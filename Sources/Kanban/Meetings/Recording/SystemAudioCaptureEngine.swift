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

    var elapsed: TimeInterval { clock.elapsed() }

    /// Bumped by every `start` and by every teardown, so a stop that lands while
    /// `start()` is awaiting permissions cannot let the graph come up afterwards.
    private var generation: UInt64 = 0
    /// Token of the `start()` currently in flight, if any. Lets an abandoned start
    /// tell "a teardown happened" apart from "a newer start took the engine".
    private var startingToken: UInt64?

    /// The audio graph, rebuilt from scratch for every recording.
    ///
    /// Per-recording because the format is decided from whatever hardware is in front
    /// of us at the time — see `graphFormat` — and someone can plug in a headset
    /// between two meetings. It also means no state survives a recording that ended
    /// badly.
    private final class Graph {
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        let systemPlayer = AVAudioPlayerNode()
    }

    private var graph: Graph?

    // Output — safe to touch from the audio thread.
    private let writer = AudioFileWriter()
    private var outputURL: URL?

    // System audio
    private var stream: SCStream?
    private let streamOutput = StreamAudioOutput()

    // Timing
    private let clock = ElapsedClock()

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

    /// The format the graph runs at, decided per recording from the real hardware.
    ///
    /// This must match the microphone's own sample rate. An `AVAudioMixerNode` will
    /// happily change an input's channel count, but asking it to resample an input —
    /// a 44.1 kHz built-in mic into a 48 kHz mixer output, say — makes it emit
    /// digital silence, with no error and a tap that keeps firing on time. A
    /// hardcoded 48 kHz is therefore silence on every Mac whose microphone runs at
    /// 44.1 kHz, which includes the built-in one on current laptops.
    ///
    /// Stereo regardless: channel conversion is the part a mixer does reliably, and
    /// system audio arrives with two channels.
    private static func graphFormat(inputRate: Double?) -> AVAudioFormat {
        // 48 kHz only as the fallback when there is no microphone to follow —
        // it is what ScreenCaptureKit produces natively.
        let rate = inputRate.flatMap { $0 > 0 ? $0 : nil } ?? 48_000
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    /// The format this recording is running at, for the system-audio path to match.
    private var tapFormat: AVAudioFormat?

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
        generation &+= 1
        let token = generation
        startingToken = token

        var resolved = await requestPermissions(request)
        guard token == generation else {
            if startingToken == token { startingToken = nil }
            throw CaptureError.notRecording
        }
        guard !resolved.isSilent else {
            startingToken = nil
            if request.microphone && resolved.microphone == .denied { throw CaptureError.microphoneDenied }
            throw CaptureError.noSourcesAvailable
        }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        // Build the graph, only now that permissions have been resolved, and take the
        // format from the microphone it is actually going to open.
        let graph = Graph()
        self.graph = graph
        let engine = graph.engine

        var inputFormat: AVAudioFormat?
        if resolved.microphone.isWorking {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 { inputFormat = format }
        }
        let tapFormat = Self.graphFormat(inputRate: inputFormat?.sampleRate)
        self.tapFormat = tapFormat
        NSLog("[Kanban] recording mic rate=%.0f ch=%u tap rate=%.0f ch=%u",
              inputFormat?.sampleRate ?? 0, inputFormat?.channelCount ?? 0,
              tapFormat.sampleRate, tapFormat.channelCount)

        do {
            try writer.open(url: url, settings: Self.outputSettings, tapFormat: tapFormat)
        } catch {
            startingToken = nil
            throw CaptureError.engine("Could not open the recording file: \(error.localizedDescription)")
        }
        outputURL = url
        meterClock.reset()

        engine.attach(graph.mixer)
        engine.attach(graph.systemPlayer)

        if let inputFormat {
            engine.connect(engine.inputNode, to: graph.mixer, format: inputFormat)
            resolved.microphone = .active
        } else if resolved.microphone.isWorking {
            resolved.microphone = .unavailable("No input device.")
        }

        engine.connect(graph.systemPlayer, to: graph.mixer, format: tapFormat)
        engine.connect(graph.mixer, to: engine.mainMixerNode, format: tapFormat)
        engine.mainMixerNode.outputVolume = 0   // record, never monitor

        // This closure runs on a realtime audio thread. It must not touch the main
        // actor, allocate, block, or log.
        let writer = self.writer
        let meter = self.meterClock
        let elapsedClock = self.clock
        let sink: @Sendable (Float, TimeInterval) -> Void = { [weak self] level, elapsed in
            DispatchQueue.main.async {
                self?.delegate?.captureDidUpdate(level: level, elapsed: elapsed)
            }
        }

        graph.mixer.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            let peak = writer.write(buffer)
            // Throttle UI updates to ~10 Hz; a 60 fps meter is wasted CPU.
            if meter.shouldPost() {
                sink(min(1, peak * 1.6), elapsedClock.elapsed())
            }
        }
        elapsedClock.start()

        do {
            engine.prepare()
            try engine.start()
        } catch {
            cleanupGraph()
            writer.finish()
            elapsedClock.reset()
            startingToken = nil
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.engine("Audio engine failed to start: \(error.localizedDescription)")
        }
        graph.systemPlayer.play()

        if resolved.systemAudio.isWorking {
            do {
                try await startSystemAudio(format: tapFormat)
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

        // A stop that landed while the stream was starting must not resurrect the
        // recording. Tear down what this call brought up — unless a newer start
        // already owns the engine, in which case leave its graph alone.
        guard token == generation else {
            if startingToken == token {
                startingToken = nil
                await cancel()
                try? FileManager.default.removeItem(at: url)
            }
            throw CaptureError.notRecording
        }
        startingToken = nil

        sources = resolved
        delegate?.captureSourcesDidChange(resolved)
        isRecording = true
        isPaused = false
    }

    func pause() throws {
        guard isRecording, !isPaused, let graph else { throw CaptureError.notRecording }
        writer.setPaused(true)
        graph.engine.pause()
        clock.pause()
        isPaused = true
    }

    func resume() throws {
        guard isRecording, isPaused, let graph else { throw CaptureError.notRecording }
        do {
            try graph.engine.start()
        } catch {
            throw CaptureError.engine("Could not resume: \(error.localizedDescription)")
        }
        clock.resume()
        writer.setPaused(false)
        isPaused = false
    }

    func stop() async throws -> CaptureResult {
        guard isRecording, let url = outputURL else { throw CaptureError.notRecording }
        generation &+= 1
        let duration = elapsed
        await stopSystemAudio()
        cleanupGraph()
        isRecording = false
        isPaused = false

        // Read the peak before finishing: the writer clears its state on release.
        let peak = writer.peakLevel
        // Releasing the file flushes the encoder's trailing frames.
        writer.finish()
        // Read after the flush so a failure on the final buffer is included; the
        // writer keeps the failure until the next open.
        let failure = writer.writeError

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        outputURL = nil
        clock.reset()

        // A file write that failed leaves a short or silent file behind. Report it
        // rather than handing the uploader something that looks successful.
        if let failure {
            throw CaptureError.engine("The recording could not be written: \(failure.localizedDescription)")
        }

        return CaptureResult(fileURL: url, duration: duration, byteCount: size, peakLevel: peak)
    }

    func closeKeepingFile() async {
        generation &+= 1
        await stopSystemAudio()
        cleanupGraph()
        writer.finish()
        outputURL = nil
        clock.reset()
        isRecording = false
        isPaused = false
    }

    func cancel() async {
        let url = outputURL
        await closeKeepingFile()
        if let url { try? FileManager.default.removeItem(at: url) }
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
        guard let player = graph?.systemPlayer else {
            throw CaptureError.engine("The audio graph went away before system audio started.")
        }
        // ScreenCaptureKit is asked for the graph's format but does not have to
        // honour it, so whatever arrives is converted to match rather than dropped.
        // Scheduling a buffer whose format differs from the player's connection is
        // the same silence trap the microphone just came out of.
        streamOutput.targetFormat = format
        let writer = self.writer
        streamOutput.onBuffer = { buffer in
            // Still checked: scheduling a buffer the player's connection does not
            // expect raises rather than returns, and conversion can fail. Paused
            // buffers are dropped here — queueing them on the player would grow the
            // backlog for the whole pause and then play stale audio on resume.
            guard player.isPlaying, !writer.isPaused, buffer.format == format else { return }
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
        streamOutput.targetFormat = nil
        self.stream = nil
        // Never let a failure here strand the capture indicator in the menu bar.
        try? await stream.stopCapture()
    }

    // MARK: - Teardown

    /// Tears the graph down and lets go of it. The next recording builds a new one.
    private func cleanupGraph() {
        tapFormat = nil
        guard let graph else { return }
        self.graph = nil
        graph.mixer.removeTap(onBus: 0)
        graph.systemPlayer.stop()
        graph.engine.stop()
        graph.engine.reset()
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
    private var _targetFormat: AVAudioFormat?
    /// Rebuilt whenever the incoming format changes, which in practice is once.
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onBuffer }
        set { lock.lock(); _onBuffer = newValue; lock.unlock() }
    }

    /// What the audio graph expects. Buffers are resampled into it when they differ.
    var targetFormat: AVAudioFormat? {
        get { lock.lock(); defer { lock.unlock() }; return _targetFormat }
        set {
            lock.lock()
            _targetFormat = newValue
            converter = nil
            converterSource = nil
            lock.unlock()
        }
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

        handler(convertIfNeeded(buffer))
    }

    /// Resamples into the graph's format. Returns the buffer untouched when it
    /// already matches, which is the usual case.
    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        guard let target = _targetFormat, buffer.format != target else { return buffer }

        if converter == nil || converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterSource = buffer.format
        }
        guard let converter else { return buffer }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return buffer
        }
        output.frameLength = 0

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return (error == nil && output.frameLength > 0) ? output : buffer
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error.localizedDescription)
    }
}
