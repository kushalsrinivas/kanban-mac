import XCTest

/// End-to-end agent workflows against a real in-memory store: prompt → engine →
/// typed artifact → validated operation → actual row change. No mock data.
@MainActor
final class AgentWorkspaceTests: XCTestCase {

    private var store: LocalStore!
    private var engine: AgentEngine!
    private var now: Date!
    private var today: Meeting!
    private var yesterday: Meeting!
    private var older: Meeting!
    private var todo: TaskItem!
    private var active: TaskItem!
    private var done: TaskItem!

    override func setUp() {
        super.setUp()
        store = LocalStore(ephemeral: true)
        now = Date()
        engine = AgentEngine(store: store, remotePlayback: true, now: { [weak self] in self?.now ?? Date() })

        let calendar = Calendar.current
        func at(daysAgo: Int, hour: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
        }

        todo = store.createTask(TaskItem(
            title: "Ship the API", notes: "Auth and rate limits.",
            status: .todo, priority: .high,
            dueDate: calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now),
            tags: ["api"]))
        active = store.createTask(TaskItem(
            title: "Write onboarding docs", notes: "", status: .inProgress,
            priority: .medium, dueDate: calendar.date(byAdding: .day, value: -2, to: now),
            tags: ["docs"]))
        done = store.createTask(TaskItem(title: "Old finished thing", status: .done))

        let todayID = UUID()
        let emailItem = ActionItem(meetingID: todayID, title: "Draft the onboarding email",
                                   assignee: "Priya", confidence: 0.8, state: .suggested,
                                   position: 0)
        today = Meeting(
            id: todayID, remoteID: "remote-today", title: "Onboarding sync",
            startedAt: at(daysAgo: 0, hour: 10), duration: 1830, status: .completed,
            summary: "The team agreed to simplify onboarding and ship the new flow this sprint.",
            keyPoints: ["The current flow has five steps", "Three is the target"],
            decisions: ["Use the invite-first flow"],
            questions: ["Who owns the migration?"],
            topics: ["onboarding", "activation"],
            participants: ["Priya", "Sam"],
            actionItems: [emailItem],
            transcript: [])
        store.upsertMeeting(today)
        store.saveTranscript([
            TranscriptSegment(start: 0, end: 6, speaker: "Priya", text: "We need to fix onboarding first."),
            TranscriptSegment(start: 7, end: 14, speaker: "Sam", text: "The new flow drops two steps."),
            TranscriptSegment(start: 20, end: 28, speaker: "Priya", text: "I will draft the email after this.")
        ], for: today.id)

        let yesterdayID = UUID()
        let reviewItem = ActionItem(meetingID: yesterdayID, title: "Measure activation rate",
                                    assignee: "Sam", confidence: 0.7, state: .added,
                                    position: 0)
        yesterday = Meeting(
            id: yesterdayID, remoteID: "remote-yesterday", title: "API review",
            startedAt: at(daysAgo: 1, hour: 15), duration: 2400, status: .completed,
            summary: "Reviewed the API surface and agreed to freeze it on Friday.",
            decisions: ["Freeze the API on Friday"],
            participants: ["Sam", "Alex"],
            actionItems: [reviewItem], transcript: [])
        store.upsertMeeting(yesterday)
        store.saveTranscript([
            TranscriptSegment(start: 3, end: 9, speaker: "Sam", text: "The API freeze is Friday."),
            TranscriptSegment(start: 15, end: 22, speaker: "Alex", text: "I will update the changelog.")
        ], for: yesterday.id)

        older = Meeting(
            id: UUID(), title: "Standup", startedAt: at(daysAgo: 3, hour: 9),
            duration: 600, status: .completed, summary: "", transcript: [])
        store.upsertMeeting(older)
        store.saveTranscript([
            TranscriptSegment(start: 0, end: 5, speaker: "Sam", text: "No blockers today.")
        ], for: older.id)

