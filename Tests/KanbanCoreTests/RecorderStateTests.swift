import Foundation
import XCTest

/// Drives `MeetingRecorder` against a fake engine.
///
/// These cover the "Stop doesn't work" class of bug: the recorder and the engine
/// disagreeing, and the UI being left with no way out of a recording state.
@MainActor
final class RecorderStateTests: XCTestCase {

    /// Stands in for the real capture engine. Can be told to fail on demand.
    final class FakeEngine: AudioCaptureEngine {
        weak var delegate: AudioCaptureDelegate?
        var isRecording = false
        var isPaused = false
        var elapsed: TimeInterval = 0
        var sources = CaptureSources(microphone: .ready, systemAudio: .disabled)

        var startError: CaptureError?
        var stopError: CaptureError?
        var bytes: Int64 = 4096
        var peak: Float = 0.6
        private(set) var cancelCount = 0
        private(set) var startedURL: URL?

        static func probeSources(_ request: CaptureRequest) async -> CaptureSources {
            CaptureSources(microphone: .ready, systemAudio: .disabled)
        }

        func requestPermissions(_ request: CaptureRequest) async -> CaptureSources { sources }

        func start(to url: URL, request: CaptureRequest) async throws {
            if let startError { throw startError }
            startedURL = url
            isRecording = true
            // Pretend a file appeared, the way the real engine would.
            try? Data(repeating: 0, count: Int(bytes)).write(to: url)
        }

        func pause() throws { isPaused = true }
        func resume() throws { isPaused = false }

        func stop() async throws -> CaptureResult {
            if let stopError {
                isRecording = false
                throw stopError
            }
            isRecording = false
            return CaptureResult(fileURL: startedURL ?? URL(fileURLWithPath: "/dev/null"),
                                 duration: 42, byteCount: bytes, peakLevel: peak)
        }

        func cancel() async {
            cancelCount += 1
            isRecording = false
            isPaused = false
            if let startedURL { try? FileManager.default.removeItem(at: startedURL) }
        }
    }

    private func makeRecorder() -> (LocalStore, FakeEngine, MeetingRecorder) {
        let store = LocalStore(ephemeral: true)
        let engine = FakeEngine()
        let recorder = MeetingRecorder(store: store, settings: .shared, engine: engine)
        return (store, engine, recorder)
    }

    // MARK: Happy path

    func testStartCreatesARecordingMeeting() async {
        let (store, _, recorder) = makeRecorder()
        await recorder.start()

        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertNotNil(recorder.currentMeetingID)
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(store.activeRecording?.status, .recording)
        XCTAssertNotNil(store.meetings.first?.audioFilename)
    }

    func testStopSavesTheRecordingAndReportsIt() async {
        let (store, _, recorder) = makeRecorder()
        await recorder.start()
        let id = recorder.currentMeetingID!

        let finished = await recorder.stop()

        let result = try? XCTUnwrap(finished)
        XCTAssertEqual(result?.meetingID, id)
        XCTAssertEqual(result?.duration, 42)
        XCTAssertEqual(result?.bytes, 4096)
        XCTAssertEqual(result?.wasSilent, false)
        XCTAssertEqual(recorder.phase, .idle, "stopping no longer asks anything")
        XCTAssertEqual(recorder.lastFinished, finished)
        XCTAssertEqual(store.meeting(id)?.status, .readyToProcess,
                       "the recording is kept and queued for the VPS on its own")
        XCTAssertNil(store.meeting(id)?.failureReason)
        XCTAssertNil(recorder.currentMeetingID)
    }

    func testStopFlagsARecordingThatCapturedOnlySilence() async {
        let (store, engine, recorder) = makeRecorder()
        engine.peak = 0
        await recorder.start()
        let id = recorder.currentMeetingID!

        let finished = await recorder.stop()

        XCTAssertEqual(finished?.wasSilent, true,
                       "macOS hands out silence rather than an error when it blocks a mic")
        XCTAssertEqual(store.meeting(id)?.status, .readyToProcess,
                       "the file is still kept — the user decides whether to transcribe it")
        XCTAssertNotNil(store.meeting(id)?.failureReason, "and it says why it is empty")
        XCTAssertNotNil(recorder.lastError)
    }

    // MARK: The wedge cases

