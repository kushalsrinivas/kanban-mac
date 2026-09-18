import XCTest

@MainActor
final class StoreTests: XCTestCase {

    private func makeStore() -> LocalStore { LocalStore(ephemeral: true) }

    // MARK: Task CRUD

    func testCreateAndRead() {
        let store = makeStore()
        let task = store.createTask(TaskItem(title: "Deploy backend", priority: .high))
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.task(task.id)?.title, "Deploy backend")
        XCTAssertEqual(store.task(task.id)?.priority, .high)
        XCTAssertEqual(store.task(task.id)?.status, .inbox)
        XCTAssertEqual(store.task(task.id)?.source, .manual)
    }

    func testNoOpUpdateDoesNotChangeTimestamp() {
        let store = makeStore()
        let task = store.createTask(TaskItem(title: "A"))
        XCTAssertEqual(store.updateTask(task.id) { _ in }?.updatedAt, task.updatedAt)
    }

    func testCompleteAndReopen() {
        let store = makeStore()
        let task = store.createTask(TaskItem(title: "Ship"))
        let done = store.completeTask(task.id)
        XCTAssertEqual(done?.status, .done)
        XCTAssertNotNil(done?.completedAt)

        let reopened = store.reopenTask(task.id, to: .inProgress)
        XCTAssertEqual(reopened?.status, .inProgress)
        XCTAssertNil(reopened?.completedAt)
    }

    func testArchiveHidesFromColumnButKeepsRow() {
        let store = makeStore()
        let task = store.createTask(TaskItem(title: "Old"))
        store.archiveTask(task.id)
        XCTAssertTrue(store.task(task.id)!.isArchived)
        XCTAssertTrue(store.tasks(in: .inbox).isEmpty)
        XCTAssertEqual(store.tasks(in: .inbox, includeArchived: true).count, 1)
    }

    func testDeleteRemovesRow() {
        let store = makeStore()
        let task = store.createTask(TaskItem(title: "Gone"))
        XCTAssertTrue(store.deleteTask(task.id))
        XCTAssertNil(store.task(task.id))
        XCTAssertFalse(store.deleteTask(task.id))
    }

    // MARK: Ordering

    func testNewTasksLandOnTop() {
        let store = makeStore()
        store.createTask(TaskItem(title: "first"))
        store.createTask(TaskItem(title: "second"))
        XCTAssertEqual(store.tasks(in: .inbox).map(\.title), ["second", "first"])
    }

    func testMoveToIndexPlacesBetweenNeighbours() {
        let store = makeStore()
        let a = store.createTask(TaskItem(title: "a"))
        store.createTask(TaskItem(title: "b"))
        store.createTask(TaskItem(title: "c"))
        XCTAssertEqual(store.tasks(in: .inbox).map(\.title), ["c", "b", "a"])
        store.moveTask(a.id, to: .inbox, index: 1)
        XCTAssertEqual(store.tasks(in: .inbox).map(\.title), ["c", "a", "b"])
    }

    func testRepeatedMidpointInsertsKeepOrder() {
        let store = makeStore()
        let ids = (0..<12).map { store.createTask(TaskItem(title: "t\($0)")).id }
        for _ in 0..<40 {
            guard let last = store.tasks(in: .inbox).last else { break }
            store.moveTask(last.id, to: .inbox, index: 1)
        }
        let order = store.tasks(in: .inbox)
        XCTAssertEqual(order.count, ids.count)
        XCTAssertEqual(Set(order.map(\.id)).count, ids.count)
        for (a, b) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(a.position, b.position, "positions collapsed")
        }
    }

    // MARK: Subtasks

    func testSubtaskLifecycle() {
        let store = makeStore()
        let task = store.createTask(TaskItem(title: "Parent"))
        let sub = store.addSubtask(to: task.id, title: "child")
        XCTAssertNotNil(sub)
        store.setSubtask(sub!.id, on: task.id, done: true)
        XCTAssertEqual(store.task(task.id)?.doneSubtaskCount, 1)
        store.removeSubtask(sub!.id, from: task.id)
        XCTAssertTrue(store.task(task.id)!.subtasks.isEmpty)
    }

    // MARK: Search and counts

    func testSearchMatchesTitleNotesAndTags() {
        let store = makeStore()
        store.createTask(TaskItem(title: "Fix auth bug", notes: "check the refresh token"))
        store.createTask(TaskItem(title: "Write docs", tags: ["writing"]))
        XCTAssertEqual(store.search("auth").count, 1)
        XCTAssertEqual(store.search("refresh").count, 1)
        XCTAssertEqual(store.search("AUTH").count, 1)
        XCTAssertEqual(store.search("").count, 2)
    }

    func testCounts() {
        let store = makeStore()
        let now = Date()
        store.createTask(TaskItem(title: "today", dueDate: now))
        store.createTask(TaskItem(title: "late", status: .todo, dueDate: now.addingTimeInterval(-86_400 * 2)))
        store.createTask(TaskItem(title: "doing", status: .inProgress))
        let done = store.createTask(TaskItem(title: "done"))
        store.completeTask(done.id)

        let counts = store.counts(now: now)
        XCTAssertEqual(counts.open, 3)
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.dueToday, 1)
        XCTAssertEqual(counts.overdue, 1)
    }

    // MARK: Meetings

    func testMeetingLifecycle() {
        let store = makeStore()
        let meeting = store.upsertMeeting(Meeting(title: "Product sync", status: .recording))
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(store.activeRecording?.id, meeting.id)

        store.updateMeeting(meeting.id) {
            $0.status = .completed
            $0.duration = 2_532
            $0.summary = "We discussed onboarding."
        }
        XCTAssertNil(store.activeRecording)
        XCTAssertEqual(store.meeting(meeting.id)?.summary, "We discussed onboarding.")
        XCTAssertEqual(store.meeting(meeting.id)?.durationLabel, "42 MIN")
    }

    func testActionItemStateTransitions() {
        let store = makeStore()
        let meetingID = UUID()
        let item = ActionItem(meetingID: meetingID, title: "Finish onboarding", confidence: 0.9)
        store.upsertMeeting(Meeting(id: meetingID, title: "Sync", status: .completed, actionItems: [item]))

        XCTAssertEqual(store.meeting(meetingID)?.suggestedCount, 1)

        let taskID = UUID()
        store.setActionItemState(item.id, in: meetingID, to: .added, taskID: taskID)
        XCTAssertEqual(store.meeting(meetingID)?.suggestedCount, 0)
        XCTAssertEqual(store.meeting(meetingID)?.addedCount, 1)
        XCTAssertEqual(store.meeting(meetingID)?.actionItems.first?.taskID, taskID)
    }

    func testDeletingTaskReleasesItsSuggestion() {
        let store = makeStore()
        let meetingID = UUID()
        let item = ActionItem(meetingID: meetingID, title: "Review API")
        store.upsertMeeting(Meeting(id: meetingID, title: "Sync", status: .completed, actionItems: [item]))

        let task = store.createTask(TaskItem(title: "Review API", source: .meeting,
                                             meetingID: meetingID, actionItemID: item.id))
        store.setActionItemState(item.id, in: meetingID, to: .added, taskID: task.id)
        XCTAssertEqual(store.meeting(meetingID)?.suggestedCount, 0)

        store.deleteTask(task.id)
        XCTAssertEqual(store.meeting(meetingID)?.suggestedCount, 1,
                       "deleting the task should make the suggestion available again")
    }

    func testDeletingMeetingClearsTaskReferences() {
        let store = makeStore()
        let meetingID = UUID()
        store.upsertMeeting(Meeting(id: meetingID, title: "Sync", status: .completed))
        let task = store.createTask(TaskItem(title: "From meeting", source: .meeting, meetingID: meetingID))

        store.deleteMeeting(meetingID)
        XCTAssertNil(store.task(task.id)?.meetingID)
        XCTAssertNotNil(store.task(task.id), "the task itself must survive")
    }

    func testTranscriptStoredOutOfMemory() {
        let store = makeStore()
        let meetingID = UUID()
        store.upsertMeeting(Meeting(id: meetingID, title: "Long", status: .completed))
        let segments = (0..<200).map {
            TranscriptSegment(start: Double($0) * 5, end: Double($0) * 5 + 4, speaker: "Alex", text: "line \($0)")
        }
        store.saveTranscript(segments, for: meetingID)

        XCTAssertTrue(store.meeting(meetingID)!.transcript.isEmpty,
                      "transcripts must not be held in the in-memory meeting list")
        let loaded = store.transcript(for: meetingID)
        XCTAssertEqual(loaded.count, 200)
        XCTAssertEqual(loaded.first?.text, "line 0")
        XCTAssertEqual(loaded.first?.timecode, "00:00")
    }

    func testMeetingGrouping() {
        let now = Date()
        let cal = Calendar.current
        let meetings = [
            Meeting(title: "today", startedAt: now),
            Meeting(title: "this week", startedAt: cal.date(byAdding: .day, value: -1, to: now)!),
            Meeting(title: "old", startedAt: cal.date(byAdding: .day, value: -60, to: now)!)
        ]
        let groups = meetings.grouped(now: now, calendar: cal).map(\.0)
        XCTAssertEqual(groups.first, "TODAY")
        XCTAssertTrue(groups.contains("EARLIER"))
    }

    // MARK: Outbox

    func testOutboxQueuesAndCollapses() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(kind: "task.update", method: "PATCH", path: "/tasks/\(id)",
                      body: Data("{\"title\":\"a\"}".utf8), entityID: id)
        store.enqueue(kind: "task.update", method: "PATCH", path: "/tasks/\(id)",
                      body: Data("{\"title\":\"b\"}".utf8), entityID: id)
        XCTAssertEqual(store.pendingOperationCount, 1, "repeat edits should collapse")

        let pending = store.pendingOperations()
        XCTAssertEqual(pending.first?.method, "PATCH")
        XCTAssertEqual(String(data: pending.first!.body!, encoding: .utf8), "{\"title\":\"b\"}")

        store.removeOutboxEntry(pending.first!.id)
        XCTAssertEqual(store.pendingOperationCount, 0)
    }

    func testOutboxPreservesOrderAcrossEntities() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.enqueue(kind: "task.create", method: "POST", path: "/tasks", entityID: a)
        store.enqueue(kind: "task.create", method: "POST", path: "/tasks", entityID: b)
        store.enqueue(kind: "task.delete", method: "DELETE", path: "/tasks/\(a)", entityID: a, collapse: false)
        XCTAssertEqual(store.pendingOperations().map(\.kind),
                       ["task.create", "task.create", "task.delete"])
    }

    func testOutboxFailureIsRecorded() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(kind: "task.create", method: "POST", path: "/tasks", entityID: id)
        let entry = store.pendingOperations()[0]
        store.recordOutboxFailure(entry.id, error: "boom")
        let after = store.pendingOperations()[0]
        XCTAssertEqual(after.attempts, 1)
        XCTAssertEqual(after.lastError, "boom")
    }

    func testReplaceTasksKeepsLocallyQueuedRows() {
        let store = makeStore()
        let queued = store.createTask(TaskItem(title: "written offline"))
        store.enqueue(kind: "task.create", method: "POST", path: "/tasks", entityID: queued.id)

        let remote = TaskItem(title: "from server", status: .todo)
        store.replaceTasks(with: [remote])

        XCTAssertTrue(store.tasks.contains { $0.id == queued.id },
                      "an unsynced local task must survive a server refresh")
        XCTAssertTrue(store.tasks.contains { $0.id == remote.id })
    }

    // MARK: Persistence

    func testDataSurvivesReopeningTheDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-test-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let taskID: UUID
        let meetingID = UUID()
        do {
            let store = LocalStore(url: url)
            var task = TaskItem(title: "Persisted", notes: "notes", status: .inProgress,
                                priority: .urgent, dueDate: Date(timeIntervalSince1970: 1_700_000_000),
                                tags: ["a", "b"], source: .meeting, meetingID: meetingID)
            task.subtasks = [Subtask(title: "one", isDone: true, position: 0)]
            taskID = store.createTask(task).id

            store.upsertMeeting(Meeting(id: meetingID, title: "Sync", duration: 600,
                                        status: .completed, summary: "s",
                                        keyPoints: ["k1", "k2"], decisions: ["d1"],
                                        actionItems: [ActionItem(meetingID: meetingID, title: "ai")]))
            store.saveTranscript([TranscriptSegment(start: 0, end: 3, speaker: "Alex", text: "hello")],
                                 for: meetingID)
        }

        let reopened = LocalStore(url: url)
        let task = try XCTUnwrap(reopened.task(taskID))
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.source, .meeting)
        XCTAssertEqual(task.meetingID, meetingID)
        XCTAssertEqual(task.subtasks.count, 1)

        let meeting = try XCTUnwrap(reopened.meeting(meetingID))
        XCTAssertEqual(meeting.keyPoints, ["k1", "k2"])
        XCTAssertEqual(meeting.decisions, ["d1"])
        XCTAssertEqual(meeting.actionItems.count, 1)
        XCTAssertEqual(reopened.transcript(for: meetingID).first?.text, "hello")
    }

    func testMigrationFromV1PreservesTasks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-v1-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build a v1 database by hand, including the old 'active' column value.
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("""
            CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
              col TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 1, due REAL, tags TEXT NOT NULL DEFAULT '',
              position REAL NOT NULL DEFAULT 0, created REAL NOT NULL, updated REAL NOT NULL,
              completed REAL, archived REAL);
            CREATE TABLE subtasks (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, title TEXT NOT NULL,
              done INTEGER NOT NULL DEFAULT 0, position REAL NOT NULL DEFAULT 0);
            CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, actor TEXT NOT NULL,
              action TEXT NOT NULL, task_id TEXT, detail TEXT NOT NULL DEFAULT '');
            """)
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try db.run("INSERT INTO tasks (id,title,notes,col,priority,due,tags,position,created,updated) VALUES (?,?,?,?,?,?,?,?,?,?);",
                   [.text(id), .text("legacy"), .text(""), .text("active"), .int(2), .null,
                    .text("old"), .double(0), .double(now), .double(now)])
        db.userVersion = 1
        db.close()

        let store = LocalStore(url: url)
        XCTAssertNil(store.lastError)
        let task = try XCTUnwrap(store.task(UUID(uuidString: id)!))
        XCTAssertEqual(task.title, "legacy")
        XCTAssertEqual(task.status, .inProgress, "'active' should migrate to in_progress")
        XCTAssertEqual(task.tags, ["old"])
        XCTAssertEqual(store.meetings.count, 0)
    }

    func testCorruptDatabaseDoesNotCrash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-corrupt-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("this is not a database".utf8).write(to: url)

        let store = LocalStore(url: url)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertNotNil(store.lastError)
        _ = store.createTask(TaskItem(title: "after corruption"))
        XCTAssertEqual(store.tasks.count, 1, "the app must stay usable")
    }
}
