import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The real capture engine: microphone via AVAudioEngine, system audio via
/// ScreenCaptureKit, mixed into a single AAC file.
///
/// Graph:
///
///     inputNode (mic) ─────┐
///                          ├──► mixer ──► mainMixer (volume 0) ──► output
///     playerNode (system) ─┘        │
///                                   └──► tap ──► AVAudioConverter ──► AAC .m4a
///
/// The main mixer is muted so nothing is played back — this records, it never
/// monitors, which would feed the speakers straight back into the microphone.
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

    // Output
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputURL: URL?

    // System audio
    private var stream: SCStream?
    private let streamOutput = StreamAudioOutput()

    // Timing
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var lastMeterUpdate = Date.distantPast

    /// 32 kHz mono AAC: speech-grade, ~28 MB/hour, and exactly the shape a
    /// transcription model wants. Stereo and 48 kHz would only inflate the upload.
    private static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 32_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000
    ]

    // MARK: - Permissions

    static func probeSources(_ request: CaptureRequest) async -> CaptureSources {
        var sources = CaptureSources(microphone: .disabled, systemAudio: .disabled)

        if request.microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: sources.microphone = .ready
            case .denied, .restricted: sources.microphone = .denied
            case .notDetermined: sources.microphone = .unavailable("Permission not requested yet.")
            @unknown default: sources.microphone = .unavailable("Unknown permission state.")
            }
        }

        if request.systemAudio {
            // Preflight does not prompt, which is what we want for a status display.
            sources.systemAudio = CGPreflightScreenCaptureAccess()
                ? .ready
                : .unavailable("Screen Recording permission not granted yet.")
        }

        return sources
    }

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
                // Opens System Settings the first time; returns immediately after.
                let granted = CGRequestScreenCaptureAccess()
                sources.systemAudio = granted
                    ? .ready
                    : .unavailable("Grant Screen Recording in System Settings, then start again.")
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

        // The tap format is whatever the input hardware gives us; the file is 32k mono.
        let tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: Self.outputSettings)
        } catch {
            throw CaptureError.engine("Could not open the recording file: \(error.localizedDescription)")
        }
        file = audioFile
        outputURL = url
        converter = AVAudioConverter(from: tapFormat, to: audioFile.processingFormat)

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

        engine.connect(systemPlayer, to: mixer, format: tapFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: tapFormat)
        engine.mainMixerNode.outputVolume = 0   // record, never monitor

        mixer.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.write(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            cleanupGraph()
            throw CaptureError.engine("Audio engine failed to start: \(error.localizedDescription)")
        }
        systemPlayer.play()

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
        file = nil
        converter = nil

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        outputURL = nil
        startedAt = nil

        return CaptureResult(fileURL: url, duration: duration, byteCount: size ?? 0)
    }

    func cancel() async {
        await stopSystemAudio()
        cleanupGraph()
        file = nil
        converter = nil
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
        startedAt = nil
        isRecording = false
        isPaused = false
    }

    // MARK: - Writing

    private nonisolated func write(_ buffer: AVAudioPCMBuffer) {
        // Runs on the audio thread. Keep it allocation-light and never block.
        MainActor.assumeIsolated {
            guard !isPaused, let file, let converter else { return }

            let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: capacity) else { return }

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
            if error == nil, output.frameLength > 0 {
                try? file.write(from: output)
            }

            meter(buffer)
        }
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastMeterUpdate) > 0.1 else { return }
        lastMeterUpdate = now

        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Peak rather than RMS: cheaper, and more legible as an activity indicator.
        var peak: Float = 0
        var i = 0
        while i < frames {
            peak = max(peak, abs(channel[i]))
            i += 8   // every 8th sample is plenty for a level meter
        }
        delegate?.captureDidUpdate(level: min(1, peak * 1.6), elapsed: elapsed)
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
        // Do not record our own output; nothing here plays audio, but it keeps the
        // capture honest if a future version ever does.
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

        streamOutput.onBuffer = { [weak self] buffer in
            MainActor.assumeIsolated { self?.enqueueSystemAudio(buffer, format: format) }
        }
        streamOutput.onStopped = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.sources.systemAudio = .unavailable(reason)
                self.delegate?.captureSourcesDidChange(self.sources)
                self.delegate?.captureDidFail(.engine("System audio stopped: \(reason)"))
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
        try? await stream.stopCapture()
        self.stream = nil
    }

    private func enqueueSystemAudio(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard isRecording, !isPaused, systemPlayer.isPlaying else { return }
        guard buffer.format.sampleRate == format.sampleRate,
              buffer.format.channelCount == format.channelCount else { return }
        systemPlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Teardown

    private func cleanupGraph() {
        mixer.removeTap(onBus: 0)
        systemPlayer.stop()
        engine.stop()
        engine.reset()
        // Detach so a second recording rebuilds a clean graph.
        if engine.attachedNodes.contains(mixer) { engine.detach(mixer) }
        if engine.attachedNodes.contains(systemPlayer) { engine.detach(systemPlayer) }
    }

    private static func describe(_ error: Error) -> String {
        if let scError = error as NSError?, scError.domain == SCStreamErrorDomain {
            switch scError.code {
            case -3801: return "Screen Recording permission was refused."
            default: return scError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - SCStream plumbing

/// Bridges ScreenCaptureKit's sample buffers into AVAudioPCMBuffers.
/// Lives outside the actor because SCStream calls back on its own queue.
private final class StreamAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onStopped: ((String) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let onBuffer else { return }
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate,
                                         channels: description.mChannelsPerFrame) else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames

        // Copy into the PCM buffer's channel pointers.
        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size + Int(format.channelCount - 1) * MemoryLayout<AudioBuffer>.size
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

        onBuffer(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error.localizedDescription)
    }
}
