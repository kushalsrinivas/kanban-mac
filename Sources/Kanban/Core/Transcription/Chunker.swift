import Foundation

/// Scores 16 kHz frames for speech, one probability per whole frame.
protocol SpeechScoring: AnyObject {
    var frameSamples: Int { get }
    func score(_ frames: [Float]) throws -> [Float]
}

/// Long-form chunking: long audio is decoded in chunks cut at pauses, because
/// whisper's accuracy degrades past 30–40 s in one run.
///
/// Direct port of Handy's `audio_toolkit/chunking.rs` (itself ported from
/// pi-voice's `chunking.ts`). Every duration is in 16 kHz samples, never in
/// frames, so any detector's frame size works with the same rules. The
/// thresholds are Silero's `get_speech_timestamps` defaults.
enum SpeechChunking {
    static let rate = 16_000

    static let targetSeconds = 30.0
    /// Audio up to this many samples is decoded in one piece; longer audio is cut.
    static let maxChunkSamples = 40 * rate
    static let minChunkSamples = 5 * rate
    /// Live, a cut is only final once this much audio past its window is
    /// scored: then no cut it allows can leave a short rest.
    static let lookaheadSamples = minChunkSamples

    static let threshold: Float = 0.5
    static let negThreshold: Float = threshold - 0.15
    static let minSpeechSamples = 250 * rate / 1000
    static let minSilenceSamples = 100 * rate / 1000
    static let speechPadSamples = 30 * rate / 1000

    /// Speech segments, in samples, from per-frame speech probabilities:
    /// Silero's `get_speech_timestamps` without a maximum speech length.
    /// `samples` is the length of the audio the probabilities score.
    static func speechSegments(probs: [Float], frameSamples: Int, samples: Int) -> [Range<Int>] {
        var segments: [Range<Int>] = []
        var triggered = false
        var start = 0
        var tempEnd: Int?

        for (i, prob) in probs.enumerated() {
            let at = i * frameSamples
            if prob >= threshold {
                tempEnd = nil
                if !triggered {
                    triggered = true
                    start = at
                }
                continue
            }
            if prob < negThreshold, triggered {
                let end = tempEnd ?? at
                if tempEnd == nil { tempEnd = at }
                if at - end < minSilenceSamples { continue }
                if end - start > minSpeechSamples {
                    segments.append(start..<end)
                }
                triggered = false
                tempEnd = nil
            }
        }
        if triggered, samples - start > minSpeechSamples {
            segments.append(start..<samples)
        }

        for i in segments.indices {
            if i == 0 {
                segments[0] = max(0, segments[0].lowerBound - speechPadSamples)..<segments[0].upperBound
            }
            if i + 1 == segments.count {
                segments[i] = segments[i].lowerBound
                    ..< min(samples, segments[i].upperBound + speechPadSamples)
                continue
            }
            let silence = segments[i + 1].lowerBound - segments[i].upperBound
            let pad = silence < 2 * speechPadSamples ? silence / 2 : speechPadSamples
            segments[i] = segments[i].lowerBound..<min(samples, segments[i].upperBound + pad)
            segments[i + 1] = max(0, segments[i + 1].lowerBound - pad)..<segments[i + 1].upperBound
        }
        return segments
    }

    /// A place a chunk may end: the middle of a pause.
    struct CutCandidate: Equatable {
        var cut: Int
        var gapSeconds: Double
    }

    /// One candidate in the middle of each pause, lead-in and tail included.
    static func cutCandidates(segments: [Range<Int>], samples: Int) -> [CutCandidate] {
        var candidates: [CutCandidate] = []
        var silenceStart = 0
        for segment in segments + [samples..<samples] {
            if segment.lowerBound > silenceStart {
                candidates.append(CutCandidate(
                    cut: (silenceStart + segment.lowerBound) / 2,
                    gapSeconds: Double(segment.lowerBound - silenceStart) / Double(rate)))
            }
            silenceStart = max(silenceStart, segment.upperBound)
        }
        return candidates
    }

    /// Greedy, left to right from `from`: each cut is the best-scoring pause
    /// 5–40 s after the previous one, preferring long pauses near 30 s and ones
    /// that leave at least 5 s after them. With no pause, a hard cut at 40 s, or
    /// halfway when that would leave under 5 s. 40 s or less is never cut.
    /// `candidates` must be in order.
    static func planCuts(candidates: [CutCandidate], samples: Int, from: Int) -> [Int] {
        var cuts: [Int] = []
        var start = from
        var first = 0
        while samples - start > maxChunkSamples {
            while first < candidates.count, candidates[first].cut < start + minChunkSamples {
                first += 1
            }
            var best: (cut: Int, score: Double)?
            var fallback: (cut: Int, score: Double)?
            for candidate in candidates[first...].prefix(while: { $0.cut <= start + maxChunkSamples }) {
                let position = Double(candidate.cut - start) / Double(rate)
                let offTarget = position > targetSeconds
                    ? 0.1 * (position - targetSeconds)
                    : 0.05 * (targetSeconds - position)
                let score = min(candidate.gapSeconds, 1.0) - offTarget
                if samples - candidate.cut >= minChunkSamples, best == nil || score > best!.score {
                    best = (candidate.cut, score)
                }
                if fallback == nil || score > fallback!.score {
                    fallback = (candidate.cut, score)
                }
            }
            let hardCut = samples - start < maxChunkSamples + minChunkSamples
                ? start + (samples - start) / 2
                : start + maxChunkSamples
            start = best?.cut ?? fallback?.cut ?? hardCut
            cuts.append(start)
        }
        return cuts
    }

