import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The real capture engine: microphone via AVAudioEngine, optional system audio via
/// ScreenCaptureKit, mixed into a single AAC file.
///
/// Graph:
///
///     inputNode (mic) ─────┐
///                          ├──► mixer ──► mainMixer (volume 0) ──► output
///     playerNode (system) ─┘        │
///                                   └──► tap ──► AudioFileWriter ──► .m4a
///
/// The main mixer is muted so nothing is played back — this records, it never
/// monitors, which would feed the speakers straight into the microphone.
///
/// Threading: the tap and the ScreenCaptureKit callback run on realtime audio
/// threads. Everything they touch is either the writer (lock-protected) or an
/// atomic flag. UI updates are posted to the main queue at ~10 Hz. Nothing on the
/// hot path asserts main-actor isolation.
@MainActor
final class SystemAudioCaptureEngine: NSObject, AudioCaptureEngine {

    weak var delegate: AudioCaptureDelegate?

    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var sources = CaptureSources(microphone: .disabled, systemAudio: .disabled)

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt) - pausedDuration
    }

    // Audio graph
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let systemPlayer = AVAudioPlayerNode()

    // Output — safe to touch from the audio thread.
    private let writer = AudioFileWriter()
    private var outputURL: URL?

    // System audio
    private var stream: SCStream?
    private let streamOutput = StreamAudioOutput()

    // Timing
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0

    /// Shared with the audio thread. `OSAllocatedUnfairLock` keeps the meter throttle
    /// off the main actor without a full lock on every buffer.
    private let meterClock = MeterClock()

    /// 32 kHz mono AAC: speech-grade, ~28 MB/hour, and exactly the shape a
    /// transcription model wants. Stereo and 48 kHz would only inflate the upload.
    private static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 32_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000
    ]

    private static let tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    // MARK: - Permissions

    static func probeSources(_ request: CaptureRequest) async -> CaptureSources {
        var sources = CaptureSources(microphone: .disabled, systemAudio: .disabled)

        if request.microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: sources.microphone = .ready
            case .denied, .restricted: sources.microphone = .denied
            case .notDetermined: sources.microphone = .unavailable("Not asked for yet.")
            @unknown default: sources.microphone = .unavailable("Unknown permission state.")
            }
        }

        if request.systemAudio {
            // Preflight does not prompt, which is what we want for a status display.
            sources.systemAudio = CGPreflightScreenCaptureAccess()
                ? .ready
                : .unavailable("Screen Recording not granted yet.")
        }

        return sources
    }

    /// Prompts for anything not yet granted.
    ///
    /// This is the only path that registers the app with TCC. Until it runs at least
    /// once, macOS does not list the app under Privacy & Security at all — which is
    /// why Settings offers this explicitly rather than only reporting status.
    func requestPermissions(_ request: CaptureRequest) async -> CaptureSources {
        var sources = CaptureSources(microphone: .disabled, systemAudio: .disabled)

        if request.microphone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            sources.microphone = granted ? .ready : .denied
        }

        if request.systemAudio {
            if CGPreflightScreenCaptureAccess() {
                sources.systemAudio = .ready
            } else {
                // CGRequestScreenCaptureAccess blocks while the prompt is up, so it
                // must not run on the main actor or the UI freezes behind it.
                let granted = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: CGRequestScreenCaptureAccess())
                    }
                }
                sources.systemAudio = granted
                    ? .ready
                    : .unavailable("Turn on Screen Recording for Kanban, then quit and reopen the app.")
            }
        }

        self.sources = sources
        delegate?.captureSourcesDidChange(sources)
        return sources
    }

    // MARK: - Recording

    func start(to url: URL, request: CaptureRequest) async throws {
        guard !isRecording else { throw CaptureError.alreadyRecording }

        var resolved = await requestPermissions(request)
        guard !resolved.isSilent else {
            if request.microphone && resolved.microphone == .denied { throw CaptureError.microphoneDenied }
            throw CaptureError.noSourcesAvailable
        }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        do {
            try writer.open(url: url, settings: Self.outputSettings, tapFormat: Self.tapFormat)
        } catch {
            throw CaptureError.engine("Could not open the recording file: \(error.localizedDescription)")
        }
        outputURL = url
        meterClock.reset()

        // Build the graph.
        engine.attach(mixer)
        engine.attach(systemPlayer)

        if resolved.microphone.isWorking {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0 {
                engine.connect(input, to: mixer, format: inputFormat)
                resolved.microphone = .active
            } else {
                resolved.microphone = .unavailable("No input device.")
            }
        }

        engine.connect(systemPlayer, to: mixer, format: Self.tapFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: Self.tapFormat)
        engine.mainMixerNode.outputVolume = 0   // record, never monitor

        // This closure runs on a realtime audio thread. It must not touch the main
        // actor, allocate, block, or log.
        let writer = self.writer
        let clock = self.meterClock
        let sink: @Sendable (Float, TimeInterval) -> Void = { [weak self] level, elapsed in
            DispatchQueue.main.async {
                self?.delegate?.captureDidUpdate(level: level, elapsed: elapsed)
            }
        }
        let started = Date()

        mixer.installTap(onBus: 0, bufferSize: 4096, format: Self.tapFormat) { buffer, _ in
            let peak = writer.write(buffer)
            // Throttle UI updates to ~10 Hz; a 60 fps meter is wasted CPU.
            if clock.shouldPost() {
                sink(min(1, peak * 1.6), Date().timeIntervalSince(started))
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            cleanupGraph()
            writer.finish()
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.engine("Audio engine failed to start: \(error.localizedDescription)")
        }
        systemPlayer.play()

        if resolved.systemAudio.isWorking {
            do {
                try await startSystemAudio(format: Self.tapFormat)
                resolved.systemAudio = .active
            } catch {
                // A failure here must not kill the recording — the mic keeps going.
                resolved.systemAudio = .unavailable(Self.describe(error))
                delegate?.captureDidFail(.engine("System audio unavailable: \(Self.describe(error))"))
            }
        }

        guard !resolved.isSilent else {
            await cancel()
            throw CaptureError.noSourcesAvailable
        }

        sources = resolved
        delegate?.captureSourcesDidChange(resolved)
        startedAt = Date()
        pausedDuration = 0
        pausedAt = nil
        isRecording = true
        isPaused = false
    }

    func pause() throws {
        guard isRecording, !isPaused else { throw CaptureError.notRecording }
        writer.setPaused(true)
        engine.pause()
        pausedAt = Date()
        isPaused = true
    }

    func resume() throws {
        guard isRecording, isPaused else { throw CaptureError.notRecording }
        if let pausedAt { pausedDuration += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        do {
            try engine.start()
        } catch {
            throw CaptureError.engine("Could not resume: \(error.localizedDescription)")
        }
        writer.setPaused(false)
        isPaused = false
    }

    func stop() async throws -> CaptureResult {
        guard isRecording, let url = outputURL else { throw CaptureError.notRecording }
        let duration = elapsed

        await stopSystemAudio()
        cleanupGraph()
        isRecording = false
        isPaused = false

        // Releasing the file flushes the encoder's trailing frames.
        writer.finish()

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        outputURL = nil
        startedAt = nil

        return CaptureResult(fileURL: url, duration: duration, byteCount: size ?? 0)
    }

    func cancel() async {
        await stopSystemAudio()
        cleanupGraph()
        writer.finish()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
        startedAt = nil
        isRecording = false
        isPaused = false
    }

    // MARK: - System audio

    private func startSystemAudio(format: AVAudioFormat) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.engine("No display available to attach an audio capture to.")
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(format.sampleRate)
        configuration.channelCount = Int(format.channelCount)
        configuration.excludesCurrentProcessAudio = true
        // Video is mandatory on an SCStream, so take the smallest, slowest frame
        // possible and throw it away. This keeps the capture near-free.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)

        // Runs on the ScreenCaptureKit queue. AVAudioPlayerNode.scheduleBuffer is
        // safe to call from any thread; nothing else here touches the actor.
        let player = systemPlayer
        streamOutput.onBuffer = { buffer in
            guard buffer.format.sampleRate == format.sampleRate,
                  buffer.format.channelCount == format.channelCount,
                  player.isPlaying else { return }
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
        streamOutput.onStopped = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                // The user hit "Stop Sharing" in the menu bar, or the stream died.
                // The microphone keeps recording; say so rather than failing silently.
                self.sources.systemAudio = .unavailable(reason)
                self.stream = nil
                self.delegate?.captureSourcesDidChange(self.sources)
                self.delegate?.captureDidFail(.systemAudioStopped(reason))
            }
        }

        try stream.addStreamOutput(streamOutput, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "kanban.sysaudio", qos: .userInitiated))
        try await stream.startCapture()
        self.stream = stream
    }

    private func stopSystemAudio() async {
        guard let stream else { return }
        streamOutput.onBuffer = nil
        streamOutput.onStopped = nil
        self.stream = nil
        // Never let a failure here strand the capture indicator in the menu bar.
        try? await stream.stopCapture()
    }

    // MARK: - Teardown

    private func cleanupGraph() {
        mixer.removeTap(onBus: 0)
        systemPlayer.stop()
        engine.stop()
        engine.reset()
        if engine.attachedNodes.contains(mixer) { engine.detach(mixer) }
        if engine.attachedNodes.contains(systemPlayer) { engine.detach(systemPlayer) }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801: return "Screen Recording permission was refused."
            default: return nsError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Meter throttle

/// Shared between the audio thread and the main queue. Keeps the ~10 Hz throttle out
/// of main-actor state so the tap never has to reach across an actor boundary.
private final class MeterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func reset() {
        lock.lock()
        last = .distantPast
        lock.unlock()
    }

    func shouldPost() -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(last) > 0.1 else { return false }
        last = now
        return true
    }
}

// MARK: - SCStream plumbing

/// Bridges ScreenCaptureKit's sample buffers into AVAudioPCMBuffers.
/// Lives outside the actor because SCStream calls back on its own queue.
private final class StreamAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var _onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var _onStopped: ((String) -> Void)?

    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onBuffer }
        set { lock.lock(); _onBuffer = newValue; lock.unlock() }
    }

    var onStopped: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStopped }
        set { lock.lock(); _onStopped = newValue; lock.unlock() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let handler = onBuffer else { return }
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate,
                                         channels: description.mChannelsPerFrame) else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames

        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size
            + Int(max(0, format.channelCount - 1)) * MemoryLayout<AudioBuffer>.size
        let listPointer = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        let list = listPointer.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(list)
        guard let destination = buffer.floatChannelData else { return }
        for channel in 0..<Int(format.channelCount) where channel < sourceBuffers.count {
            guard let source = sourceBuffers[channel].mData else { continue }
            let count = min(Int(frames), Int(sourceBuffers[channel].mDataByteSize) / MemoryLayout<Float>.size)
            destination[channel].update(from: source.assumingMemoryBound(to: Float.self), count: count)
        }

        handler(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error.localizedDescription)
    }
}
