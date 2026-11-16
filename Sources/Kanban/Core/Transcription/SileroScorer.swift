import Foundation
import TranscribeCpp

/// Silero VAD through the same transcribe.cpp runtime whisper runs on, exactly
/// as Handy's `audio_toolkit/vad/silero.rs`: the model's own frame size, one
/// probability per whole frame, CPU only (a 1 MB model does not need a GPU).
final class SileroScorer: SpeechScoring {

    /// Handy's Silero threshold for capture and scoring.
    static let threshold: Float = 0.3

    let frameSamples: Int
    private let model: Model
    private let session: VadSession

    init(path: URL, threads: Int32 = 1) throws {
        let model = try Model(path: path.path, options: ModelOptions(backend: .cpu))
        guard model.roles.contains(.vad) else {
            throw TranscriptionError.engine("\(path.lastPathComponent) is not a voice activity model.")
        }
        let info = try model.vadInfo
        guard info.sampleRate == Int32(SpeechChunking.rate), info.frameSamples > 0 else {
            throw TranscriptionError.engine(
                "Unsupported voice detector: \(info.sampleRate) Hz, \(info.frameSamples) samples per frame.")
        }
        self.model = model
        self.session = try model.vadSession(threads: threads)
        self.frameSamples = Int(info.frameSamples)
    }

    func score(_ frames: [Float]) throws -> [Float] {
        guard frames.count % frameSamples == 0 else {
            throw TranscriptionError.engine("The voice detector needs whole frames.")
        }
        let result = try session.streamFeed(frames)
        let expected = frames.count / frameSamples
        guard result.probs.count == expected else {
            throw TranscriptionError.engine(
                "The voice detector returned \(result.probs.count) scores for \(expected) frames.")
        }
        return result.probs
    }
}
