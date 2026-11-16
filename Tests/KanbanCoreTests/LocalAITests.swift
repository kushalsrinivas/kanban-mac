import XCTest

/// The local AI path: whatever Gemini sends back becomes board writes only after
/// this validation passes, so these are the tests that keep a bad generation from
/// touching real tasks.
final class LocalAITests: XCTestCase {

    // MARK: Meeting analysis decoding

    func testAnalysisToleratesMissingAndUnknownFields() throws {
        let json = """
        {"summary": "We shipped it", "actionItems": [{"title": "Write the post"}],
         "topics": ["launch"], "modelNote": "ignored"}
        """
        let analysis = try JSONDecoder().decode(MeetingAnalysis.self, from: Data(json.utf8))
        XCTAssertEqual(analysis.summary, "We shipped it")
        XCTAssertEqual(analysis.topics, ["launch"])
        XCTAssertEqual(analysis.actionItems.count, 1)
        XCTAssertNil(analysis.actionItems.first?.confidence)
        XCTAssertTrue(analysis.decisions.isEmpty)
        XCTAssertTrue(analysis.participants.isEmpty)
    }

    func testAnalysisRejectsNonJSON() {
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingAnalysis.self, from: Data("nope".utf8)))
    }

    func testAgentReplyDecodesToolArguments() throws {
        let json = """
        {"reply": "Added it.", "actions": [
            {"tool": "create_task", "title": "Draft the deck", "status": "todo", "tags": ["deck"]}
        ]}
        """
        let reply = try JSONDecoder().decode(LocalAgentReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.reply, "Added it.")
        XCTAssertEqual(reply.actions.first?.tool, "create_task")
        XCTAssertEqual(reply.actions.first?.tags, ["deck"])
    }

    // MARK: Proposed operations

    private func raw(_ tool: String, taskId: UUID? = nil, title: String? = nil,
                     status: String? = nil, due: String? = nil,
                     priority: String? = nil) -> LocalAgentReply.Action {
        LocalAgentReply.Action(tool: tool, taskId: taskId?.uuidString, title: title,
                               notes: nil, status: status, priority: priority, due: due, tags: nil)
    }

    private func lookup(_ tasks: TaskItem...) -> (UUID) -> TaskItem? {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return { byID[$0] }
    }

    func testCreateNeedsATitleAndAcceptsAKnownStatus() {
        let task = lookup()
        XCTAssertNil(LocalAgentPlan.action(raw("create_task"), task: task))
        XCTAssertNil(LocalAgentPlan.action(raw("create_task", title: "   "), task: task))

        let action = LocalAgentPlan.action(
            raw("create_task", title: "Draft the deck", status: "in_progress"), task: task)
        XCTAssertEqual(action?.tool, "create_task")
        XCTAssertEqual(action?.summary, "CREATE · Draft the deck → ACTIVE")
        XCTAssertFalse(action?.destructive ?? true)
    }

    func testOperationOnAnInventedTaskIdIsDropped() {
        let real = TaskItem(title: "real")
        let task = lookup(real)
        XCTAssertNotNil(LocalAgentPlan.action(raw("complete_task", taskId: real.id), task: task))
        XCTAssertNil(LocalAgentPlan.action(raw("complete_task", taskId: UUID()), task: task),
                     "an id the model made up must never resolve")
        XCTAssertNil(LocalAgentPlan.action(raw("complete_task", taskId: UUID()), task: task))
    }

    func testUndatedAndUnparseableDueDates() {
        let task = lookup()
        XCTAssertNotNil(LocalAgentPlan.action(
            raw("create_task", title: "a", due: "2026-09-18"), task: task))
        XCTAssertNotNil(LocalAgentPlan.action(
            raw("create_task", title: "a", due: "friday"), task: task))
        XCTAssertNil(LocalAgentPlan.action(
            raw("create_task", title: "a", due: "sometime next quarter"), task: task))
    }

    func testUpdateShowsWhatChangesAndDropsEmptyEdits() {
        let target = TaskItem(title: "Old title", tags: ["ops"])
        let task = lookup(target)
        let action = LocalAgentPlan.action(
            raw("update_task", taskId: target.id, title: "New title", priority: "urgent"), task: task)
        XCTAssertEqual(action?.summary.hasPrefix("UPDATE · Old title\n"), true)
        XCTAssertEqual(action?.summary.contains("PRIORITY=URGENT"), true)

        XCTAssertNil(LocalAgentPlan.action(raw("update_task", taskId: target.id), task: task),
                     "an update with no recognised fields would be a no-op card")
    }

    func testMoveSummarisesBothColumns() {
        let target = TaskItem(title: "Ship", status: .todo)
        let action = LocalAgentPlan.action(
            raw("move_task", taskId: target.id, status: "doing"), task: lookup(target))
        XCTAssertEqual(action?.summary, "MOVE · Ship · TODO → ACTIVE")
        XCTAssertNil(LocalAgentPlan.action(
            raw("move_task", taskId: target.id, status: "nowhere"), task: lookup(target)))
    }

    func testDestructiveOperationsAreMarked() {
        let target = TaskItem(title: "Old")
        let task = lookup(target)
        XCTAssertEqual(LocalAgentPlan.action(raw("delete_task", taskId: target.id), task: task)?.destructive, true)
        XCTAssertEqual(LocalAgentPlan.action(raw("archive_task", taskId: target.id), task: task)?.destructive, true)
        XCTAssertEqual(LocalAgentPlan.action(raw("complete_task", taskId: target.id), task: task)?.destructive, false)
    }

    func testUnknownToolIsDropped() {
        XCTAssertNil(LocalAgentPlan.action(raw("drop_database", title: "x"), task: lookup()))
        XCTAssertFalse(LocalAgentPlan.isClear("friday"))
        XCTAssertTrue(LocalAgentPlan.isClear("NONE"))
    }
}
