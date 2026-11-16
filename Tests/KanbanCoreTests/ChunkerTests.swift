import XCTest

/// The chunker's own expectations, ported from Handy's
/// `audio_toolkit/chunking.rs` tests. These pin the cut plan: if a port drifts,
/// chunk boundaries (and so transcription quality) drift with it.
final class ChunkerTests: XCTestCase {

    private let frame = 512
    private let rate = 16_000

    // MARK: Fixtures

    private func samples(_ seconds: Double) -> Int {
        Int((seconds * Double(rate)).rounded())
    }

    /// Frame probabilities: speech everywhere except the given pauses, in seconds.
    private func probsWithPauses(_ seconds: Double, _ pauses: [(Double, Double)]) -> [Float] {
        (0..<(samples(seconds) / frame)).map { index in
            let at = Double(index * frame) / Double(rate)
            return pauses.contains { at >= $0.0 && at < $0.1 } ? 0 : 1
        }
    }

    /// Cut positions, in tenths of a second.
    private func plan(_ seconds: Double, _ pauses: [(Double, Double)]) -> [Double] {
        let total = samples(seconds)
        let segments = SpeechChunking.speechSegments(
            probs: probsWithPauses(seconds, pauses), frameSamples: frame, samples: total)
        return SpeechChunking.planCuts(
            candidates: SpeechChunking.cutCandidates(segments: segments, samples: total),
            samples: total, from: 0)
            .map { (Double($0) / Double(rate) * 10).rounded() / 10 }
    }

    private func lengths(_ chunks: [[Float]]) -> [Int] { chunks.map(\.count) }

    /// Where chunks end, except the last, in tenths of a second.
    private func cuts(_ chunks: [[Float]]) -> [Double] {
        var end = 0
        return chunks.dropLast().map { chunk in
            end += chunk.count
            return (Double(end) / Double(rate) * 10).rounded() / 10
        }
    }

    /// Scores each frame with its first sample, so a clip carries its own
    /// probabilities. Fails on the `failOn`th call.
    private final class ScriptedScorer: SpeechScoring {
        let frameSamples: Int
        let scored: Counter
        var calls = 0
        let failOn: Int?

        init(frameSamples: Int, scored: Counter, failOn: Int?) {
            self.frameSamples = frameSamples
            self.scored = scored
            self.failOn = failOn
        }

        func score(_ frames: [Float]) throws -> [Float] {
            XCTAssertEqual(frames.count % frameSamples, 0, "whole frames only")
            calls += 1
            if failOn == calls - 1 { throw TranscriptionError.engine("scripted VAD failure") }
            scored.value += frames.count / frameSamples
            return stride(from: 0, to: frames.count, by: frameSamples).map { frames[$0] }
        }
    }

    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func chunker(failOn: Int? = nil) -> (Chunker, Counter, Counter) {
        let made = Counter()
        let scored = Counter()
        let frame = frame
        let chunker = Chunker {
            made.value += 1
            return ScriptedScorer(frameSamples: frame, scored: scored, failOn: failOn)
        }
        return (chunker, made, scored)
    }

    /// Audio whose every frame holds its own probability.
    private func clip(_ probs: [Float]) -> [Float] {
        probs.flatMap { Array(repeating: $0, count: frame) }
    }

    /// 100 s of audio, with pauses at 29–30 s and 58–59 s.
    private func longClip() -> [Float] {
        clip(probsWithPauses(100, [(29, 30), (58, 59)]))
    }

    // MARK: Plan

    func testCutsPreferLongPausesNear30s() {
        XCTAssertTrue(plan(40, [(20, 21)]).isEmpty, "40 s or less is never cut")
        XCTAssertEqual(plan(70, [(28, 29), (30, 30.2), (55, 56)]), [28.5, 55.5])
        XCTAssertEqual(plan(100, []), [40, 80], "without a pause, hard 40 s cuts")
        XCTAssertEqual(plan(60, [(2, 3)]), [40], "a pause under 5 s in is never used")
    }

