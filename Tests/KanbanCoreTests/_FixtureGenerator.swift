import XCTest

/// Writes the fixtures the Python suite asserts against. Kept in the repo so both
/// sides fail loudly if the wire contract drifts.
@MainActor
final class FixtureGenerator: XCTestCase {

    /// Fixtures live in this repo and are copied into the backend repo by
    /// scripts/sync-contract-fixtures.sh, so each repo's suite is self-contained.
    private var directory: URL {
        // #filePath keeps this working regardless of where the checkout lives.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KanbanCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name))
    }

    /// Not part of a normal test run: it rewrites tracked files, and the timestamps
    /// inside are naturally non-deterministic. Set KANBAN_WRITE_FIXTURES=1 to run it.
    func testGenerateFixtures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KANBAN_WRITE_FIXTURES"] == "1",
                          "set KANBAN_WRITE_FIXTURES=1 to regenerate the wire fixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(ephemeral: true)
        let service = TaskService(store: store, syncEnabled: true)

        let meetingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let actionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        _ = try service.create(CreateTaskBody(
            id: "55555555-5555-5555-5555-555555555555",
            title: "Deploy API", notes: "ship the agent bridge", status: "in_progress",
            priority: "urgent", due: "2026-09-18T17:00:00Z", tags: ["ops"],
            subtasks: ["build image", "run migrations"], source: "meeting",
            meetingId: meetingID.uuidString, actionItemId: actionID.uuidString))
        _ = try service.create(CreateTaskBody(title: "Finish CAD model", status: "todo",
                                              priority: "high"))

        // 1. What POST /tasks sends (an outbox replay body).
        let createOp = store.pendingOperations().first { $0.kind == "task.create" }!
        try createOp.body!.write(to: directory.appendingPathComponent("task_create.json"))

        // 2. The move body.
        try write(MoveBody(status: TaskStatus.inProgress.rawValue, index: 0, position: -1),
                  to: "task_move.json")

        // 3. The agent chat request.
        try write(AgentRequest(
            message: "move my API task into progress",
            history: [.init(role: "user", content: "hi"), .init(role: "assistant", content: "Hello.")],
            context: service.summary(),
            clientVersion: "1.0"), to: "agent_chat.json")

        // 4. The meeting creation body.
        try write(CreateMeetingBody(id: meetingID.uuidString, title: "Product Sync",
                                    startedAt: "2026-09-18T10:30:00Z", duration: 2532),
                  to: "meeting_create.json")

        print("WROTE FIXTURES")
    }

    /// Decoding the server's shapes must not lose anything the UI relies on.
    func testDecodesServerResponses() throws {
        let meetingJSON = """
        {"id":"33333333-3333-3333-3333-333333333333","title":"Product Sync",
         "startedAt":"2026-09-18T10:30:00Z","duration":2532,"status":"completed",
         "summary":"We discussed onboarding.","keyPoints":["a"],"decisions":["Ship Friday"],
         "questions":["Who signs off?"],"topics":["onboarding"],"participants":["Alex"],
         "actionItems":[{"id":"44444444-4444-4444-4444-444444444444","title":"Finish onboarding",
                         "assignee":"Sarah","dueDate":null,"confidence":0.91,"state":"suggested","taskId":null}],
         "transcript":{"segments":[{"id":null,"start":3.0,"end":8.0,"speaker":"Alex","text":"hello"}],
                       "language":"en","duration":2532},
         "jobId":"job-1","error":null}
        """
        let meeting = try XCTUnwrap(
            try JSONDecoder().decode(MeetingDTO.self, from: Data(meetingJSON.utf8)).merged(into: nil))
        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.decisions, ["Ship Friday"])
        XCTAssertEqual(meeting.actionItems.first?.confidence ?? 0, 0.91, accuracy: 0.001)
        XCTAssertEqual(meeting.actionItems.first?.state, .suggested)
        XCTAssertEqual(meeting.transcript.first?.speaker, "Alex")

        let taskJSON = """
        {"id":"55555555-5555-5555-5555-555555555555","title":"Deploy API","notes":"",
         "status":"in_progress","priority":"urgent","due":"2026-09-18T17:00:00Z","tags":["ops"],
         "subtasks":[{"id":"66666666-6666-6666-6666-666666666666","title":"step","done":true}],
         "position":-1,"created":"2026-09-18T09:00:00Z","updated":"2026-09-18T09:00:00Z",
         "completed":null,"archived":null,"source":"meeting",
         "meetingId":"33333333-3333-3333-3333-333333333333",
         "actionItemId":"44444444-4444-4444-4444-444444444444","overdue":false,"dueToday":true}
        """
        let task = try XCTUnwrap(
            try JSONDecoder().decode(TaskDTO.self, from: Data(taskJSON.utf8)).toTask())
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.priority, .urgent)
        XCTAssertEqual(task.source, .meeting)
        XCTAssertEqual(task.subtasks.first?.isDone, true)

        let jobJSON = """
        {"id":"job-1","status":"running","stage":"transcribing","progress":0.42,
         "error":null,"meetingId":"33333333-3333-3333-3333-333333333333"}
        """
        let job = try JSONDecoder().decode(JobDTO.self, from: Data(jobJSON.utf8))
        XCTAssertEqual(job.meetingStatus, .transcribing)

        let agentJSON = """
        {"reply":"Moving it.","pending_actions":[{"id":"a1","tool":"move_task",
          "summary":"DEPLOY API · TODO → IN_PROGRESS","destructive":false,"applied":false}],
         "applied_actions":null,"tasks_changed":null}
        """
        let agent = try JSONDecoder().decode(AgentResponse.self, from: Data(agentJSON.utf8))
        XCTAssertEqual(agent.reply, "Moving it.")
        XCTAssertEqual(agent.pendingActions?.first?.tool, "move_task")
        XCTAssertEqual(agent.pendingActions?.first?.destructive, false)
    }
}
