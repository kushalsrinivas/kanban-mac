import XCTest

@MainActor
final class ServiceTests: XCTestCase {

    private func makeService(sync: Bool = false) -> (LocalStore, TaskService) {
        let store = LocalStore(ephemeral: true)
        return (store, TaskService(store: store, syncEnabled: sync))
    }

    // MARK: Validation

    func testCreateRequiresTitle() {
        let (_, service) = makeService()
        XCTAssertThrowsError(try service.create(CreateTaskBody(title: "   "))) { error in
            guard case APIError.badRequest = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testCreateParsesEverything() throws {
        let (_, service) = makeService()
        let task = try service.create(CreateTaskBody(
            title: "Deploy", notes: "n", status: "in progress", priority: "urgent",
            due: "2026-09-18", tags: ["Backend", "#ops", "backend"], subtasks: ["a", "b"]))
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.priority, .urgent)
        XCTAssertEqual(task.tags, ["backend", "ops"], "tags should be lowercased and deduped")
        XCTAssertEqual(task.subtasks.count, 2)
        XCTAssertNotNil(task.dueDate)
    }

    func testCreateRejectsUnknownEnumValues() {
        let (_, service) = makeService()
        XCTAssertThrowsError(try service.create(CreateTaskBody(title: "x", status: "sideways")))
        XCTAssertThrowsError(try service.create(CreateTaskBody(title: "x", priority: "spicy")))
        XCTAssertThrowsError(try service.create(CreateTaskBody(title: "x", due: "not a date")))
    }

    func testPatchOnlyTouchesProvidedFields() throws {
        let (_, service) = makeService()
        let created = try service.create(CreateTaskBody(title: "A", notes: "keep", priority: "high"))
        let patched = try service.patch(created.id, PatchTaskBody(title: "B"))
        XCTAssertEqual(patched.title, "B")
        XCTAssertEqual(patched.notes, "keep")
        XCTAssertEqual(patched.priority, .high)
    }

    func testPatchClearsDueWithSentinel() throws {
        let (_, service) = makeService()
        let created = try service.create(CreateTaskBody(title: "A", due: "tomorrow"))
        XCTAssertNotNil(created.dueDate)
        XCTAssertNil(try service.patch(created.id, PatchTaskBody(due: "none")).dueDate)
        XCTAssertNil(try service.patch(created.id, PatchTaskBody(due: "")).dueDate)
    }

    func testUnknownIdThrows() {
        let (_, service) = makeService()
        XCTAssertThrowsError(try service.patch(UUID(), PatchTaskBody(title: "x"))) { error in
            guard case APIError.notFound = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testDeleteArchivesByDefaultAndHardDeletesOnRequest() throws {
        let (store, service) = makeService()
        let task = try service.create(CreateTaskBody(title: "A"))
        _ = try service.delete(task.id, hard: false)
        XCTAssertTrue(store.task(task.id)!.isArchived)
        _ = try service.delete(task.id, hard: true)
        XCTAssertNil(store.task(task.id))
    }

    // MARK: Filtering

    func testListFilters() throws {
        let (_, service) = makeService()
        _ = try service.create(CreateTaskBody(title: "today one", due: "today", tags: ["home"]))
        _ = try service.create(CreateTaskBody(title: "urgent one", status: "active", priority: "urgent"))
        let done = try service.create(CreateTaskBody(title: "finished"))
        _ = try service.complete(done.id)

        var q = ListQuery(); q.status = .inProgress
        XCTAssertEqual(service.list(q).count, 1)

        q = ListQuery(); q.due = "today"
        XCTAssertEqual(service.list(q).count, 1)

        q = ListQuery(); q.tag = "HOME"
        XCTAssertEqual(service.list(q).count, 1, "tag filter should be case-insensitive")

        q = ListQuery(); q.includeDone = false
        XCTAssertEqual(service.list(q).count, 2)

        q = ListQuery(); q.priority = .urgent
        XCTAssertEqual(service.list(q).count, 1)
    }

    func testListFiltersBySource() throws {
        let (_, service) = makeService()
        let meetingID = UUID()
        _ = try service.create(CreateTaskBody(title: "manual"))
        _ = try service.create(CreateTaskBody(title: "from meeting",
                                              source: TaskSource.meeting.rawValue,
                                              meetingId: meetingID.uuidString))
        var q = ListQuery(); q.source = .meeting
        XCTAssertEqual(service.list(q).map(\.title), ["from meeting"])

        q = ListQuery(); q.meetingID = meetingID
        XCTAssertEqual(service.list(q).count, 1)
    }

    func testSummaryCounts() throws {
        let (_, service) = makeService()
        _ = try service.create(CreateTaskBody(title: "a", status: "active"))
        _ = try service.create(CreateTaskBody(title: "b", due: "today"))
        let done = try service.create(CreateTaskBody(title: "c"))
        _ = try service.complete(done.id)

        let summary = service.summary()
        XCTAssertEqual(summary.open, 2)
        XCTAssertEqual(summary.active, 1)
        XCTAssertEqual(summary.dueToday, 1)
        XCTAssertEqual(summary.doneToday, 1)
        XCTAssertEqual(summary.byStatus["done"], 1)
        XCTAssertFalse(summary.agenda.isEmpty)
    }

    // MARK: Outbox behaviour

    func testNothingIsQueuedWhenSyncIsOff() throws {
        let (store, service) = makeService(sync: false)
        let task = try service.create(CreateTaskBody(title: "local only"))
        _ = try service.complete(task.id)
        XCTAssertEqual(store.pendingOperationCount, 0,
                       "a purely local app should not accumulate an outbox")
    }

    func testMutationsAreQueuedWhenSyncIsOn() throws {
        let (store, service) = makeService(sync: true)
        let task = try service.create(CreateTaskBody(title: "syncs"))
        XCTAssertEqual(store.pendingOperations().map(\.kind), ["task.create"])

        _ = try service.move(task.id, to: .inProgress)
        _ = try service.complete(task.id)
        let kinds = store.pendingOperations().map(\.kind)
        XCTAssertTrue(kinds.contains("task.move"))
        XCTAssertTrue(kinds.contains("task.complete"))

        // Bodies must be replayable against the server as-is: a create carries the
        // shape POST /tasks accepts, including the local id so a replay is idempotent.
        let create = store.pendingOperations().first { $0.kind == "task.create" }!
        XCTAssertEqual(create.method, "POST")
        XCTAssertEqual(create.path, "/tasks")
        let body = try JSONDecoder().decode(CreateTaskBody.self, from: create.body!)
        XCTAssertEqual(body.title, "syncs")
        XCTAssertEqual(body.source, "manual")
        XCTAssertEqual(body.id, task.id.uuidString)
        XCTAssertEqual(body.status, "inbox")

        // A patch carries only fields PATCH /tasks/:id understands.
        let move = store.pendingOperations().first { $0.kind == "task.move" }!
        let moveBody = try JSONDecoder().decode(MoveBody.self, from: move.body!)
        XCTAssertEqual(moveBody.status, "in_progress")
    }

    func testPatchBodyClearsDueWithSentinel() throws {
        let (store, service) = makeService(sync: true)
        let task = try service.create(CreateTaskBody(title: "no date"))
        _ = try service.patch(task.id, PatchTaskBody(title: "renamed"))

        let update = store.pendingOperations().first { $0.kind == "task.update" }!
        let body = try JSONDecoder().decode(PatchTaskBody.self, from: update.body!)
        XCTAssertEqual(body.title, "renamed")
        XCTAssertEqual(body.due, "none", "a task with no due date must clear it server-side")
        XCTAssertEqual(body.archived, false)
    }

    func testDeleteQueuesWithoutCollapsingEarlierEdits() throws {
        let (store, service) = makeService(sync: true)
        let task = try service.create(CreateTaskBody(title: "x"))
        _ = try service.delete(task.id, hard: true)
        let kinds = store.pendingOperations().map(\.kind)
        XCTAssertEqual(kinds.last, "task.delete")
    }

    // MARK: DTO round trips

    func testTaskDTORoundTrip() throws {
        let (_, service) = makeService()
        let meetingID = UUID(), actionID = UUID()
        let original = try service.create(CreateTaskBody(
            title: "Round trip", notes: "n", status: "in_progress", priority: "high",
            due: "today", tags: ["x"], source: "meeting",
            meetingId: meetingID.uuidString, actionItemId: actionID.uuidString))

        let encoded = try JSONEncoder().encode(TaskDTO(original))
        let decoded = try XCTUnwrap(try JSONDecoder().decode(TaskDTO.self, from: encoded).toTask())

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.status, .inProgress)
        XCTAssertEqual(decoded.priority, .high)
        XCTAssertEqual(decoded.source, .meeting)
        XCTAssertEqual(decoded.meetingID, meetingID)
        XCTAssertEqual(decoded.actionItemID, actionID)
        XCTAssertEqual(decoded.dueDate?.timeIntervalSince1970 ?? 0,
                       original.dueDate?.timeIntervalSince1970 ?? 0, accuracy: 1)
    }

    func testMeetingDTOMergePreservesUserDecisions() throws {
        let meetingID = UUID()
        let itemID = UUID()
        let taskID = UUID()

        var existing = Meeting(id: meetingID, title: "Sync", status: .analyzing)
        existing.actionItems = [ActionItem(id: itemID, meetingID: meetingID, title: "Finish onboarding",
                                          state: .added, taskID: taskID)]

        let json = """
        {"id":"\(meetingID.uuidString)","title":"Product Sync","startedAt":"2026-09-18T10:30:00Z",
         "duration":2532,"status":"completed","summary":"We discussed onboarding.",
         "keyPoints":["a"],"decisions":["d"],
         "actionItems":[{"id":"\(itemID.uuidString)","title":"Finish onboarding","confidence":0.91},
                        {"id":"new-1","title":"Review API"}],
         "transcript":{"segments":[{"start":3,"end":8,"speaker":"Alex","text":"hello"}]}}
        """
        let dto = try JSONDecoder().decode(MeetingDTO.self, from: Data(json.utf8))
        let merged = try XCTUnwrap(dto.merged(into: existing))

        XCTAssertEqual(merged.title, "Product Sync")
        XCTAssertEqual(merged.status, .completed)
        XCTAssertEqual(merged.summary, "We discussed onboarding.")
        XCTAssertEqual(merged.actionItems.count, 2)
        XCTAssertEqual(merged.actionItems[0].state, .added, "an accepted suggestion must stay accepted")
        XCTAssertEqual(merged.actionItems[0].taskID, taskID)
        XCTAssertEqual(merged.actionItems[1].state, .suggested)
        XCTAssertEqual(merged.transcript.first?.text, "hello")
    }

    func testMeetingDTOMapsNonUUIDServerIdsStably() throws {
        let meetingID = UUID()
        let dto = ActionItemDTO(id: "action_1", title: "t", assignee: nil, dueDate: nil, confidence: 0.5)
        let a = dto.toActionItem(meetingID: meetingID, position: 0)
        let b = dto.toActionItem(meetingID: meetingID, position: 0)
        XCTAssertEqual(a?.id, b?.id, "a server id that is not a UUID must map stably")
    }

    func testJobStatusMapping() {
        XCTAssertEqual(JobDTO(id: "1", status: "running", stage: "transcribing").meetingStatus, .transcribing)
        XCTAssertEqual(JobDTO(id: "1", status: "queued").meetingStatus, .queued)
        XCTAssertEqual(JobDTO(id: "1", status: "completed").meetingStatus, .completed)
        XCTAssertEqual(JobDTO(id: "1", status: "failed", error: "boom").meetingStatus, .failed)
        XCTAssertNil(JobDTO(id: "1", status: "something-new").meetingStatus)
    }

    func testAPIErrorTransience() {
        XCTAssertTrue(APIError.offline("x").isTransient)
        XCTAssertTrue(APIError.server(503, "").isTransient)
        XCTAssertTrue(APIError.server(429, "").isTransient)
        XCTAssertFalse(APIError.badRequest("").isTransient)
        XCTAssertFalse(APIError.notFound("").isTransient)
        XCTAssertFalse(APIError.unauthorized.isTransient)
    }
}
