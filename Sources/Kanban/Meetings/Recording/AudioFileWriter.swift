import AVFoundation
import Foundation

/// Owns the output file and the format conversion.
///
/// This deliberately lives *outside* the main actor. The AVAudioEngine tap and the
/// ScreenCaptureKit callback both run on realtime audio threads, and anything they
/// touch has to be safe there — an earlier version reached for main-actor state from
/// the tap and trapped the moment recording started.
///
/// One lock, held only around the conversion and the file write. No allocation beyond
/// the output buffer, no logging, no Swift concurrency on the hot path.
final class AudioFileWriter: @unchecked Sendable {

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputBuffer: AVAudioPCMBuffer?

    /// Read from the audio thread on every buffer, so it is behind the same lock
    /// rather than being main-actor state.
    private var paused = false
    private(set) var frameCount: AVAudioFramePosition = 0

    // MARK: Lifecycle

    /// Opens the destination. `tapFormat` is what the engine will hand us.
    func open(url: URL, settings: [String: Any], tapFormat: AVAudioFormat) throws {
        lock.lock()
        defer { lock.unlock() }

        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file
        self.converter = AVAudioConverter(from: tapFormat, to: file.processingFormat)
        self.frameCount = 0
        self.paused = false
    }

    /// Releasing the file is what flushes the encoder's trailing frames.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        converter = nil
        outputBuffer = nil
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    // MARK: Hot path

    /// Called from the audio thread for every buffer. Returns the peak level so the
    /// caller can drive a meter without walking the samples twice.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Float {
        let peak = Self.peak(of: buffer)

        lock.lock()
        defer { lock.unlock() }

        guard !paused, let file, let converter else { return peak }

        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        // Reuse the output buffer across calls; allocating one per buffer would churn
        // the heap 40+ times a second for the length of a meeting.
        if outputBuffer == nil || outputBuffer!.frameCapacity < capacity {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: capacity)
        }
        guard let output = outputBuffer else { return peak }
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

        if error == nil, output.frameLength > 0 {
            do {
                try file.write(from: output)
                frameCount += AVAudioFramePosition(output.frameLength)
            } catch {
                // Disk full or the file vanished. Drop the buffer rather than trap;
                // stop() will report the short recording.
            }
        }
        return peak
    }

    /// Peak rather than RMS: cheaper, and more legible as an activity indicator.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        var i = 0
        while i < frames {
            peak = max(peak, abs(channel[i]))
            i += 8   // every 8th sample is plenty for a meter
        }
        return peak
    }
}