        // Link the real task behind the accepted action item.
        let linked = store.createTask(TaskItem(
            title: "Update the API changelog", status: .todo, source: .meeting,
            meetingID: yesterday.id, actionItemID: yesterday.actionItems[0].id))
        _ = linked
        store.setActionItemState(yesterday.actionItems[0].id, in: yesterday.id,
                                 to: .added, taskID: linked.id)
        store.updateMeeting(yesterday.id) {
            $0.actionItems[0].state = .added
            $0.actionItems[0].taskID = linked.id
        }
    }

    // MARK: Task cards

    func testTodoReturnsRealTaskCards() {
        var context = AgentContext()
        let turn = engine.run("What's on my todo?", context: &context)

        XCTAssertEqual(turn.artifacts.count, 1)
        guard case .taskList(let list) = turn.artifacts[0].payload else {
            return XCTFail("expected a task list")
        }
        XCTAssertEqual(list.title, "TODO")
        XCTAssertTrue(list.tasks.contains { $0.id == todo.id })
        XCTAssertFalse(list.tasks.contains { $0.id == done.id }, "done rows are not TODO")
        XCTAssertEqual(context.taskIDs.count, list.tasks.count)
        XCTAssertTrue(turn.reply.contains("task"))
    }

    func testOverdueFilterUsesTheStoredDueDate() {
        var context = AgentContext()
        let turn = engine.run("What's overdue?", context: &context)
        guard case .taskList(let list) = turn.artifacts.first?.payload else {
            return XCTFail("expected a task list")
        }
        XCTAssertTrue(list.tasks.contains { $0.id == active.id })
        XCTAssertFalse(list.tasks.contains { $0.id == todo.id })
    }

    func testDueFiltersAreNotMistakenForSearchText() {
        var context = AgentContext()
        let turn = engine.run("tasks with no due date", context: &context)
        guard case .taskList(let list) = turn.artifacts.first?.payload else {
            return XCTFail("expected a task list")
        }
        XCTAssertTrue(list.tasks.allSatisfy { $0.dueDate == nil })
        XCTAssertFalse(list.tasks.contains { $0.id == todo.id })
    }

    func testFinishedTodayUsesTheCompletedTimestamp() {
        store.updateTask(done.id) {
            $0.completedAt = Calendar.current.date(byAdding: .day, value: -1, to: now)
        }
        store.completeTask(todo.id)
        var context = AgentContext()
        let turn = engine.run("what did I finish today?", context: &context)
        guard case .taskList(let list) = turn.artifacts.first?.payload else {
            return XCTFail("expected a task list")
        }
        XCTAssertTrue(list.tasks.contains { $0.id == todo.id })
        XCTAssertFalse(list.tasks.contains { $0.id == done.id }, "done yesterday is not finished today")
    }

    // MARK: The conversation in the brief

    func testMeetingChainResolvesEveryFollowUp() {
        var context = AgentContext()

        let listed = engine.run("Show my recent meetings", context: &context)
        guard case .meetingList(let list) = listed.artifacts.first?.payload else {
            return XCTFail("expected meetings")
        }
        XCTAssertEqual(list.meetings.map(\.id), [today.id, yesterday.id, older.id])
        XCTAssertEqual(context.meetingIDs, [today.id, yesterday.id, older.id])

        let summarized = engine.run("Summarize the second one", context: &context)
        guard case .meetingSummary(let summary) = summarized.artifacts.first?.payload else {
            return XCTFail("expected a summary")
        }
        XCTAssertEqual(summary.meeting.id, yesterday.id)
        XCTAssertEqual(summary.highlights.count, 2)
        XCTAssertEqual(context.lastMeetingID, yesterday.id)

        let actions = engine.run("What tasks came out of it?", context: &context)
        XCTAssertEqual(actions.artifacts.count, 2, "action items plus linked real tasks")
        guard case .actionItems(let items) = actions.artifacts[0].payload else {
            return XCTFail("expected action items")
        }
        XCTAssertEqual(items.meeting?.id, yesterday.id)
        XCTAssertEqual(items.cards.count, 1)
        XCTAssertEqual(items.cards[0].linkedTask?.title, "Update the API changelog")
        guard case .taskList(let linked) = actions.artifacts[1].payload else {
            return XCTFail("expected linked tasks")
        }
        XCTAssertEqual(linked.tasks.map(\.title), ["Update the API changelog"])

        let played = engine.run("Play its recording", context: &context)
        guard case .recording(let recording) = played.artifacts.first?.payload else {
            return XCTFail("expected a recording")
        }
        XCTAssertEqual(recording.meeting.id, yesterday.id)
        XCTAssertTrue(played.autoPlay)
        XCTAssertTrue(recording.isPlayable, "a remote meeting has a playable audio object")
    }

    func testAmbiguousMeetingQuestionAcceptsABareOrdinal() {
        let calendar = Calendar.current
        let extra = Meeting(
            id: UUID(), title: "Design review",
            startedAt: calendar.date(byAdding: .hour, value: -4, to: yesterday.startedAt) ?? yesterday.startedAt,
            duration: 900, status: .completed,
            summary: "Reviewed the empty states.", participants: ["Alex"])
        store.upsertMeeting(extra)
        var context = AgentContext()

        let asked = engine.run("summarize yesterday's meeting", context: &context)
        XCTAssertTrue(asked.reply.contains("Which one?"), asked.reply)

        let picked = engine.run("the first one", context: &context)
        guard case .meetingSummary(let summary) = picked.artifacts.first?.payload else {
            return XCTFail("expected the first meeting's summary")
        }
        XCTAssertEqual(summary.meeting.id, yesterday.id)
    }

    func testBareFollowUpUsesTheMostRecentMeeting() {
        var context = AgentContext()
        _ = engine.run("Show my recent meetings", context: &context)

        let summary = engine.run("Summarize it", context: &context)
        guard case .meetingSummary(let body) = summary.artifacts.first?.payload else {
            return XCTFail("a list of meetings must leave 'it' resolvable")
        }
        XCTAssertEqual(body.meeting.id, today.id)

        let actions = engine.run("What tasks came out of it?", context: &context)
        guard case .actionItems(let items) = actions.artifacts.first?.payload else {
            return XCTFail("expected action items")
        }
        XCTAssertEqual(items.meeting?.id, today.id)
    }

    func testTranscriptSearchAndParticipants() {
        var context = AgentContext()

        let transcript = engine.run("show the transcript of onboarding sync", context: &context)
        guard case .transcript(let body) = transcript.artifacts.first?.payload else {
            return XCTFail("expected a transcript")
        }
        XCTAssertEqual(body.meeting.id, today.id)
        XCTAssertEqual(body.totalCount, 3)
        XCTAssertEqual(body.segments.count, 3)

        let filtered = engine.run("find \"new flow\" in the transcript", context: &context)
        guard case .transcript(let filteredBody) = filtered.artifacts.first?.payload else {
            return XCTFail("expected a filtered transcript")
        }
        XCTAssertEqual(filteredBody.query, "new flow")
        XCTAssertEqual(filteredBody.segments.count, 1)
        XCTAssertTrue(filteredBody.segments[0].text.contains("new flow"))

        let people = engine.run("who was in the onboarding sync?", context: &context)
        guard case .participants(let participants) = people.artifacts.first?.payload else {
            return XCTFail("expected participants")
        }
        XCTAssertEqual(participants.participants.map(\.name), ["Priya", "Sam"])
        XCTAssertEqual(participants.participants.first?.assignedItems.first?.title,
                       "Draft the onboarding email")
    }

    func testSummaryByTopicUsesTheStoredSummary() {
        var context = AgentContext()
        let turn = engine.run("what did we decide about onboarding?", context: &context)
        guard case .meetingSummary(let summary) = turn.artifacts.first?.payload else {
            return XCTFail("expected the onboarding meeting")
        }
        XCTAssertEqual(summary.meeting.id, today.id)
        XCTAssertEqual(summary.meeting.decisions, ["Use the invite-first flow"])
    }

    // MARK: Writes are proposed then executed

    func testCreateOperationWritesARealTask() throws {
        var context = AgentContext()
        let turn = engine.run("create task Write release notes @tomorrow !high #docs >todo", context: &context)
        XCTAssertEqual(turn.operations.count, 1)
        let operation = try XCTUnwrap(turn.operations.first)
        XCTAssertEqual(operation.kind, .createTask)
        XCTAssertEqual(operation.title, "Write release notes")
        XCTAssertEqual(operation.priority, .high)
        XCTAssertEqual(operation.status, .todo)
        XCTAssertEqual(operation.tags, ["docs"])
        XCTAssertNotNil(operation.due)

        try AgentExecutor.apply(operation, store: store, syncEnabled: false)
        let created = try XCTUnwrap(store.tasks.first { $0.title == "Write release notes" })
        XCTAssertEqual(created.priority, .high)
        XCTAssertEqual(created.status, .todo)
        XCTAssertEqual(created.tags, ["docs"])
        XCTAssertEqual(created.source, .agent)
        XCTAssertNotNil(created.dueDate)
    }

    func testRenamePriorityAndDueAreRealUpdates() throws {
        var context = AgentContext()

        let rename = try XCTUnwrap(
            engine.run("rename Ship the API to Ship the v2 API", context: &context).operations.first)
        XCTAssertEqual(rename.kind, .updateTask)
        XCTAssertEqual(rename.title, "Ship the v2 API")
        try AgentExecutor.apply(rename, store: store, syncEnabled: false)
        XCTAssertEqual(store.task(todo.id)?.title, "Ship the v2 API")

        let priority = try XCTUnwrap(
            engine.run("make Ship the v2 API urgent priority", context: &context).operations.first)
        XCTAssertEqual(priority.priority, .urgent)
        try AgentExecutor.apply(priority, store: store, syncEnabled: false)
        XCTAssertEqual(store.task(todo.id)?.priority, .urgent)

        let due = try XCTUnwrap(
            engine.run("set the due date of Ship the v2 API to friday", context: &context).operations.first)
        XCTAssertEqual(due.due, "friday")
        try AgentExecutor.apply(due, store: store, syncEnabled: false)
        XCTAssertNotNil(store.task(todo.id)?.dueDate)
    }

    func testCompleteThenFollowUpSeesTheChange() throws {
        var context = AgentContext()
        _ = engine.run("What's on my todo?", context: &context)
        // The list's first row is the newest TODO; target it explicitly to avoid
        // depending on ordering inside the test.
        let operation = try XCTUnwrap(
            engine.run("complete Ship the API", context: &context).operations.first)
        XCTAssertEqual(operation.kind, .completeTask)
        XCTAssertEqual(operation.taskID, todo.id)

        try AgentExecutor.apply(operation, store: store, syncEnabled: false)
        XCTAssertEqual(store.task(todo.id)?.status, .done)

        let after = engine.run("What's on my todo?", context: &context)
        guard case .taskList(let list) = after.artifacts.first?.payload else {
            return XCTFail("expected a task list")
        }
        XCTAssertFalse(list.tasks.contains { $0.id == todo.id })
    }

    func testMoveIsValidatedAndApplied() throws {
        var context = AgentContext()
        let turn = engine.run("move Ship the API to active", context: &context)
        let operation = try XCTUnwrap(turn.operations.first)
        XCTAssertEqual(operation.kind, .moveTask)
        XCTAssertEqual(operation.status, .inProgress)
        try AgentExecutor.apply(operation, store: store, syncEnabled: false)
        XCTAssertEqual(store.task(todo.id)?.status, .inProgress)
    }

    func testAmbiguousWriteAsksThenAcceptsABareOrdinal() {
        store.createTask(TaskItem(title: "API authentication", status: .todo))
        var context = AgentContext()
        let turn = engine.run("complete the API task", context: &context)
        XCTAssertTrue(turn.operations.isEmpty, "two matches must not become one write")
        guard case .taskList(let list) = turn.artifacts.first?.payload else {
            return XCTFail("expected a choice")
        }
        XCTAssertEqual(list.title, "WHICH TASK?")
        XCTAssertGreaterThanOrEqual(list.tasks.count, 2)

        let picked = engine.run("the first one", context: &context)
        XCTAssertEqual(picked.operations.first?.kind, .completeTask)
        XCTAssertEqual(picked.operations.first?.taskID, list.tasks.first?.id)
    }

    func testDestructiveOperationIsMarked() {
        var context = AgentContext()
        let turn = engine.run("delete Old finished thing", context: &context)
        XCTAssertEqual(turn.operations.first?.kind, .deleteTask)
        XCTAssertEqual(turn.operations.first?.destructive, true)
    }

    func testInventedTaskNeverResolves() {
        var context = AgentContext()
        let turn = engine.run("complete zzzzzzz-not-a-task", context: &context)
        XCTAssertTrue(turn.operations.isEmpty)
        XCTAssertTrue(turn.reply.lowercased().contains("couldn't find"))
    }

    // MARK: Scheduling

    func testScheduleMeetingReturnsAValidatedDraft() throws {
        var context = AgentContext()
        let turn = engine.run(
            "schedule a meeting about onboarding with Priya tomorrow at 2pm for 45 minutes",
            context: &context)

        let draft = try XCTUnwrap(turn.scheduledDraft)
        XCTAssertEqual(draft.title, "Onboarding")
        XCTAssertEqual(draft.participants, ["Priya"])
        XCTAssertEqual(draft.durationMinutes, 45)
        XCTAssertTrue(draft.startsAt > now)
        XCTAssertTrue(turn.reply.contains("PROPOSED OPERATIONS"))
        XCTAssertTrue(turn.operations.isEmpty, "scheduling is confirmed through pending actions")
    }

    func testCalendarListAndBriefUseLocalSchedule() throws {
        let scheduled = store.upsertScheduledMeeting(ScheduledMeeting(
            title: "Onboarding review",
            startsAt: now.addingTimeInterval(3_600),
            endsAt: now.addingTimeInterval(5_400),
            participants: ["Priya"]))

        var context = AgentContext()
        let listed = engine.run("what's on my calendar?", context: &context)
        guard case .scheduledMeetingList(let list) = listed.artifacts.first?.payload else {
            return XCTFail("expected a schedule list")
        }
        XCTAssertEqual(list.meetings.map(\.id), [scheduled.id])
        XCTAssertEqual(context.lastScheduledMeetingID, scheduled.id)

        let brief = engine.run("prepare me for my next meeting", context: &context)
        guard case .scheduledBrief(let value) = brief.artifacts.first?.payload else {
            return XCTFail("expected a scheduled brief")
        }
        XCTAssertEqual(value.brief.scheduled.id, scheduled.id)
        XCTAssertTrue(value.brief.relatedMeetings.contains { $0.title == "Onboarding sync" })
        XCTAssertTrue(value.brief.openActions.contains { $0.title == "Draft the onboarding email" })
        XCTAssertTrue(value.brief.decisions.contains { $0.text == "Use the invite-first flow" })
    }

    func testOpenCalendarUsesTheLocalSelection() {
        let scheduled = store.upsertScheduledMeeting(ScheduledMeeting(
            title: "Review", startsAt: now.addingTimeInterval(3_600),
            endsAt: now.addingTimeInterval(5_400)))
        var context = AgentContext()
        _ = engine.run("what's on my calendar?", context: &context)
        let open = engine.run("open my calendar", context: &context)
        XCTAssertEqual(open.navigation, .calendar(scheduled.id))
    }

    func testEmptyCalendarAndMissingBriefHaveRealEmptyStates() {
        let empty = LocalStore(ephemeral: true)
        let emptyEngine = AgentEngine(store: empty, remotePlayback: false)
        var context = AgentContext()

        let listed = emptyEngine.run("what's on my calendar?", context: &context)
        guard case .scheduledMeetingList(let list) = listed.artifacts.first?.payload else {
            return XCTFail("expected a schedule list")
        }
        XCTAssertTrue(list.meetings.isEmpty)

        let brief = emptyEngine.run("prepare me for my next meeting", context: &context)
        XCTAssertTrue(brief.artifacts.isEmpty)
        XCTAssertTrue(brief.reply.lowercased().contains("couldn't find"))
    }

    // MARK: Navigation

    func testOpenMeetingAndTaskUseRealDestinations() {
        var context = AgentContext()
        _ = engine.run("Show my recent meetings", context: &context)
        let meeting = engine.run("open the second meeting", context: &context)
        XCTAssertEqual(meeting.navigation, .meeting(yesterday.id, focus: nil))

        let byTitle = engine.run("open the standup meeting", context: &context)
        XCTAssertEqual(byTitle.navigation, .meeting(older.id, focus: nil),
                       "reply=\(byTitle.reply) artifacts=\(byTitle.artifacts.map(\.title))")

        _ = engine.run("What's on my todo?", context: &context)
        let task = engine.run("open the first task", context: &context)
        if case .task(let id)? = task.navigation {
            XCTAssertTrue(store.task(id) != nil)
        } else {
            XCTFail("expected a task destination")
        }
    }

    // MARK: Empty and fallback

    func testEmptyBoardAndEmptyMeetingsSaySo() {
        let empty = LocalStore(ephemeral: true)
        let emptyEngine = AgentEngine(store: empty, remotePlayback: false)
        var context = AgentContext()

        let tasks = emptyEngine.run("What's on my todo?", context: &context)
        guard case .taskList(let list) = tasks.artifacts.first?.payload else {
            return XCTFail("expected an empty task list")
        }
        XCTAssertTrue(list.tasks.isEmpty)
        XCTAssertFalse(tasks.reply.isEmpty)

        let meetings = emptyEngine.run("Show my recent meetings", context: &context)
        guard case .meetingList(let meetingList) = meetings.artifacts.first?.payload else {
            return XCTFail("expected an empty meeting list")
        }
        XCTAssertTrue(meetingList.meetings.isEmpty)
    }

    func testStagesAreReportedForARealTurn() {
        var context = AgentContext()
        var stages: [AgentStage] = []
        _ = engine.run("What's on my todo?", context: &context) { stages.append($0) }
        XCTAssertEqual(stages.first, .thinking)
        XCTAssertEqual(stages.last, .done)
        XCTAssertTrue(stages.contains {
            if case .searching = $0 { return true }
            return false
        }, "a task read must report a search stage")
    }

    func testUnknownTopicFallsBackForAModel() {
        var context = AgentContext()
        let turn = engine.run("quantum chromodynamics", context: &context)
        XCTAssertTrue(turn.fallback)
        XCTAssertTrue(turn.artifacts.isEmpty)
    }

    func testKeywordSearchFindsATopic() {
        var context = AgentContext()
        let turn = engine.run("find onboarding", context: &context)
        XCTAssertFalse(turn.fallback)
        XCTAssertFalse(turn.artifacts.isEmpty)
        XCTAssertTrue(turn.artifacts.contains { $0.kind == .meetingList })
        XCTAssertTrue(turn.artifacts.contains { $0.kind == .taskList })
    }

    // MARK: Planner mapping

    func testPlannerMapsTheBriefPhrases() {
        let context = AgentContext()
        if case .taskList(let filter) = AgentPlanner.plan("What's on my todo?", context: context) {
            XCTAssertEqual(filter.status, .todo)
        } else { XCTFail("todo") }

        if case .meetingList = AgentPlanner.plan("Show my recent meetings", context: context) {
        } else { XCTFail("meetings") }

        if case .recording(let selector) = AgentPlanner.plan("Find my last recording", context: context) {
            XCTAssertEqual(selector, .latest)
        } else { XCTFail("recording") }

        if case .summary(let selector) = AgentPlanner.plan("Summarize yesterday's meeting", context: context) {
            if case .day = selector {} else { XCTFail("yesterday selector") }
        } else { XCTFail("summary") }
    }
}
