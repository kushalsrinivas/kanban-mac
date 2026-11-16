import AVFoundation
import Foundation

/// File decoding for the engine: one audio track, downmixed to mono, resampled
/// to 16 kHz float32 — the only input transcribe.cpp accepts.
///
/// Handy decodes with symphonia + a rubato FFT resampler; `AVAudioConverter`
/// plays the same role here and reads everything AVFoundation can open (the
/// app's own recordings are 32 kHz mono AAC).
enum AudioPCM {

    static let sampleRate: Double = 16_000

    static func decode(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard inputFormat.channelCount > 0, file.length > 0 else {
            throw TranscriptionError.engine("The recording has no audio.")
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false) else {
            throw TranscriptionError.engine("Could not prepare the audio format.")
        }

        if inputFormat.commonFormat == .pcmFormatFloat32,
           inputFormat.sampleRate == sampleRate,
           inputFormat.channelCount == 1 {
            return try readDirect(file)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionError.engine("Could not convert the recording to 16 kHz.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let inputCapacity: AVAudioFrameCount = 16_384
        let outputCapacity = AVAudioFrameCount(sampleRate)   // one second per pass
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw TranscriptionError.engine("Could not allocate audio buffers.")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / inputFormat.sampleRate) + 1)
        var reachedEnd = false

        func drain(_ status: AVAudioConverterOutputStatus) throws {
            if outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(outputBuffer.frameLength)))
            }
            if status == .error { throw TranscriptionError.engine("Audio conversion failed.") }
        }

        while !reachedEnd {
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { break }
            let frames = AVAudioFrameCount(min(Int64(inputCapacity), remaining))
            try file.read(into: inputBuffer, frameCount: frames)
            let isLastRead = file.framePosition >= file.length
            var supplied = false
            while true {
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { _, statusPointer in
                    if supplied {
                        statusPointer.pointee = isLastRead ? .endOfStream : .noDataNow
                        return nil
                    }
                    supplied = true
                    statusPointer.pointee = .haveData
                    return inputBuffer
                }
                try drain(status)
                if let error { throw TranscriptionError.engine(error.localizedDescription) }
                if status == .endOfStream || status == .error { break }
                if status == .inputRanDry { break }
            }
        }

        // Flush the converter's delay.
        while true {
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, statusPointer in
                statusPointer.pointee = .endOfStream
                return nil
            }
            try drain(status)
            if let error { throw TranscriptionError.engine(error.localizedDescription) }
            if status == .endOfStream || status == .error || outputBuffer.frameLength == 0 { break }
        }

        guard !samples.isEmpty else {
            throw TranscriptionError.engine("The recording decoded to no audio.")
        }
        return samples
    }

    private static func readDirect(_ file: AVAudioFile) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionError.engine("Could not allocate an audio buffer.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw TranscriptionError.engine("The recording decoded to no audio.")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
