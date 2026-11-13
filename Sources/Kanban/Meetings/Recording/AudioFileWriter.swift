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

    /// The first conversion or write failure. A disk that filled up or a converter
    /// that could not be built leaves a short, possibly silent file — it must not be
    /// reported as a usable recording just because the bytes exist.
    private var failure: Error?

    /// Loudest sample written so far. Read once at the end of a recording to tell
    /// "nobody spoke" apart from "the microphone was never really open".
    private var peak: Float = 0

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
        self.peak = 0
        self.failure = self.converter == nil
            ? CaptureError.engine("Could not create an audio converter for the recording.")
            : nil
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

    /// Nil while every buffer reached the file. Once set, `stop()` must fail the
    /// recording instead of offering the truncated file for upload.
    var writeError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Peak across everything that actually reached the file.
    var peakLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return peak
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
        self.peak = max(self.peak, peak)

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
                // stop() reports the failure and keeps whatever was written.
                if failure == nil { failure = error }
            }
        } else if let error, failure == nil {
            failure = error
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