    func testCutsAvoidLeavingAShortLastChunk() {
        XCTAssertEqual(plan(42, [(9.8, 10.2), (37.5, 38.5)]), [10])
        XCTAssertEqual(plan(84, []), [40, 62], "a short rest is split evenly")
        XCTAssertEqual(plan(40.5, [(38.8, 39.2)]), [39],
                       "a pause that leaves a short rest still beats cutting mid-speech")
    }

    // MARK: Join

    func testJoinsPutSpacesOnlyBetweenSpacedScripts() {
        XCTAssertEqual(
            SpeechChunking.joinTranscripts([" Hello there. ", "", "General Kenobi."]),
            "Hello there. General Kenobi.")
        XCTAssertEqual(
            SpeechChunking.joinTranscripts(["今天天气很好。", "我们去公园吧。"]),
            "今天天气很好。我们去公园吧。")
        XCTAssertEqual(SpeechChunking.joinTranscripts(["I said", "你好"]), "I said你好")
        XCTAssertEqual(
            SpeechChunking.joinTranscripts(["안녕하세요.", "반갑습니다."]),
            "안녕하세요. 반갑습니다.")
        XCTAssertEqual(
            SpeechChunking.joinTranscripts(["你好𠀀", "我们"]), "你好𠀀我们",
            "CJK Extension B is outside the BMP")
    }

    // MARK: Streaming and failure

    func testChunksArriveBeforeTheEndAtTheSameCuts() {
        var pcm = longClip()
        pcm.append(contentsOf: Array(repeating: 1, count: 100))   // partial frame
        var once = chunker().0
        var offline = once.push(pcm)
        offline += once.finish()
        // Pause midpoints, then the 41.5 s left split evenly.
        XCTAssertEqual(cuts(offline), [29.5, 58.5, 79.3])

        var (chunker, made, scored) = self.chunker()
        var live: [[Float]] = []
        var index = 0
        while index < pcm.count {
            let end = min(index + frame * 3 + 7, pcm.count)
            live += chunker.push(Array(pcm[index..<end]))
            index = end
        }
        XCTAssertEqual(live.count, 2, "chunks are ready while audio still arrives")
        live += chunker.finish()
        XCTAssertEqual(lengths(live), lengths(offline))
        XCTAssertEqual(live.flatMap { $0 }, pcm, "every sample once, in order")
        XCTAssertEqual(made.value, 1, "one stateful scorer for the clip")
        XCTAssertEqual(scored.value, (pcm.count + frame - 1) / frame)
    }

    func testCutsWaitForAPauseToEnd() {
        // At 45 s the pause so far is 34–45 s; the whole pause's midpoint is out
        // of reach, so the plan cuts at 40 s.
        let pcm = clip(probsWithPauses(90, [(34, 50)]))
        let planned = [samples(40), samples(40), pcm.count - samples(80)]

        var (chunker, _, _) = self.chunker()
        var live: [[Float]] = []
        var index = 0
        while index < pcm.count {
            let end = min(index + 16 * frame, pcm.count)
            live += chunker.push(Array(pcm[index..<end]))
            index = end
        }
        live += chunker.finish()
        XCTAssertEqual(lengths(live), planned)
    }

    func testAOneChunkClipNeverLoadsAVAD() {
        let pcm = clip(probsWithPauses(40, [(20, 21)]))
        var (chunker, made, _) = self.chunker()
        var index = 0
        while index < pcm.count {
            let end = min(index + frame, pcm.count)
            XCTAssertTrue(chunker.push(Array(pcm[index..<end])).isEmpty)
            index = end
        }
        XCTAssertEqual(lengths(chunker.finish()), [pcm.count])
        XCTAssertEqual(made.value, 0)
    }

    func testAVADFailureLeavesTheRestInOnePiece() {
        let pcm = longClip()
        var (chunker, _, _) = self.chunker(failOn: 1)
        var chunks: [[Float]] = []
        var index = 0
        while index < pcm.count {
            let end = min(index + frame, pcm.count)
            chunks += chunker.push(Array(pcm[index..<end]))
            index = end
        }
        XCTAssertEqual(chunks.count, 1)
        chunks += chunker.finish()
        XCTAssertEqual(cuts(chunks), [29.5])
        XCTAssertEqual(chunks.flatMap { $0 }, pcm, "no audio lost")
    }
}
