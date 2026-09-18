import Foundation
import Observation

/// The on-device cache: tasks, meetings and the outbox of mutations waiting for the VPS.
///
/// Performance notes, since low resource use is a hard requirement:
///  - Tasks and meeting headers live in memory. A personal board is a few hundred
///    rows, so every filter, search and count is an in-memory pass with no query cost.
///  - Transcripts are the one thing kept on disk and loaded on demand — a long
///    meeting is thousands of segments and has no business sitting in RAM.
///  - Writes are write-through: mutate the array, then one small statement. No sync
///    loop, no timers, no file watchers.
@Observable
@MainActor
public final class LocalStore {

    public private(set) var tasks: [TaskItem] = []
    /// Meetings without their transcripts. Use `transcript(for:)` to page one in.
    public private(set) var meetings: [Meeting] = []
    public private(set) var lastError: String?

    @ObservationIgnored private var db: SQLiteDatabase?
    @ObservationIgnored private var snapshotWorkItem: DispatchWorkItem?
    @ObservationIgnored private let isEphemeral: Bool

    /// Fired after any mutation, coalesced. The app uses it to refresh the widget and
    /// reschedule notifications without the store knowing either exists.
    @ObservationIgnored public var onChange: ((BoardSnapshot) -> Void)?
    /// Fired when something lands in the outbox, so the sync engine can try to flush.
    @ObservationIgnored public var onOutboxChange: (() -> Void)?

    // MARK: Lifecycle

    public init(url: URL? = nil, ephemeral: Bool = false) {
        self.isEphemeral = ephemeral
        let path: String
        if ephemeral {
            path = ":memory:"
        } else {
            KanbanPaths.ensureSupportDirectory()
            path = (url ?? KanbanPaths.databaseURL).path
        }
        do {
            let database = try SQLiteDatabase(path: path)
            try Schema.migrate(database)
            db = database
            tasks = try Self.loadTasks(from: database)
            meetings = try Self.loadMeetings(from: database)
        } catch {
            lastError = "\(error)"
            db = nil
        }
    }

    // MARK: - Task reads

    public var openTasks: [TaskItem] { tasks.filter(\.isOpen) }

    public func tasks(in status: TaskStatus, includeArchived: Bool = false) -> [TaskItem] {
        tasks.filter { $0.status == status && (includeArchived || !$0.isArchived) }.boardSorted()
    }

    public func task(_ id: UUID) -> TaskItem? { tasks.first { $0.id == id } }

    public func tasks(fromMeeting id: UUID) -> [TaskItem] {
        tasks.filter { $0.meetingID == id }
    }

    public func search(_ query: String, includeArchived: Bool = false) -> [TaskItem] {
        tasks.filter { (includeArchived || !$0.isArchived) && $0.matches(query: query) }
    }

    public func counts(now: Date = Date()) -> (open: Int, active: Int, dueToday: Int, overdue: Int) {
        var open = 0, active = 0, dueToday = 0, overdue = 0
        let cal = Calendar.current
        for t in tasks where t.isOpen {
            open += 1
            if t.status == .inProgress { active += 1 }
            if t.isDueToday(now: now, calendar: cal) { dueToday += 1 }
            if t.isOverdue(now: now, calendar: cal) { overdue += 1 }
        }
        return (open, active, dueToday, overdue)
    }

    public var allTags: [String] {
        var seen = Set<String>()
        for t in tasks where !t.isArchived { seen.formUnion(t.tags) }
        return seen.sorted()
    }

    public func snapshot(now: Date = Date(), recording: BoardSnapshot.Recording? = nil) -> BoardSnapshot {
        BoardSnapshot.make(from: tasks, recording: recording, now: now)
    }

    // MARK: - Task mutations

    @discardableResult
    public func createTask(_ task: TaskItem) -> TaskItem {
        var new = task
        if new.position == 0 { new.position = nextPosition(in: new.status) }
        new.updatedAt = Date()
        if new.status == .done && new.completedAt == nil { new.completedAt = Date() }
        tasks.append(new)
        write { try Self.insertTask(new, into: $0) }
        didMutate()
        return new
    }

