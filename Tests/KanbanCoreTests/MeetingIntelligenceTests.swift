import XCTest

/// The local meeting brain: commitments with sources, memory search and answers,
/// contradiction candidates, brief enrichment and local automation.
final class MeetingIntelligenceTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19,
                                                 hour: 9, minute: 0))!
    }

    private func meeting(_ title: String, daysAgo: Int = 0,
                         decisions: [String] = [], questions: [String] = [],
                         participants: [String] = ["Sarah", "Alex"],
                         actions: [ActionItem] = []) -> Meeting {
        Meeting(title: title, startedAt: now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400),
                duration: 1_800, status: .completed,
                summary: "\(title) summary.", decisions: decisions, questions: questions,
                participants: participants, actionItems: actions)
    }

    // MARK: Commitments

    func testQuotesLinkToTranscriptSegments() {
        let segments = [
            TranscriptSegment(start: 0, end: 6, speaker: "Alex",
                              text: "We should launch the new onboarding next week."),
            TranscriptSegment(start: 6, end: 12, speaker: "Sarah",
                              text: "I can finish the new screens by Wednesday."),
            TranscriptSegment(start: 12, end: 18, speaker: "Alex",
                              text: "Let's decide to ship on Friday, and someone needs to review the API changes.")
        ]
        var source = meeting("Product Sync", actions: [
            ActionItem(meetingID: UUID(), title: "Finish screens",
                       quote: "I can finish the new screens by Wednesday."),
            ActionItem(meetingID: UUID(), title: "Review API changes")
        ])
        source = MeetingMemory.attachSources(to: source, segments: segments)

        XCTAssertEqual(source.actionItems[0].sourceStart, 6)
        XCTAssertEqual(source.actionItems[0].sourceEnd, 12)
        XCTAssertEqual(source.actionItems[1].sourceStart, 12,
                       "a paraphrased title still finds its segment")
        XCTAssertEqual(source.actionItems[1].quote,
                       segments[2].text)
    }

    @MainActor
    func testCommitmentStateAndSourceSurviveReopening() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("commitments-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let meetingID = UUID()
        let itemID = UUID()
        let first = LocalStore(url: url)
        first.upsertMeeting(meeting("Product Sync", actions: [
            ActionItem(id: itemID, meetingID: meetingID, title: "Send the proposal",
                       assignee: "Sarah", dueDate: now.addingTimeInterval(-3_600),
                       quote: "I'll send the proposal by Friday", sourceStart: 42,
                       sourceEnd: 48, commitmentState: .open)
        ]))
        first.flush()

        let second = LocalStore(url: url)
        let stored = try XCTUnwrap(second.commitment(itemID)?.item)
        XCTAssertEqual(stored.quote, "I'll send the proposal by Friday")
        XCTAssertEqual(stored.sourceStart, 42)
        XCTAssertTrue(stored.isOverdue(now: now))
        XCTAssertTrue(stored.needsReminder(now: now))

        second.setCommitmentState(itemID, in: meetingID, to: .done, now: now)
        let done = try XCTUnwrap(second.commitment(itemID)?.item)
        XCTAssertEqual(done.commitmentState, .done)
        XCTAssertEqual(done.completedAt, now)
        XCTAssertFalse(done.isOverdue(now: now))
        XCTAssertFalse(done.needsReminder(now: now))
    }

    @MainActor
    func testCompletingACommitmentCompletesItsTask() throws {
        let store = LocalStore(ephemeral: true)
        let meetingID = UUID()
        let itemID = UUID()
        let task = store.createTask(TaskItem(title: "Send the proposal", source: .meeting,
                                             meetingID: meetingID, actionItemID: itemID))
        store.upsertMeeting(meeting("Product Sync", actions: [
            ActionItem(id: itemID, meetingID: meetingID, title: "Send the proposal",
                       state: .added, taskID: task.id)
        ]))

        store.setCommitmentState(itemID, in: meetingID, to: .done)
        XCTAssertEqual(store.task(task.id)?.status, .done)

        store.setCommitmentState(itemID, in: meetingID, to: .open)
        XCTAssertEqual(store.task(task.id)?.status, .todo,
                       "reopening the promise reopens the same task")
    }

    // MARK: Memory

    func testSearchSpansHistoryAndTrimsByDateAndPerson() {
        let meetingID = UUID()
        let action = ActionItem(meetingID: meetingID, title: "Send the proposal",
                                assignee: "Sarah", quote: "I'll send it Friday")
        let earlier = meeting("Pricing review", daysAgo: 90,
                              decisions: ["We approved the enterprise pricing strategy."])
        let later = meeting("Pricing retro", daysAgo: 5,
                            decisions: ["We rejected the enterprise pricing strategy."],
                            questions: ["What replaces enterprise pricing?"],
                            actions: [action])

        let all = MeetingMemory.search("enterprise pricing", meetings: [earlier, later])
        XCTAssertEqual(Set(all.map(\.meetingID)), [earlier.id, later.id])
        XCTAssertTrue(all.contains { $0.kind == .decision })

        let recent = MeetingMemory.search("enterprise pricing", meetings: [earlier, later],
                                          since: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(Set(recent.map(\.meetingID)), [later.id])

        let byPerson = MeetingMemory.search("pricing", meetings: [earlier, later],
                                            participant: "sarah")
        XCTAssertFalse(byPerson.isEmpty)
        let nobody = MeetingMemory.search("pricing", meetings: [earlier, later],
                                          participant: "Nobody")
        XCTAssertTrue(nobody.isEmpty)
    }

    func testDuplicateMeetingRowsCannotCrashSearch() {
        // SQLite primary keys are text and therefore case-sensitive. A database
        // written by two clients can hold the same UUID twice; search must still work.
        let recorded = meeting("Pricing review", decisions: ["We rejected pricing."])
        let hits = MeetingMemory.search("pricing", meetings: [recorded, recorded])
        XCTAssertFalse(hits.isEmpty)
    }

    func testTranscriptWordsAreSearchableWithTheirTimestamp() {
        let recorded = meeting("Product Sync", daysAgo: 2)
        let segments = [
            TranscriptSegment(start: 0, end: 6, text: "Unrelated intro"),
            TranscriptSegment(start: 6, end: 12, text: "I can finish the new screens by Wednesday.")
        ]
        let hits = MeetingMemory.search("screens by Wednesday", meetings: [recorded],
                                        transcripts: [recorded.id: segments])
        let transcript = hits.first { $0.kind == .transcript }
        XCTAssertEqual(transcript?.entry.start, 6)
        XCTAssertEqual(transcript?.meetingID, recorded.id)
    }

    func testAnswerExplainsAReversedDecisionWithCitations() {
        let earlier = meeting("Pricing review", daysAgo: 90,
                              decisions: ["We approved the enterprise pricing strategy."])
        let later = meeting("Pricing retro", daysAgo: 5,
                            decisions: ["We rejected the enterprise pricing strategy because margins were too thin."])

        let answer = MeetingMemory.answer("Why did we reject the previous pricing strategy?",
                                          meetings: [earlier, later])
        XCTAssertTrue(answer.confident)
        XCTAssertTrue(answer.answer.contains("That changed"), answer.answer)
        XCTAssertTrue(answer.answer.lowercased().contains("rejected"))
        XCTAssertEqual(answer.citations.count, 2)
        XCTAssertGreaterThanOrEqual(answer.answer.components(separatedBy: "\n\n").count, 2)
    }

    func testEmptyQuestionSaysSoRatherThanInventing() {
        let answer = MeetingMemory.answer("What did we decide about penguins?",
                                          meetings: [meeting("Product Sync")])
        XCTAssertFalse(answer.confident)
        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertTrue(answer.answer.lowercased().contains("could not find"))
    }

    func testContradictionsFindApprovedThenRejected() {
        let earlier = meeting("Pricing review", daysAgo: 90,
                              decisions: ["We approved the enterprise pricing strategy."])
        let later = meeting("Pricing retro", daysAgo: 5,
                            decisions: ["We rejected the enterprise pricing strategy."])

        let pairs = MeetingMemory.contradictions(meetings: [earlier, later])
        let pair = try? XCTUnwrap(pairs.first)
        XCTAssertEqual(pair?.earlier.meetingID, earlier.id)
        XCTAssertEqual(pair?.later.meetingID, later.id)
        XCTAssertGreaterThan(pair?.similarity ?? 0, 0.25)
        XCTAssertTrue(pair?.reason.lowercased().contains("opposite") == true)
    }

    func testServerDTOKeepsCommitmentSourceAndExecutionState() throws {
        let dto = ActionItemDTO(
            id: "C0000000-0000-4000-8000-000000000001",
            title: "Send the proposal", assignee: "Sarah",
            dueDate: "2026-11-20", confidence: 0.9, state: "added",
            taskId: nil, quote: "I'll send it by Friday",
            sourceStart: 62, sourceEnd: 68, commitmentState: "done",
            completedAt: "2026-11-19T09:00:00Z",
            remindedAt: "2026-11-18T09:00:00Z")
        let item = try XCTUnwrap(dto.toActionItem(meetingID: UUID(), position: 0))
        XCTAssertEqual(item.quote, "I'll send it by Friday")
        XCTAssertEqual(item.sourceStart, 62)
        XCTAssertEqual(item.commitmentState, .done)
        XCTAssertNotNil(item.completedAt)
        XCTAssertNotNil(item.remindedAt)
    }

    // MARK: Follow-up composition

    func testFollowUpContainsSummaryDecisionsAndOpenCommitments() {
        let recorded = meeting("Client kickoff", decisions: ["Ship on Friday"],
                               actions: [ActionItem(meetingID: UUID(),
                                                    title: "Send the proposal",
                                                    assignee: "Sarah",
                                                    dueDate: now)])
        let body = FollowUpComposer.followUp(meeting: recorded).body
        XCTAssertTrue(body.contains("Client kickoff"))
        XCTAssertTrue(body.contains("Ship on Friday"))
        XCTAssertTrue(body.contains("Send the proposal"))
        XCTAssertTrue(body.contains("Sarah"))

        let reminder = FollowUpComposer.reminder(
            commitment: ActionItem(meetingID: recorded.id, title: "Send the proposal",
                                   quote: "I'll send it by Friday", sourceStart: 62),
            meeting: recorded)
        XCTAssertEqual(reminder.kind, .notification)
        XCTAssertTrue(reminder.body.contains("\"I'll send it by Friday\""))
        XCTAssertTrue(reminder.body.contains("1:02"))
    }

    // MARK: Automations

    func testRuleConditionsAndPlanner() {
        let rule = AutomationRule(
            name: "Client follow-up",
            conditions: AutomationConditions(titleContains: "Client", hasDecisions: true),
            actions: [.summaryEmail(), .createTasks(minConfidence: 0.8)])
        let client = meeting("Client kickoff", decisions: ["Ship"],
                             actions: [ActionItem(meetingID: UUID(), title: "One",
                                                  confidence: 0.9),
                                       ActionItem(meetingID: UUID(), title: "Two",
                                                  confidence: 0.2)])
        let internalMeeting = meeting("Internal sync", decisions: ["Ship"])

        XCTAssertTrue(AutomationPlanner.matches(rule, meeting: client))
        XCTAssertFalse(AutomationPlanner.matches(rule, meeting: internalMeeting))
        let plan = AutomationPlanner.plan(rule, meeting: client)
        XCTAssertEqual(plan.map(\.type), ["email.summary", "tasks.create"])
    }

    @MainActor
    func testRulesRunsAndMessagesPersist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = LocalStore(url: url)
        var rule = AutomationRule.standardFollowUp()
        rule.conditions.titleContains = "Client"
        first.upsertAutomationRule(rule)
        let meetingID = UUID()
        first.recordAutomationRun(AutomationRun(
            ruleID: rule.id, ruleName: rule.name, meetingID: meetingID,
            status: .completed, detail: "created 2 tasks", startedAt: now, finishedAt: now))
        first.addLocalMessage(FollowUpComposer.summary(meeting: meeting("Client kickoff")))
        first.flush()

        let second = LocalStore(url: url)
        XCTAssertEqual(second.automationRules.first?.name, "Meeting follow-up")
        XCTAssertEqual(second.automationRules.first?.conditions.titleContains, "Client")
        XCTAssertEqual(second.automationRules.first?.actions.count, 4)
        XCTAssertEqual(second.automationRuns.first?.detail, "created 2 tasks")
        XCTAssertEqual(second.localMessages.first?.subject, "Meeting summary: Client kickoff")
        XCTAssertEqual(second.localMessages.first?.status, .draft)
    }

    func testFreeTimeSkipsBusyIntervals() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20,
                                                       hour: 9, minute: 0))!
        let busy = [DateInterval(start: start, end: start.addingTimeInterval(1_800))]
        let slots = FreeTimeFinder.slots(duration: 1_800, after: start, days: 1,
                                         busy: busy, calendar: calendar)
        XCTAssertEqual(slots.first?.start, start.addingTimeInterval(1_800))
        // Slots are half-open: a slot may start exactly when the busy block ends
        // without taking any of its time.
        XCTAssertFalse(slots.contains { $0.start < busy[0].end && busy[0].start < $0.end })
    }
}
