import XCTest

/// The agent's write path: natural reminders become real dated tasks without a
/// second confirmation, while delete/archive stay proposals.
@MainActor
final class AgentCRUDTests: XCTestCase {

    private var store: LocalStore!
    private var settings: AppSettings!
    private var client: APIClient!
    private var sync: SyncEngine!

    override func setUp() {
        super.setUp()
        setenv("KANBAN_DEFAULTS_SUITE", "com.kanban.tests.crud.\(UUID().uuidString)", 1)
        store = LocalStore(ephemeral: true)
        settings = AppSettings.testing()
        client = APIClient()
        sync = SyncEngine(store: store, client: client)
    }

    private func session() -> AgentSession { session(model: NoopModel()) }

    private func session(model: AgentModelProvider) -> AgentSession {
        AgentSession(store: store, client: client, settings: settings, sync: sync,
                     model: model, requestTimeout: 2)
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testNaturalDueAndTimeAreRemovedFromTheTitle() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19,
                                                     hour: 9, minute: 0))!
        let parsed = QuickParse.parse("Call Sarah tomorrow at 5pm", now: now)

        XCTAssertEqual(parsed.title, "Call Sarah")
        let due = try XCTUnwrap(parsed.due)
        XCTAssertEqual(calendar.component(.day, from: due), 20)
        XCTAssertEqual(calendar.component(.hour, from: due), 17)
        XCTAssertEqual(calendar.component(.minute, from: due), 0)
    }

    func testRelativeReminderUsesAnExactTime() throws {
        let now = Date()
        let parsed = QuickParse.parse("Send the deck in 2 hours", now: now)
        XCTAssertEqual(parsed.title, "Send the deck")
        let due = try XCTUnwrap(parsed.due)
        XCTAssertEqual(due.timeIntervalSince(now), 7_200, accuracy: 5)
    }

    func testTimeOnlyReminderAndPossessiveTitle() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19,
                                                     hour: 9, minute: 0))!

        let evening = QuickParse.parse("Call Sarah at 5pm", now: now)
        XCTAssertEqual(evening.title, "Call Sarah")
        let due = try XCTUnwrap(evening.due)
        XCTAssertEqual(calendar.component(.hour, from: due), 17)
        XCTAssertEqual(calendar.component(.day, from: due), 19)

        let possessive = QuickParse.parse("Review today's numbers", now: now)
        XCTAssertEqual(possessive.title, "Review today's numbers")
        XCTAssertNil(possessive.due, "a possessive is not a due date")
    }

    func testQuantifiedAddIsAWriteNotATaskList() {
        var context = AgentContext()
        guard case .askModel = AgentPlanner.plan("add some sample todo items please",
                                                 context: context) else {
            return XCTFail("a quantified add must be handled by the model, not a TODO list read")
        }
    }

    func testLongBrainDumpGoesToTheModelAndCreatesEveryTask() async throws {
        let prompt = "add these todo basically i need to work on few stuff one is courses folio website completion and setting it up secondly newstok ai processing to be moved to the phone and then cleriko app submission and then introduction of haven to the desktop world aswell"
        var context = AgentContext()
        guard case .askModel = AgentPlanner.plan(prompt, context: context) else {
            return XCTFail("a long multi-task brain dump should be handed to the model")
        }

        let model = MultiCreateModel(titles: [
            "Courses folio website completion and setup",
            "Move newstok AI processing to the phone",
            "Cleriko app submission",
            "Introduce Haven to the desktop world"
        ])
        let agent = session(model: model)
        agent.send(prompt)
        await waitUntil { !agent.isBusy }

        XCTAssertEqual(Set(store.tasks.map(\.title)), Set([
            "Courses folio website completion and setup",
            "Move newstok AI processing to the phone",
            "Cleriko app submission",
            "Introduce Haven to the desktop world"
        ]))
        XCTAssertTrue(agent.pending.isEmpty, "safe creates from the model apply immediately")
        XCTAssertEqual(agent.messages.filter { $0.kind == .applied }.count, 4)
    }

    func testAgentJSONDecoderToleratesFencesAndRepeatedObjects() throws {
        let object = """
        {"reply":"Added them.","actions":[{"tool":"create_task","title":"One"},{"tool":"create_task","title":"Two"}]}
        """
        let fenced = "```json\n\(object)\n```"
        let reply = try GeminiClient.decodeAgentReply(from: Data(fenced.utf8))
        XCTAssertEqual(reply.reply, "Added them.")
        XCTAssertEqual(reply.actions.map(\.title), ["One", "Two"])

        let repeated = object + "\n" + object
        let second = try GeminiClient.decodeAgentReply(from: Data(repeated.utf8))
        XCTAssertEqual(second.actions.count, 2)
    }

    func testCreateReminderIsATaskNotACalendarMeeting() {
        var context = AgentContext()
        let engine = AgentEngine(store: store)
        let turn = engine.run("create a reminder to call Sarah tomorrow at 5pm",
                              context: &context)
        XCTAssertEqual(turn.operations.first?.kind, .createTask)
        XCTAssertEqual(turn.operations.first?.title, "call Sarah")
        XCTAssertNotNil(turn.operations.first?.due)
        XCTAssertNil(turn.scheduledDraft, "a reminder must not become a calendar event")
    }

    func testSafeWriteAppliesWithoutExecute() async throws {
        let agent = session()
        agent.send("create a todo Call Sarah tomorrow at 5pm")
        await waitUntil { !agent.isBusy }

        let task = try XCTUnwrap(store.tasks.first { $0.title == "Call Sarah" })
        XCTAssertEqual(task.source, .agent)
        let due = try XCTUnwrap(task.dueDate)
        XCTAssertEqual(Calendar.current.component(.hour, from: due), 17)
        XCTAssertTrue(agent.pending.isEmpty, "a safe create should not wait for EXECUTE")
        XCTAssertTrue(agent.messages.contains { $0.kind == .applied })
    }

    func testUpdateAndCompleteApplyImmediately() async throws {
        let task = store.createTask(TaskItem(title: "Call Sarah", status: .todo))
        let agent = session()

        agent.send("set the due date of Call Sarah to friday")
        await waitUntil { !agent.isBusy }
        XCTAssertNotNil(store.task(task.id)?.dueDate)
        XCTAssertTrue(agent.pending.isEmpty)

        agent.send("complete Call Sarah")
        await waitUntil { !agent.isBusy }
        XCTAssertEqual(store.task(task.id)?.status, .done)
        XCTAssertTrue(agent.pending.isEmpty)
    }

    func testDestructiveDeleteStillNeedsConfirmation() async throws {
        let task = store.createTask(TaskItem(title: "Old draft", status: .todo))
        let agent = session()

        agent.send("delete Old draft")
        await waitUntil { !agent.isBusy }

        XCTAssertNotNil(store.task(task.id), "delete must not run without EXECUTE")
        XCTAssertEqual(agent.pending.first?.tool, "delete_task")

        await agent.execute(try XCTUnwrap(agent.pending.first))
        XCTAssertNil(store.task(task.id), "the confirmed delete removes the row")
    }

    func testAutoApplyCanBeTurnedOff() async throws {
        settings.agentAutoApplyWrites = false
        let agent = session()
        agent.send("create a todo Buy milk")
        await waitUntil { !agent.isBusy }

        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(agent.pending.first?.tool, "create_task")
    }
}


private final class NoopModel: AgentModelProvider, @unchecked Sendable {
    func reply(prompt: String, history: [(role: String, content: String)],
               boardContext: String, meetingContext: String,
               onText: @Sendable @escaping (String) async -> Void) async throws -> LocalAgentReply {
        LocalAgentReply(reply: "", actions: [])
    }
}


private final class MultiCreateModel: AgentModelProvider, @unchecked Sendable {
    let titles: [String]

    init(titles: [String]) { self.titles = titles }

    func reply(prompt: String, history: [(role: String, content: String)],
               boardContext: String, meetingContext: String,
               onText: @Sendable @escaping (String) async -> Void) async throws -> LocalAgentReply {
        LocalAgentReply(reply: "Added them.", actions: titles.map {
            LocalAgentReply.Action(tool: "create_task", taskId: nil, title: $0,
                                   notes: nil, status: "todo", priority: nil,
                                   due: nil, tags: nil)
        })
    }
}
