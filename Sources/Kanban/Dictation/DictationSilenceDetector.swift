import Foundation

/// Decides when a dictation has said everything it is going to say.
///
/// Handy stops on key release (push-to-talk) or a second press (toggle). A
/// permission-free hotkey has no key-up here, so the flow finishes itself:
/// two seconds of silence after real speech, or a few seconds of nothing at all.
struct DictationSilenceDetector {

    /// Below this capture level (0…1, peak-based) a frame counts as silence.
    /// Quiet rooms sit well under it; speech is an order of magnitude above.
    var threshold: Float = 0.05
    /// Speech needed before silence means anything, so a cough is not a sentence.
    var minimumSpeech: TimeInterval = 0.6
    /// Silence that ends the dictation.
    var silenceLimit: TimeInterval = 2.0
    /// Total time allowed without any speech at all.
    var emptyLimit: TimeInterval = 6.0

    private(set) var speech: TimeInterval = 0
    private(set) var silence: TimeInterval = 0
    private(set) var total: TimeInterval = 0

    /// - Parameter seconds: duration of the frame this level covers.
    /// - Returns: true when the dictation should stop on its own.
    mutating func add(level: Float, seconds: TimeInterval) -> Bool {
        guard seconds > 0 else { return false }
        total += seconds
        if level >= threshold {
            speech += seconds
            silence = 0
            return false
        }
        guard speech >= minimumSpeech else {
            return total >= emptyLimit
        }
        silence += seconds
        return silence >= silenceLimit
    }
}
