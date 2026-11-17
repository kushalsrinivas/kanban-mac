import XCTest

final class DictationTests: XCTestCase {

    /// 20 ms frames at a given level.
    private func frames(_ level: Float, seconds: Double, into detector: inout DictationSilenceDetector) -> Bool {
        var stop = false
        var elapsed: Double = 0
        while elapsed < seconds {
            stop = detector.add(level: level, seconds: 0.02)
            elapsed += 0.02
            if stop { break }
        }
        return stop
    }

    func testSpeechThenTwoSecondsOfSilenceStops() {
        var detector = DictationSilenceDetector()
        XCTAssertFalse(frames(0.08, seconds: 1.0, into: &detector), "speech alone never stops")
        XCTAssertFalse(frames(0.001, seconds: 1.8, into: &detector))
        XCTAssertTrue(frames(0.001, seconds: 0.4, into: &detector),
                      "two seconds of silence after speech ends the take")
    }

    func testSilenceResetsWhenSpeakingResumes() {
        var detector = DictationSilenceDetector()
        XCTAssertFalse(frames(0.08, seconds: 1.0, into: &detector))
        XCTAssertFalse(frames(0.001, seconds: 1.0, into: &detector))
        XCTAssertFalse(frames(0.08, seconds: 0.5, into: &detector))
        XCTAssertFalse(frames(0.001, seconds: 1.0, into: &detector),
                       "the earlier silence must not carry over")
    }

    func testAShortBlipIsNotSpeech() {
        var detector = DictationSilenceDetector()
        XCTAssertFalse(frames(0.08, seconds: 0.2, into: &detector))
        XCTAssertFalse(frames(0.001, seconds: 5.0, into: &detector),
                       "without minimum speech, silence alone does not stop")
        XCTAssertTrue(frames(0.001, seconds: 1.2, into: &detector),
                      "but nothing at all still gives up")
    }

    func testUnknownLevelsAreIgnored() {
        var detector = DictationSilenceDetector()
        XCTAssertFalse(detector.add(level: 1, seconds: 0))
        XCTAssertEqual(detector.total, 0)
    }
}