    /// Joins chunk texts in order: a space between two chunks unless either side
    /// is written without spaces (CJK, Thai, Lao, Khmer, Myanmar, CJK punctuation).
    static func joinTranscripts(_ texts: [String]) -> String {
        var joined = ""
        var last: Character?
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { continue }
            if let last, !isUnspaced(last), !isUnspaced(first) {
                joined.append(" ")
            }
            joined.append(contentsOf: trimmed)
            last = trimmed.last
        }
        return joined
    }

    static func isUnspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: { scalar in
            let value = scalar.value
            switch value {
            // Han, including the supplementary planes, kana, bopomofo.
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F,
                 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,
                 0x3100...0x312F, 0x31A0...0x31BF:
                return true
            // Thai, Lao, Khmer, Myanmar.
            case 0x0E00...0x0E7F, 0x0E80...0x0EFF,
                 0x1000...0x109F,
                 0x1780...0x17FF, 0x19E0...0x19FF:
                return true
            // CJK punctuation and full-width forms.
            case 0x3000...0x303F, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        })
    }
}

/// Cuts audio into chunks at pauses as it arrives, and hands each back once its
/// cut is certain, so a clip can be decoded while the rest is still being read
/// (and long clips never sit in memory twice).
///
/// If the audio cannot be scored (the VAD fails to load or run), nothing more is
/// cut and the rest is one chunk: chunking only places cuts, so the audio is
/// still decoded.
struct Chunker {
    typealias MakeScorer = () throws -> SpeechScoring

    private let makeScorer: MakeScorer
    /// Made the first time audio has to be scored, so a clip short enough to be
    /// one chunk never loads a VAD.
    private var scorer: SpeechScoring?
    private var frameSamples = 0
    /// Set when scoring fails: no more cuts.
    private var uncut = false
    /// Audio from `start` on; everything before it is already in a chunk.
    private var pending: [Float] = []
    /// One speech probability per whole frame from the beginning.
    private var probs: [Float] = []
    private var start = 0
    private var len = 0

    init(makeScorer: @escaping MakeScorer) {
        self.makeScorer = makeScorer
    }

    /// Samples pushed so far, chunked or not. A caller checks this against the
    /// whole recording before trusting the chunks.
    var samples: Int { len }

    /// Adds audio. Returns the chunks whose cuts this made certain, in order.
    mutating func push(_ pcm: [Float]) -> [[Float]] {
        len += pcm.count
        pending.append(contentsOf: pcm)
        if uncut || len - start <= SpeechChunking.maxChunkSamples + SpeechChunking.lookaheadSamples {
            return []
        }
        // Plan over whole frames only; a partial one waits for the rest.
        let scored: Int
        do {
            scored = try score(padLast: false)
        } catch {
            stopCutting()
            return []
        }
        let segments = SpeechChunking.speechSegments(
            probs: probs, frameSamples: frameSamples, samples: scored)
        // A pause still open at the end moves its midpoint as it grows: wait
        // for speech.
        if segments.last?.upperBound != scored {
            return []
        }
        // One plan, committed while each cut's whole window plus the lookahead
        // is scored.
        let cuts = SpeechChunking.planCuts(
            candidates: SpeechChunking.cutCandidates(segments: segments, samples: scored),
            samples: scored, from: start)
        var chunks: [[Float]] = []
        for cut in cuts {
            if scored - start <= SpeechChunking.maxChunkSamples + SpeechChunking.lookaheadSamples {
                break
            }
            chunks.append(take(until: cut))
        }
        return chunks
    }

    /// Cuts what is left and returns the remaining chunks, in order. Nothing
    /// more is pushed after.
    mutating func finish() -> [[Float]] {
        var chunks: [[Float]] = []
        if !uncut, len - start > SpeechChunking.maxChunkSamples {
            do {
                _ = try score(padLast: true)
                let segments = SpeechChunking.speechSegments(
                    probs: probs, frameSamples: frameSamples, samples: len)
                let cuts = SpeechChunking.planCuts(
                    candidates: SpeechChunking.cutCandidates(segments: segments, samples: len),
                    samples: len, from: start)
                for cut in cuts {
                    chunks.append(take(until: cut))
                }
            } catch {
                stopCutting()
            }
        }
        if len > start {
            chunks.append(take(until: len))
        }
        return chunks
    }

    /// Scores every frame not yet scored, making the scorer first if this is the
    /// first time: whole frames only, or with `padLast` the partial last frame
    /// too, zero padded. Returns how many samples are scored.
    private mutating func score(padLast: Bool) throws -> Int {
        if scorer == nil {
            // Nothing is cut before the first score, so a fresh scorer starts
            // at the first sample, as it must.
            let made = try makeScorer()
            frameSamples = made.frameSamples
            guard frameSamples > 0 else {
                throw TranscriptionError.engine("the voice detector reported a zero frame size")
            }
            scorer = made
        }
        guard let scorer else { return len }
        let frame = frameSamples
        let scored = probs.count * frame
        // Cuts only fall in scored audio, so its unscored rest is pending.
        let from = scored - start
        let whole = (len - scored) / frame * frame
        if whole > 0 {
            let slice = Array(pending[from..<(from + whole)])
            probs.append(contentsOf: try scorer.score(slice))
        }
        if padLast, len > scored + whole {
            var tail = Array(pending[(from + whole)...])
            tail += Array(repeating: 0, count: frame - tail.count)
            probs.append(contentsOf: try scorer.score(tail))
            return len
        }
        return scored + whole
    }

    private mutating func stopCutting() {
        uncut = true
    }

    private mutating func take(until cut: Int) -> [Float] {
        let count = cut - start
        let chunk = Array(pending.prefix(count))
        pending.removeFirst(count)
        start = cut
        return chunk
    }
}