    func testStopStillSettlesWhenTheEngineThrows() async {
        let (store, engine, recorder) = makeRecorder()
        await recorder.start()
        let id = recorder.currentMeetingID!
        engine.stopError = .engine("the engine fell over")

        await recorder.stop()

        XCTAssertEqual(recorder.phase, .idle, "a failed stop must not strand the UI")
        XCTAssertNil(recorder.currentMeetingID)
        XCTAssertEqual(store.meeting(id)?.status, .failed)
        XCTAssertNotNil(store.meeting(id)?.failureReason)
        XCTAssertGreaterThan(engine.cancelCount, 0, "the engine must be forced down")
    }

    func testStopWorksEvenIfTheEngineThinksItIsNotRecording() async {
        let (_, engine, recorder) = makeRecorder()
        await recorder.start()
        // Simulate the disagreement that used to make STOP a no-op.
        engine.isRecording = false

        await recorder.stop()
        XCTAssertNotEqual(recorder.phase, .recording, "STOP must always leave the recording state")
        XCTAssertNil(recorder.currentMeetingID)
    }

    func testForceStopAlwaysReturnsToIdle() async {
        let (store, engine, recorder) = makeRecorder()
        await recorder.start()
        let id = recorder.currentMeetingID!

        await recorder.forceStop()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(recorder.currentMeetingID)
        XCTAssertEqual(recorder.level, 0)
        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertEqual(store.meeting(id)?.status, .failed)
    }

    func testForceStopIsSafeWhenNothingIsRecording() async {
        let (_, _, recorder) = makeRecorder()
        await recorder.forceStop()
        XCTAssertEqual(recorder.phase, .idle)
    }

    func testStopWithNoAudioDoesNotOfferToUpload() async {
        let (store, engine, recorder) = makeRecorder()
        engine.bytes = 0
        await recorder.start()
        let id = recorder.currentMeetingID!

        let finished = await recorder.stop()

        XCTAssertNil(finished, "an empty file must never be handed to the uploader")
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(recorder.lastFinished)
        XCTAssertEqual(store.meeting(id)?.status, .failed)
    }

    func testFailedStartLeavesNoRecordingBehind() async {
        let (store, engine, recorder) = makeRecorder()
        engine.startError = .microphoneDenied

        await recorder.start()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(recorder.currentMeetingID)
        XCTAssertTrue(store.meetings.isEmpty, "a failed start must not leave a stray meeting")
        XCTAssertNotNil(recorder.lastError)
    }

    func testDiscardRemovesTheMeetingEntirely() async {
        let (store, _, recorder) = makeRecorder()
        await recorder.start()
        await recorder.discard()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testPauseAndResumeTrackPhase() async {
        let (_, _, recorder) = makeRecorder()
        await recorder.start()
        recorder.pause()
        XCTAssertEqual(recorder.phase, .paused)
        recorder.resume()
        XCTAssertEqual(recorder.phase, .recording)
    }

    // MARK: Live no-signal hint

    func testNoSignalHintAppearsAfterSustainedSilence() async {
        let (_, _, recorder) = makeRecorder()
        await recorder.start()

        for t in [0.0, 1.0, 2.0, 3.0, 4.0, 6.5] {
            recorder.captureDidUpdate(level: 0, elapsed: t)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(recorder.noSignalHint, "ACTIVE with 5s+ of zeroes must say so live")

        recorder.captureDidUpdate(level: 0.5, elapsed: 7)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(recorder.noSignalHint, "signal returning must clear the hint")
    }

    // MARK: Delegate callbacks from other threads

    func testDelegateCallbacksFromABackgroundThreadDoNotTrap() async {
        let (_, _, recorder) = makeRecorder()
        await recorder.start()

        // The real engine posts these from an audio thread. Calling them off the main
        // actor used to trap; they must now hop instead.
        let done = expectation(description: "posted from a background thread")
        Thread.detachNewThread {
            recorder.captureDidUpdate(level: 0.7, elapsed: 12)
            recorder.captureSourcesDidChange(CaptureSources(microphone: .active, systemAudio: .disabled))
            recorder.captureDidFail(.systemAudioStopped("user stopped sharing"))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)

        // Let the hops land.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recorder.level, 0.7, accuracy: 0.001)
        XCTAssertEqual(recorder.sources.microphone, .active)
        XCTAssertNotNil(recorder.lastError)
    }

    func testSystemAudioStoppingDoesNotStopTheRecording() async {
        let (_, _, recorder) = makeRecorder()
        await recorder.start()

        recorder.captureDidFail(.systemAudioStopped("Stop Sharing"))
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(recorder.phase, .recording,
                       "losing system audio must not end the meeting; the mic continues")
    }
}