    @discardableResult
    public func updateTask(_ id: UUID, _ edit: (inout TaskItem) -> Void) -> TaskItem? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let before = tasks[index]
        var task = before
        edit(&task)
        guard task != before else { return before }
        task.updatedAt = Date()
        if task.status == .done, task.completedAt == nil { task.completedAt = task.updatedAt }
        if task.status != .done { task.completedAt = nil }
        tasks[index] = task
        write { try Self.updateTask(task, in: $0) }
        didMutate()
        return task
    }

    @discardableResult
    public func moveTask(_ id: UUID, to status: TaskStatus, index: Int? = nil) -> TaskItem? {
        guard task(id) != nil else { return nil }
        let position = positionFor(status: status, index: index, excluding: id)
        return updateTask(id) {
            $0.status = status
            $0.position = position
            if status != .done { $0.archivedAt = nil }
        }
    }

    @discardableResult
    public func completeTask(_ id: UUID) -> TaskItem? {
        guard let t = task(id), t.status != .done else { return task(id) }
        return moveTask(id, to: .done, index: 0)
    }

    @discardableResult
    public func reopenTask(_ id: UUID, to status: TaskStatus = .todo) -> TaskItem? {
        moveTask(id, to: status, index: 0)
    }

    @discardableResult
    public func archiveTask(_ id: UUID) -> TaskItem? {
        updateTask(id) { $0.archivedAt = Date() }
    }

    @discardableResult
    public func unarchiveTask(_ id: UUID) -> TaskItem? {
        updateTask(id) { $0.archivedAt = nil }
    }

    @discardableResult
    public func deleteTask(_ id: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let removed = tasks.remove(at: index)
        write { db in
            try db.run("DELETE FROM subtasks WHERE task_id = ?;", [.text(removed.id.uuidString)])
            try db.run("DELETE FROM tasks WHERE id = ?;", [.text(removed.id.uuidString)])
        }
        // A suggestion whose task was deleted becomes available to add again.
        if let actionItemID = removed.actionItemID, let meetingID = removed.meetingID {
            setActionItemState(actionItemID, in: meetingID, to: .suggested, taskID: nil)
        }
        didMutate()
        return true
    }

    @discardableResult
    public func purgeArchivedTasks() -> Int {
        let ids = tasks.filter(\.isArchived).map(\.id)
        for id in ids { deleteTask(id) }
        return ids.count
    }

    /// Replaces the cache with what the server returned. Local-only rows that still
    /// have outbox entries are kept so an offline edit is never clobbered by a refresh.
    public func replaceTasks(with remote: [TaskItem]) {
        let pending = Set(pendingEntityIDs())
        let kept = tasks.filter { pending.contains($0.id) }
        var merged = remote.filter { !pending.contains($0.id) }
        merged.append(contentsOf: kept)
        tasks = merged
        write { db in
            try db.transaction {
                try db.run("DELETE FROM tasks WHERE id NOT IN (SELECT entity_id FROM outbox WHERE entity_id IS NOT NULL);")
                try db.run("DELETE FROM subtasks WHERE task_id NOT IN (SELECT id FROM tasks);")
                for task in merged { try Self.insertTask(task, into: db) }
            }
        }
        didMutate()
    }

    // MARK: - Subtasks

    @discardableResult
    public func addSubtask(to id: UUID, title: String) -> Subtask? {
        var created: Subtask?
        updateTask(id) { task in
            let sub = Subtask(title: title, position: (task.subtasks.map(\.position).max() ?? 0) + 1)
            task.subtasks.append(sub)
            created = sub
        }
        return created
    }

    @discardableResult
    public func setSubtask(_ subtaskID: UUID, on id: UUID, done: Bool? = nil, title: String? = nil) -> TaskItem? {
        updateTask(id) { task in
            guard let i = task.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
            if let done { task.subtasks[i].isDone = done }
            if let title { task.subtasks[i].title = title }
        }
    }

    @discardableResult
    public func removeSubtask(_ subtaskID: UUID, from id: UUID) -> TaskItem? {
        updateTask(id) { $0.subtasks.removeAll { $0.id == subtaskID } }
    }

    // MARK: - Ordering

    /// Position that places a task at `index` within `status` (nil == top).
    public func positionFor(status: TaskStatus, index: Int?, excluding: UUID? = nil) -> Double {
        let ordered = tasks
            .filter { $0.status == status && !$0.isArchived && $0.id != excluding }
            .boardSorted()
        guard !ordered.isEmpty else { return 0 }
        guard let index, index > 0 else { return ordered[0].position - 1 }
        if index >= ordered.count { return ordered[ordered.count - 1].position + 1 }
        return (ordered[index - 1].position + ordered[index].position) / 2
    }

    private func nextPosition(in status: TaskStatus) -> Double {
        let positions = tasks.filter { $0.status == status && !$0.isArchived }.map(\.position)
        return (positions.min() ?? 1) - 1
    }

    // MARK: - Meetings

    public func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    public var activeRecording: Meeting? { meetings.first { $0.status == .recording } }

    public var processingMeetings: [Meeting] { meetings.filter { $0.status.isProcessing } }

    /// Meetings recorded but never uploaded — the offline queue.
    public var meetingsAwaitingUpload: [Meeting] { meetings.filter(\.awaitsUpload) }

    @discardableResult
    public func upsertMeeting(_ meeting: Meeting) -> Meeting {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        write { try Self.writeMeeting(meeting, into: $0) }
        didMutate()
        return meeting
    }

    @discardableResult
    public func updateMeeting(_ id: UUID, _ edit: (inout Meeting) -> Void) -> Meeting? {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return nil }
        var meeting = meetings[index]
        edit(&meeting)
        guard meeting != meetings[index] else { return meeting }
        meetings[index] = meeting
        write { try Self.writeMeeting(meeting, into: $0) }
        didMutate()
        return meeting
    }

    @discardableResult
    public func deleteMeeting(_ id: UUID) -> Bool {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return false }
        meetings.remove(at: index)
        write { db in
            try db.transaction {
                try db.run("DELETE FROM transcript_segments WHERE meeting_id = ?;", [.text(id.uuidString)])
                try db.run("DELETE FROM action_items WHERE meeting_id = ?;", [.text(id.uuidString)])
                try db.run("DELETE FROM meetings WHERE id = ?;", [.text(id.uuidString)])
            }
        }
        // Tasks created from it keep their text but lose the dangling reference.
        for task in tasks.filter({ $0.meetingID == id }) {
            updateTask(task.id) { $0.meetingID = nil; $0.actionItemID = nil }
        }
        didMutate()
        return true
    }

    /// Transcripts are stored but not held in memory; this pages one in on demand.
    public func transcript(for meetingID: UUID) -> [TranscriptSegment] {
        guard let db else { return [] }
        var out: [TranscriptSegment] = []
        try? db.query("""
            SELECT id, start, finish, speaker, text FROM transcript_segments
            WHERE meeting_id = ? ORDER BY start;
            """, [.text(meetingID.uuidString)]) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            out.append(TranscriptSegment(id: id, start: row.double(1), end: row.double(2),
                                         speaker: row.stringOrNil(3), text: row.string(4)))
        }
        return out
    }

    public func saveTranscript(_ segments: [TranscriptSegment], for meetingID: UUID) {
        write { db in
            try db.transaction {
                try db.run("DELETE FROM transcript_segments WHERE meeting_id = ?;", [.text(meetingID.uuidString)])
                for s in segments {
                    try db.run("""
                        INSERT INTO transcript_segments (id, meeting_id, start, finish, speaker, text)
                        VALUES (?,?,?,?,?,?);
                        """,
                        [.text(s.id.uuidString), .text(meetingID.uuidString), .double(s.start),
                         .double(s.end), s.speaker.map { .text($0) } ?? .null, .text(s.text)])
                }
            }
        }
    }

    @discardableResult
    public func setActionItemState(_ itemID: UUID, in meetingID: UUID,
                                   to state: ActionItem.State, taskID: UUID?) -> Meeting? {
        updateMeeting(meetingID) { meeting in
            guard let i = meeting.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            meeting.actionItems[i].state = state
            meeting.actionItems[i].taskID = taskID
        }
    }

    // MARK: - Outbox

    public struct OutboxEntry: Identifiable, Sendable {
        public var id: Int64
        public var createdAt: Date
        public var kind: String
        public var method: String
        public var path: String
        public var body: Data?
        public var entityID: UUID?
        public var attempts: Int
        public var lastError: String?
    }

    /// Queues a mutation for the VPS. Superseded entries for the same entity and kind
    /// are dropped, so rapid edits collapse to one request.
    public func enqueue(kind: String, method: String, path: String,
                        body: Data? = nil, entityID: UUID? = nil, collapse: Bool = true) {
        write { db in
            if collapse, let entityID {
                try db.run("DELETE FROM outbox WHERE entity_id = ? AND kind = ?;",
                           [.text(entityID.uuidString), .text(kind)])
            }
            try db.run("""
                INSERT INTO outbox (created, kind, method, path, body, entity_id, attempts)
                VALUES (?,?,?,?,?,?,0);
                """,
                [.double(Date().timeIntervalSince1970), .text(kind), .text(method), .text(path),
                 body.map { .blob($0) } ?? .null, entityID.map { .text($0.uuidString) } ?? .null])
        }
        onOutboxChange?()
    }

    public func pendingOperations(limit: Int = 100) -> [OutboxEntry] {
        guard let db else { return [] }
        var out: [OutboxEntry] = []
        try? db.query("""
            SELECT id, created, kind, method, path, body, entity_id, attempts, last_error
            FROM outbox ORDER BY id LIMIT ?;
            """, [.int(Int64(limit))]) { row in
            out.append(OutboxEntry(
                id: row.int64(0),
                createdAt: Date(timeIntervalSince1970: row.double(1)),
                kind: row.string(2),
                method: row.string(3),
                path: row.string(4),
                body: row.blobOrNil(5),
                entityID: row.stringOrNil(6).flatMap(UUID.init(uuidString:)),
                attempts: Int(row.int(7)),
                lastError: row.stringOrNil(8)
            ))
        }
        return out
    }

    public var pendingOperationCount: Int {
        guard let db else { return 0 }
        var count: Int32 = 0
        try? db.query("SELECT COUNT(*) FROM outbox;") { count = $0.int(0) }
        return Int(count)
    }

    private func pendingEntityIDs() -> [UUID] {
        guard let db else { return [] }
        var out: [UUID] = []
        try? db.query("SELECT DISTINCT entity_id FROM outbox WHERE entity_id IS NOT NULL;") { row in
            if let id = UUID(uuidString: row.string(0)) { out.append(id) }
        }
        return out
    }

    public func removeOutboxEntry(_ id: Int64) {
        write { try $0.run("DELETE FROM outbox WHERE id = ?;", [.int(id)]) }
        onOutboxChange?()
    }

    public func recordOutboxFailure(_ id: Int64, error: String) {
        write { try $0.run("UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?;",
                           [.text(error), .int(id)]) }
    }

    public func clearOutbox() {
        write { try $0.run("DELETE FROM outbox;") }
        onOutboxChange?()
    }

    // MARK: - Plumbing

    private func write(_ body: (SQLiteDatabase) throws -> Void) {
        guard let db else { return }
        do { try body(db) } catch { lastError = "\(error)" }
    }

    private func didMutate() {
        guard !isEphemeral else { onChange?(snapshot()); return }
        // Coalesce bursts (drag-reorder, agent batches) into one snapshot write.
        snapshotWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        snapshotWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Writes the widget snapshot immediately. Called on quit and when going background.
    public func flush(recording: BoardSnapshot.Recording? = nil) {
        snapshotWorkItem?.cancel()
        snapshotWorkItem = nil
        let snap = snapshot(recording: recording ?? currentRecordingSnapshot())
        if !isEphemeral { snap.write() }
        onChange?(snap)
    }

    private func currentRecordingSnapshot() -> BoardSnapshot.Recording? {
        guard let meeting = activeRecording else { return nil }
        return BoardSnapshot.Recording(title: meeting.title, startedAt: meeting.startedAt)
    }

    // MARK: - SQL: tasks

    private static let taskColumns = """
        id, remote_id, title, notes, status, priority, due, tags, position,
        created, updated, completed, archived, source, meeting_id, action_item_id
        """

    private static func loadTasks(from db: SQLiteDatabase) throws -> [TaskItem] {
        var subtasks: [UUID: [Subtask]] = [:]
        try db.query("SELECT id, task_id, title, done, position FROM subtasks ORDER BY position;") { row in
            guard let sid = UUID(uuidString: row.string(0)), let tid = UUID(uuidString: row.string(1)) else { return }
            subtasks[tid, default: []].append(
                Subtask(id: sid, title: row.string(2), isDone: row.int(3) == 1, position: row.double(4)))
        }
        var out: [TaskItem] = []
        out.reserveCapacity(256)
        try db.query("SELECT \(taskColumns) FROM tasks;") { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            let tagsRaw = row.string(7)
            out.append(TaskItem(
                id: id,
                title: row.string(2),
                notes: row.string(3),
                status: TaskStatus(rawValue: row.string(4)) ?? .inbox,
                priority: Priority(rawValue: Int(row.int(5))) ?? .medium,
                dueDate: row.doubleOrNil(6).map(Date.init(timeIntervalSince1970:)),
                tags: tagsRaw.isEmpty ? [] : tagsRaw.split(separator: ",").map(String.init),
                subtasks: subtasks[id] ?? [],
                position: row.double(8),
                createdAt: Date(timeIntervalSince1970: row.double(9)),
                updatedAt: Date(timeIntervalSince1970: row.double(10)),
                completedAt: row.doubleOrNil(11).map(Date.init(timeIntervalSince1970:)),
                archivedAt: row.doubleOrNil(12).map(Date.init(timeIntervalSince1970:)),
                source: TaskSource(rawValue: row.string(13)) ?? .manual,
                meetingID: row.stringOrNil(14).flatMap(UUID.init(uuidString:)),
                actionItemID: row.stringOrNil(15).flatMap(UUID.init(uuidString:))
            ))
        }
        return out
    }

    private static func taskBinds(_ t: TaskItem) -> [SQLiteDatabase.Value] {
        [.text(t.id.uuidString), .null, .text(t.title), .text(t.notes), .text(t.status.rawValue),
         .int(Int64(t.priority.rawValue)), .date(t.dueDate), .text(t.tags.joined(separator: ",")),
         .double(t.position), .double(t.createdAt.timeIntervalSince1970),
         .double(t.updatedAt.timeIntervalSince1970), .date(t.completedAt), .date(t.archivedAt),
         .text(t.source.rawValue),
         t.meetingID.map { .text($0.uuidString) } ?? .null,
         t.actionItemID.map { .text($0.uuidString) } ?? .null]
    }

    private static func insertTask(_ t: TaskItem, into db: SQLiteDatabase) throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO tasks (\(taskColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);",
                       taskBinds(t))
            try writeSubtasks(t, db)
        }
    }

    private static func updateTask(_ t: TaskItem, in db: SQLiteDatabase) throws {
        try db.transaction {
            try db.run("""
                UPDATE tasks SET title=?, notes=?, status=?, priority=?, due=?, tags=?, position=?,
                                 created=?, updated=?, completed=?, archived=?, source=?,
                                 meeting_id=?, action_item_id=? WHERE id=?;
                """,
                Array(taskBinds(t).dropFirst(2)) + [.text(t.id.uuidString)])
            try writeSubtasks(t, db)
        }
    }

    private static func writeSubtasks(_ t: TaskItem, _ db: SQLiteDatabase) throws {
        try db.run("DELETE FROM subtasks WHERE task_id = ?;", [.text(t.id.uuidString)])
        for s in t.subtasks {
            try db.run("INSERT INTO subtasks (id, task_id, title, done, position) VALUES (?,?,?,?,?);",
                       [.text(s.id.uuidString), .text(t.id.uuidString), .text(s.title),
                        .int(s.isDone ? 1 : 0), .double(s.position)])
        }
    }

    // MARK: - SQL: meetings

    private static func loadMeetings(from db: SQLiteDatabase) throws -> [Meeting] {
        var items: [UUID: [ActionItem]] = [:]
        try db.query("""
            SELECT id, meeting_id, title, assignee, due, confidence, state, task_id, position
            FROM action_items ORDER BY position;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)),
                  let mid = UUID(uuidString: row.string(1)) else { return }
            items[mid, default: []].append(ActionItem(
                id: id, meetingID: mid, title: row.string(2), assignee: row.stringOrNil(3),
                dueDate: row.doubleOrNil(4).map(Date.init(timeIntervalSince1970:)),
                confidence: row.double(5),
                state: ActionItem.State(rawValue: row.string(6)) ?? .suggested,
                taskID: row.stringOrNil(7).flatMap(UUID.init(uuidString:)),
                position: row.double(8)))
        }

        var out: [Meeting] = []
        try db.query("""
            SELECT id, remote_id, title, started, duration, status, audio_filename, uploaded,
                   processed, failure, job_id, summary, key_points, decisions, questions,
                   topics, participants
            FROM meetings ORDER BY started DESC;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            out.append(Meeting(
                id: id,
                remoteID: row.stringOrNil(1),
                title: row.string(2),
                startedAt: Date(timeIntervalSince1970: row.double(3)),
                duration: row.double(4),
                status: MeetingStatus(rawValue: row.string(5)) ?? .completed,
                audioFilename: row.stringOrNil(6),
                uploadedAt: row.doubleOrNil(7).map(Date.init(timeIntervalSince1970:)),
                processedAt: row.doubleOrNil(8).map(Date.init(timeIntervalSince1970:)),
                failureReason: row.stringOrNil(9),
                jobID: row.stringOrNil(10),
                summary: row.string(11),
                keyPoints: decodeStrings(row.string(12)),
                decisions: decodeStrings(row.string(13)),
                questions: decodeStrings(row.string(14)),
                topics: decodeStrings(row.string(15)),
                participants: decodeStrings(row.string(16)),
                actionItems: items[id] ?? [],
                transcript: []))
        }
        return out
    }

    private static func writeMeeting(_ m: Meeting, into db: SQLiteDatabase) throws {
        try db.transaction {
            try db.run("""
                INSERT OR REPLACE INTO meetings
                (id, remote_id, title, started, duration, status, audio_filename, uploaded,
                 processed, failure, job_id, summary, key_points, decisions, questions,
                 topics, participants)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """,
                [.text(m.id.uuidString), m.remoteID.map { .text($0) } ?? .null, .text(m.title),
                 .double(m.startedAt.timeIntervalSince1970), .double(m.duration), .text(m.status.rawValue),
                 m.audioFilename.map { .text($0) } ?? .null, .date(m.uploadedAt), .date(m.processedAt),
                 m.failureReason.map { .text($0) } ?? .null, m.jobID.map { .text($0) } ?? .null,
                 .text(m.summary), .text(encodeStrings(m.keyPoints)), .text(encodeStrings(m.decisions)),
                 .text(encodeStrings(m.questions)), .text(encodeStrings(m.topics)),
                 .text(encodeStrings(m.participants))])

            try db.run("DELETE FROM action_items WHERE meeting_id = ?;", [.text(m.id.uuidString)])
            for item in m.actionItems {
                try db.run("""
                    INSERT INTO action_items
                    (id, meeting_id, title, assignee, due, confidence, state, task_id, position)
                    VALUES (?,?,?,?,?,?,?,?,?);
                    """,
                    [.text(item.id.uuidString), .text(m.id.uuidString), .text(item.title),
                     item.assignee.map { .text($0) } ?? .null, .date(item.dueDate),
                     .double(item.confidence), .text(item.state.rawValue),
                     item.taskID.map { .text($0.uuidString) } ?? .null, .double(item.position)])
            }

            if !m.transcript.isEmpty {
                try db.run("DELETE FROM transcript_segments WHERE meeting_id = ?;", [.text(m.id.uuidString)])
                for s in m.transcript {
                    try db.run("""
                        INSERT INTO transcript_segments (id, meeting_id, start, finish, speaker, text)
                        VALUES (?,?,?,?,?,?);
                        """,
                        [.text(s.id.uuidString), .text(m.id.uuidString), .double(s.start),
                         .double(s.end), s.speaker.map { .text($0) } ?? .null, .text(s.text)])
                }
            }
        }
    }

    private static func encodeStrings(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeStrings(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }
}
