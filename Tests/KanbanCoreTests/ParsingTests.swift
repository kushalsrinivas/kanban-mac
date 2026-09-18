import XCTest

final class ParsingTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_758_153_600)   // 18 Sep 2026

    // MARK: Dates

    func testRelativeKeywords() {
        XCTAssertTrue(calendar.isDate(DateInput.parse("today", now: now)!, inSameDayAs: now))
        let tomorrow = DateInput.parse("tomorrow", now: now)!
        XCTAssertTrue(calendar.isDate(tomorrow, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
        XCTAssertNil(DateInput.parse("none", now: now))
        XCTAssertNil(DateInput.parse("", now: now))
    }

    func testOffsetsAndWeekdays() {
        XCTAssertEqual(calendar.dateComponents([.day], from: now, to: DateInput.parse("+3d", now: now)!).day, 3)
        XCTAssertEqual(calendar.dateComponents([.day], from: now, to: DateInput.parse("2w", now: now)!).day, 14)
        let friday = DateInput.parse("friday", now: now)!
        XCTAssertGreaterThan(friday, now)
        XCTAssertEqual(calendar.component(.weekday, from: friday), 6)
    }

    func testISOAndLooseFormats() {
        XCTAssertNotNil(DateInput.parse("2026-09-18T10:00:00Z"))
        XCTAssertNotNil(DateInput.parse("2026-09-18T10:00:00.123Z"))
        XCTAssertNotNil(DateInput.parse("2026-09-18"))
        XCTAssertNotNil(DateInput.parse("18 sep", now: now))
        XCTAssertNil(DateInput.parse("sometime next quarter", now: now))
    }

    func testRoundTripISO() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DateInput.parse(DateInput.iso(date))?.timeIntervalSince1970 ?? 0,
                       date.timeIntervalSince1970, accuracy: 1)
    }

    func testShortLabels() {
        XCTAssertEqual(DateInput.shortLabel(now, now: now, calendar: calendar), "TODAY")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(DateInput.shortLabel(tomorrow, now: now, calendar: calendar), "TMRW")
    }

    // MARK: Quick add

    func testQuickParseExtractsTokens() {
        let r = QuickParse.parse("Fix auth bug !high #backend #ops @tomorrow >todo", now: now)
        XCTAssertEqual(r.title, "Fix auth bug")
        XCTAssertEqual(r.priority, .high)
        XCTAssertEqual(r.tags, ["backend", "ops"])
        XCTAssertEqual(r.status, .todo)
        XCTAssertNotNil(r.due)
    }

    func testQuickParseUnderstandsInProgress() {
        XCTAssertEqual(QuickParse.parse("do it >active", now: now).status, .inProgress)
        XCTAssertEqual(QuickParse.parse("do it >in_progress", now: now).status, .inProgress)
    }

    func testQuickParseKeepsUnrecognisedTokensInTitle() {
        let r = QuickParse.parse("Email bob@example.com about !stuff >nowhere", now: now)
        XCTAssertTrue(r.title.contains("bob@example.com"))
        XCTAssertTrue(r.title.contains("!stuff"))
        XCTAssertNil(r.priority)
        XCTAssertNil(r.status)
    }

    // MARK: Enums

    func testStatusParsingAliases() {
        XCTAssertEqual(TaskStatus.parse("In Progress"), .inProgress)
        XCTAssertEqual(TaskStatus.parse("doing"), .inProgress)
        XCTAssertEqual(TaskStatus.parse("in_progress"), .inProgress)
        XCTAssertEqual(TaskStatus.parse("BACKLOG"), .todo)
        XCTAssertNil(TaskStatus.parse("nowhere"))
        XCTAssertEqual(TaskStatus.inProgress.rawValue, "in_progress", "wire value is the contract")
        XCTAssertEqual(TaskStatus.inProgress.label, "ACTIVE")
    }

    func testPriorityParsingAliases() {
        XCTAssertEqual(Priority.parse("URGENT"), .urgent)
        XCTAssertEqual(Priority.parse("med"), .medium)
        XCTAssertEqual(Priority.parse("asap"), .urgent)
        XCTAssertNil(Priority.parse("whenever"))
    }

    // MARK: Meeting formatting

    func testDurationAndTimecodeLabels() {
        XCTAssertEqual(Meeting.durationLabel(42), "42 SEC")
        XCTAssertEqual(Meeting.durationLabel(2_532), "42 MIN")
        XCTAssertEqual(Meeting.durationLabel(3_600 + 7 * 60), "1H 07M")
        XCTAssertEqual(Meeting.timecode(0), "00:00")
        XCTAssertEqual(Meeting.timecode(1_458), "24:18")
        XCTAssertEqual(Meeting.timecode(3_872), "1:04:32")
    }

    func testMeetingStatusPipelineFlags() {
        XCTAssertTrue(MeetingStatus.transcribing.isProcessing)
        XCTAssertFalse(MeetingStatus.readyToProcess.isProcessing)
        XCTAssertTrue(MeetingStatus.completed.isTerminal)
        XCTAssertTrue(MeetingStatus.failed.isTerminal)
    }

    func testAwaitsUploadOnlyWhenAudioIsStillPresent() {
        var meeting = Meeting(title: "m", status: .readyToProcess, audioFilename: "a.m4a")
        XCTAssertTrue(meeting.awaitsUpload)
        meeting.audioFilename = nil
        XCTAssertFalse(meeting.awaitsUpload, "nothing to upload once the file is gone")
        meeting.audioFilename = "a.m4a"
        meeting.status = .completed
        XCTAssertFalse(meeting.awaitsUpload)
    }

    // MARK: Snapshot

    func testSnapshotCountsAndAgenda() {
        let now = Date()
        let tasks = [
            TaskItem(title: "late", status: .todo, dueDate: now.addingTimeInterval(-86_400 * 3)),
            TaskItem(title: "today", status: .todo, dueDate: now),
            TaskItem(title: "active", status: .inProgress),
            TaskItem(title: "someday", status: .inbox, priority: .low)
        ]
        let snap = BoardSnapshot.make(from: tasks, now: now)
        XCTAssertEqual(snap.openCount, 4)
        XCTAssertEqual(snap.activeCount, 1)
        XCTAssertEqual(snap.dueTodayCount, 1)
        XCTAssertEqual(snap.overdueCount, 1)
        XCTAssertEqual(snap.agenda.first?.title, "late", "overdue sorts first")
        XCTAssertNil(snap.recording)
    }

    func testSnapshotCarriesRecordingState() {
        let started = Date()
        let snap = BoardSnapshot.make(from: [],
                                      recording: .init(title: "Client call", startedAt: started))
        XCTAssertEqual(snap.recording?.title, "Client call")
        XCTAssertEqual(snap.recording?.startedAt.timeIntervalSince1970 ?? 0,
                       started.timeIntervalSince1970, accuracy: 1)
    }

    func testSnapshotFallsBackToOpenTasksWhenNothingScheduled() {
        let tasks = [TaskItem(title: "a", priority: .low), TaskItem(title: "b", priority: .low)]
        XCTAssertEqual(BoardSnapshot.make(from: tasks).agenda.count, 2,
                       "the widget should never be blank while work exists")
    }

    func testSnapshotRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = BoardSnapshot.make(from: [TaskItem(title: "x", dueDate: Date())],
                                      recording: .init(title: "rec", startedAt: Date()),
                                      suggestedCount: 3)
        snap.write(to: url)
        let read = try XCTUnwrap(BoardSnapshot.read(from: url))
        XCTAssertEqual(read.openCount, snap.openCount)
        XCTAssertEqual(read.agenda.first?.title, "x")
        XCTAssertEqual(read.recording?.title, "rec")
        XCTAssertEqual(read.suggestedCount, 3)
    }

    func testSnapshotReadFailuresAreSafe() throws {
        XCTAssertNil(BoardSnapshot.read(from: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(BoardSnapshot.read(from: url))
    }

    // MARK: Capture source reporting

    func testCaptureSourcesSilentDetection() {
        XCTAssertTrue(CaptureSources(microphone: .denied, systemAudio: .denied).isSilent)
        XCTAssertTrue(CaptureSources(microphone: .disabled, systemAudio: .unavailable("x")).isSilent)
        XCTAssertFalse(CaptureSources(microphone: .active, systemAudio: .denied).isSilent)
        XCTAssertEqual(CaptureSources.State.unavailable("no device").detail, "no device")
    }
}
