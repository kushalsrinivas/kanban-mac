import XCTest

/// Scheduling is local: parse, persist, and build a brief from the Mac's own data.
final class ScheduledMeetingTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Thursday 19 November 2026, 09:00 UTC.
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19,
                                                 hour: 9, minute: 0))!
    }

    private func parse(_ text: String) -> ScheduledMeetingParseResult {
        ScheduledMeetingParser.parse(text, now: now, calendar: calendar)
    }

    // MARK: Parser

    func testNaturalScheduleCapturesTitleTimePeopleAndDuration() throws {
        let result = parse("schedule a meeting about onboarding with Sarah and Alex tomorrow at 2pm for 45 minutes")
        guard case .draft(let draft) = result else { return XCTFail("expected a draft") }
        XCTAssertEqual(draft.title, "Onboarding")
        XCTAssertEqual(draft.participants, ["Sarah", "Alex"])
        XCTAssertEqual(calendar.component(.day, from: draft.startsAt), 20)
        XCTAssertEqual(calendar.component(.hour, from: draft.startsAt), 14)
        XCTAssertEqual(calendar.component(.minute, from: draft.startsAt), 0)
        XCTAssertEqual(draft.durationMinutes, 45)
    }

    func testNamedMeetingOnAWeekday() throws {
        let result = parse("book a meeting called Design review on friday at 10:30")
        guard case .draft(let draft) = result else { return XCTFail("expected a draft") }
        XCTAssertEqual(draft.title, "Design review")
        XCTAssertEqual(calendar.component(.weekday, from: draft.startsAt), 6) // Friday
        XCTAssertEqual(calendar.component(.hour, from: draft.startsAt), 10)
        XCTAssertEqual(calendar.component(.minute, from: draft.startsAt), 30)
        XCTAssertEqual(draft.durationMinutes, 30)
    }

    func testISODateAndHourDuration() throws {
        let result = parse("schedule a meeting about Q1 planning on 2026-12-01 at 09:30 for an hour")
        guard case .draft(let draft) = result else { return XCTFail("expected a draft") }
        XCTAssertEqual(draft.title, "Q1 planning")
        XCTAssertEqual(calendar.component(.month, from: draft.startsAt), 12)
        XCTAssertEqual(calendar.component(.day, from: draft.startsAt), 1)
        XCTAssertEqual(draft.durationMinutes, 60)
    }

    func testMissingTimeAsksRatherThanGuessing() {
        XCTAssertEqual(parse("schedule a meeting with Sarah tomorrow"), .missingDateTime)
    }

    func testPastTimeIsRejected() {
        XCTAssertEqual(parse("schedule a meeting with Sarah today at 8"), .inThePast)
    }

    func testTitleFallsBackToTheAttendees() throws {
        let result = parse("schedule a meeting with Sarah tomorrow at 2pm")
        guard case .draft(let draft) = result else { return XCTFail("expected a draft") }
        XCTAssertEqual(draft.title, "Meeting with Sarah")
    }

    // MARK: Store

    @MainActor
    func testScheduledMeetingLifecycle() {
        let store = LocalStore(ephemeral: true)
        let meeting = store.upsertScheduledMeeting(ScheduledMeeting(
            title: "Onboarding", startsAt: now.addingTimeInterval(3_600),
            endsAt: now.addingTimeInterval(5_400), participants: ["Sarah"]))
        XCTAssertEqual(store.scheduledMeeting(meeting.id)?.title, "Onboarding")
        XCTAssertEqual(store.scheduledMeetings.upcoming(now: now).count, 1)

        store.updateScheduledMeeting(meeting.id) { $0.title = "Onboarding v2" }
        XCTAssertEqual(store.scheduledMeeting(meeting.id)?.title, "Onboarding v2")

        let recordingID = UUID()
        store.linkScheduledMeeting(meeting.id, to: recordingID)
        XCTAssertEqual(store.scheduledMeeting(meeting.id)?.meetingID, recordingID)

        XCTAssertTrue(store.deleteScheduledMeeting(meeting.id))
        XCTAssertNil(store.scheduledMeeting(meeting.id))
    }

    @MainActor
    func testScheduledMeetingsSurviveReopening() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = LocalStore(url: url)
        first.upsertScheduledMeeting(ScheduledMeeting(
            title: "Persisted", startsAt: now.addingTimeInterval(3_600),
            endsAt: now.addingTimeInterval(5_400), participants: ["Alex"]))
        first.flush()

        let second = LocalStore(url: url)
        XCTAssertEqual(second.scheduledMeetings.map(\.title), ["Persisted"])
        XCTAssertEqual(second.scheduledMeetings.first?.participants, ["Alex"])
    }

    // MARK: Brief

    @MainActor
    func testBriefCrossReferencesHistoryActionsAndConflicts() {
        let store = LocalStore(ephemeral: true)
        let recordedID = UUID()
        let action = ActionItem(meetingID: recordedID, title: "Send the proposal",
                                assignee: "Sarah", dueDate: now.addingTimeInterval(-86_400),
                                confidence: 0.9, state: .suggested, position: 0)
        store.upsertMeeting(Meeting(
            id: recordedID, title: "Product Sync", startedAt: now.addingTimeInterval(-7 * 86_400),
            duration: 1_800, status: .completed,
            summary: "We agreed to keep three tiers.",
            decisions: ["Keep three tiers"],
            participants: ["Sarah", "Kushal"],
            actionItems: [action]))

        let scheduled = store.upsertScheduledMeeting(ScheduledMeeting(
            title: "Onboarding review", startsAt: now.addingTimeInterval(3_600),
            endsAt: now.addingTimeInterval(5_400), participants: ["Sarah"]))
        store.upsertScheduledMeeting(ScheduledMeeting(
            title: "Vendor sync", startsAt: now.addingTimeInterval(4_500),
            endsAt: now.addingTimeInterval(6_300), participants: ["Alex"]))

        let brief = ScheduledBriefBuilder.build(
            for: scheduled, meetings: store.meetings, tasks: store.tasks,
            scheduledMeetings: store.scheduledMeetings, now: now)

        XCTAssertEqual(brief.relatedMeetings.first?.title, "Product Sync")
        XCTAssertEqual(brief.openActions.first?.title, "Send the proposal")
        XCTAssertEqual(brief.decisions.first?.text, "Keep three tiers")
        XCTAssertEqual(brief.conflicts.first?.other.title, "Vendor sync")
        XCTAssertGreaterThan(brief.overdueCount, 0)
        XCTAssertFalse(brief.summary.isEmpty)
        XCTAssertFalse(brief.suggestedSlots.isEmpty, "a conflict should propose another time")
    }
}
