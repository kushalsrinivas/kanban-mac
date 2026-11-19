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
    /// Meetings the user scheduled. Local-only, sorted by start time.
    public private(set) var scheduledMeetings: [ScheduledMeeting] = []
    /// User-configured automation rules and their audit trail.
    public private(set) var automationRules: [AutomationRule] = []
    public private(set) var automationRuns: [AutomationRun] = []
    /// Emails and notes composed locally. A draft, never a silent no-op.
    public private(set) var localMessages: [LocalMessage] = []
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
            scheduledMeetings = try Self.loadScheduledMeetings(from: database)
            automationRules = try Self.loadAutomationRules(from: database)
            automationRuns = try Self.loadAutomationRuns(from: database)
            localMessages = try Self.loadLocalMessages(from: database)
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

    public func snapshot(now: Date = Date(), recording: BoardSnapshot.Recording? = nil) -> BoardSnapshot {
        BoardSnapshot.make(from: tasks, recording: recording,
                           suggestedCount: meetings.reduce(0) { $0 + $1.suggestedCount },
                           now: now)
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
        localMessages.removeAll { $0.meetingID == id }
        automationRuns.removeAll { $0.meetingID == id }
        write { db in
            try db.transaction {
                try db.run("DELETE FROM transcript_segments WHERE meeting_id = ?;", [.text(id.uuidString)])
                try db.run("DELETE FROM action_items WHERE meeting_id = ?;", [.text(id.uuidString)])
                try db.run("DELETE FROM local_messages WHERE meeting_id = ?;", [.text(id.uuidString)])
                try db.run("DELETE FROM automation_runs WHERE meeting_id = ?;", [.text(id.uuidString)])
                try db.run("DELETE FROM meetings WHERE id = ?;", [.text(id.uuidString)])
            }
        }
        // Tasks created from it keep their text but lose the dangling reference.
        for task in tasks.filter({ $0.meetingID == id }) {
            updateTask(task.id) { $0.meetingID = nil; $0.actionItemID = nil }
        }
        for scheduled in scheduledMeetings where scheduled.meetingID == id {
            updateScheduledMeeting(scheduled.id) { $0.meetingID = nil }
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

    // MARK: - Commitments

    /// Every open promise, newest meeting first.
    public var openCommitments: [ActionItem] {
        meetings.flatMap { $0.actionItems }.filter { $0.isOpen && $0.state != .dismissed }
    }

    public var overdueCommitments: [ActionItem] {
        let now = Date()
        return openCommitments.filter { $0.isOverdue(now: now) }
    }

    public func commitment(_ id: UUID) -> (item: ActionItem, meeting: Meeting)? {
        for meeting in meetings {
            if let item = meeting.actionItems.first(where: { $0.id == id }) {
                return (item, meeting)
            }
        }
        return nil
    }

    /// Execution state and board task stay in step: the task is the same commitment
    /// in a different view, so they must not disagree.
    @discardableResult
    public func setCommitmentState(_ itemID: UUID, in meetingID: UUID,
                                   to state: ActionItem.Commitment,
                                   now: Date = Date()) -> Meeting? {
        // A caller can hold a stale meeting id (for example after a merge). Resolve
        // by the item id rather than silently doing nothing.
        guard let resolved = resolveMeetingID(meetingID, containing: itemID) else { return nil }
        let updated = updateMeeting(resolved) { meeting in
            guard let i = meeting.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            meeting.actionItems[i].commitmentState = state
            meeting.actionItems[i].completedAt = state == .done ? now : nil
            if let taskID = meeting.actionItems[i].taskID {
                if state == .done, task(taskID)?.status != .done {
                    completeTask(taskID)
                } else if state == .open, task(taskID)?.status == .done {
                    reopenTask(taskID)
                }
            }
        }
        return updated
    }

    @discardableResult
    public func markCommitmentReminded(_ itemID: UUID, in meetingID: UUID,
                                       at date: Date = Date()) -> Meeting? {
        guard let resolved = resolveMeetingID(meetingID, containing: itemID) else { return nil }
        return updateMeeting(resolved) { meeting in
            guard let i = meeting.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            meeting.actionItems[i].remindedAt = date
        }
    }

    /// The meeting id that owns an action item, accepting the caller's id when it
    /// matches and otherwise resolving the item across the local cache.
    private func resolveMeetingID(_ preferred: UUID, containing itemID: UUID) -> UUID? {
        if meetings.contains(where: { meeting in
            meeting.id == preferred && meeting.actionItems.contains { $0.id == itemID }
        }) {
            return preferred
        }
        return meetings.first(where: { meeting in
            meeting.actionItems.contains { $0.id == itemID }
        })?.id
    }

    // MARK: - Automations

    public func automationRule(_ id: UUID) -> AutomationRule? {
        automationRules.first { $0.id == id }
    }

    public func runs(for ruleID: UUID) -> [AutomationRun] {
        automationRuns.filter { $0.ruleID == ruleID }
    }

    @discardableResult
    public func upsertAutomationRule(_ rule: AutomationRule) -> AutomationRule {
        if let index = automationRules.firstIndex(where: { $0.id == rule.id }) {
            automationRules[index] = rule
        } else {
            automationRules.append(rule)
        }
        automationRules.sort { $0.createdAt < $1.createdAt }
        write { db in
            let conditions = (try? String(data: JSONEncoder().encode(rule.conditions),
                                         encoding: .utf8)) ?? "{}"
            let actions = (try? String(data: JSONEncoder().encode(rule.actions),
                                      encoding: .utf8)) ?? "[]"
            try db.run("""
                INSERT INTO automation_rules
                (id, name, enabled, trigger, conditions, actions, created, last_run)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    name=excluded.name, enabled=excluded.enabled, trigger=excluded.trigger,
                    conditions=excluded.conditions, actions=excluded.actions,
                    last_run=excluded.last_run;
                """,
                [.text(rule.id.uuidString), .text(rule.name), .int(rule.enabled ? 1 : 0),
                 .text(rule.trigger.rawValue), .text(conditions), .text(actions),
                 .double(rule.createdAt.timeIntervalSince1970), .date(rule.lastRunAt)])
        }
        didMutate()
        return rule
    }

    @discardableResult
    public func deleteAutomationRule(_ id: UUID) -> Bool {
        guard automationRules.contains(where: { $0.id == id }) else { return false }
        automationRules.removeAll { $0.id == id }
        write { try $0.run("DELETE FROM automation_rules WHERE id = ?;",
                           [.text(id.uuidString)]) }
        didMutate()
        return true
    }

    @discardableResult
    public func recordAutomationRun(_ run: AutomationRun) -> AutomationRun {
        automationRuns.insert(run, at: 0)
        if automationRuns.count > 200 { automationRuns.removeLast(automationRuns.count - 200) }
        write { db in
            try db.run("""
                INSERT OR REPLACE INTO automation_runs
                (id, rule_id, rule_name, meeting_id, status, detail, started, finished)
                VALUES (?,?,?,?,?,?,?,?);
                """,
                [.text(run.id.uuidString),
                 run.ruleID.map { .text($0.uuidString) } ?? .null,
                 .text(run.ruleName), run.meetingID.map { .text($0.uuidString) } ?? .null,
                 .text(run.status.rawValue), .text(run.detail),
                 .double(run.startedAt.timeIntervalSince1970),
                 .double(run.finishedAt.timeIntervalSince1970)])
        }
        if let ruleID = run.ruleID,
           let index = automationRules.firstIndex(where: { $0.id == ruleID }) {
            automationRules[index].lastRunAt = run.finishedAt
            upsertAutomationRule(automationRules[index])
        }
        return run
    }

    // MARK: - Local messages

    public func messages(for meetingID: UUID) -> [LocalMessage] {
        localMessages.filter { $0.meetingID == meetingID }
    }

    @discardableResult
    public func addLocalMessage(_ message: LocalMessage) -> LocalMessage {
        localMessages.insert(message, at: 0)
        if localMessages.count > 200 { localMessages.removeLast(localMessages.count - 200) }
        write { db in
            try db.run("""
                INSERT OR REPLACE INTO local_messages
                (id, kind, status, recipients, subject, body, meeting_id, commitment_id,
                 created, sent)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """,
                [.text(message.id.uuidString), .text(message.kind.rawValue),
                 .text(message.status.rawValue),
                 .text((try? String(data: JSONEncoder().encode(message.recipients),
                                   encoding: .utf8)) ?? "[]"),
                 .text(message.subject), .text(message.body),
                 message.meetingID.map { .text($0.uuidString) } ?? .null,
                 message.commitmentID.map { .text($0.uuidString) } ?? .null,
                 .double(message.createdAt.timeIntervalSince1970), .date(message.sentAt)])
        }
        didMutate()
        return message
    }

    @discardableResult
    public func markMessageSent(_ id: UUID, at date: Date = Date()) -> LocalMessage? {
        guard let index = localMessages.firstIndex(where: { $0.id == id }) else { return nil }
        localMessages[index].status = .sent
        localMessages[index].sentAt = date
        let message = localMessages[index]
        write { try $0.run("UPDATE local_messages SET status = 'sent', sent = ? WHERE id = ?;",
                           [.double(date.timeIntervalSince1970), .text(id.uuidString)]) }
        didMutate()
        return message
    }

    // MARK: - Scheduled meetings

    public func scheduledMeeting(_ id: UUID) -> ScheduledMeeting? {
        scheduledMeetings.first { $0.id == id }
    }

    public var upcomingScheduledMeetings: [ScheduledMeeting] {
        scheduledMeetings.upcoming()
    }

    public func scheduledMeetingsBetween(_ start: Date, _ end: Date) -> [ScheduledMeeting] {
        scheduledMeetings.filter { $0.endsAt >= start && $0.startsAt <= end }.scheduledSorted()
    }

    @discardableResult
    public func upsertScheduledMeeting(_ value: ScheduledMeeting) -> ScheduledMeeting {
        var meeting = value
        meeting.updatedAt = Date()
        if let index = scheduledMeetings.firstIndex(where: { $0.id == meeting.id }) {
            scheduledMeetings[index] = meeting
        } else {
            scheduledMeetings.append(meeting)
        }
        scheduledMeetings.sort { $0.startsAt < $1.startsAt }
        write { try Self.writeScheduledMeeting(meeting, into: $0) }
        didMutate()
        return meeting
    }

    @discardableResult
    public func updateScheduledMeeting(_ id: UUID,
                                       _ edit: (inout ScheduledMeeting) -> Void) -> ScheduledMeeting? {
        guard let index = scheduledMeetings.firstIndex(where: { $0.id == id }) else { return nil }
        var meeting = scheduledMeetings[index]
        edit(&meeting)
        meeting.updatedAt = Date()
        scheduledMeetings[index] = meeting
        scheduledMeetings.sort { $0.startsAt < $1.startsAt }
        write { try Self.writeScheduledMeeting(meeting, into: $0) }
        didMutate()
        return meeting
    }

    @discardableResult
    public func deleteScheduledMeeting(_ id: UUID) -> Bool {
        guard let index = scheduledMeetings.firstIndex(where: { $0.id == id }) else { return false }
        scheduledMeetings.remove(at: index)
        write { try $0.run("DELETE FROM scheduled_meetings WHERE id = ?;",
                           [.text(id.uuidString)]) }
        didMutate()
        return true
    }

    @discardableResult
    public func linkScheduledMeeting(_ id: UUID, to meetingID: UUID) -> ScheduledMeeting? {
        updateScheduledMeeting(id) { $0.meetingID = meetingID }
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
            SELECT id, meeting_id, title, assignee, due, confidence, state, task_id, position,
                   quote, source_start, source_end, commitment_state, completed_at, reminded_at
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
                position: row.double(8),
                quote: row.stringOrNil(9),
                sourceStart: row.doubleOrNil(10),
                sourceEnd: row.doubleOrNil(11),
                commitmentState: ActionItem.Commitment(rawValue: row.string(12)) ?? .open,
                completedAt: row.doubleOrNil(13).map(Date.init(timeIntervalSince1970:)),
                remindedAt: row.doubleOrNil(14).map(Date.init(timeIntervalSince1970:))))
        }

        var out: [Meeting] = []
        var seen: Set<UUID> = []
        try db.query("""
            SELECT id, remote_id, title, started, duration, status, audio_filename, uploaded,
                   processed, failure, job_id, summary, key_points, decisions, questions,
                   topics, participants
            FROM meetings ORDER BY started DESC;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)), !seen.contains(id) else { return }
            seen.insert(id)
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
            // UPSERT, never INSERT OR REPLACE: replacing the row would delete it and
            // fire ON DELETE CASCADE across transcript_segments. Meetings are loaded
            // without their transcript, so any later status change would wipe it.
            try db.run("""
                INSERT INTO meetings
                (id, remote_id, title, started, duration, status, audio_filename, uploaded,
                 processed, failure, job_id, summary, key_points, decisions, questions,
                 topics, participants)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    remote_id=excluded.remote_id, title=excluded.title, started=excluded.started,
                    duration=excluded.duration, status=excluded.status,
                    audio_filename=excluded.audio_filename, uploaded=excluded.uploaded,
                    processed=excluded.processed, failure=excluded.failure, job_id=excluded.job_id,
                    summary=excluded.summary, key_points=excluded.key_points,
                    decisions=excluded.decisions, questions=excluded.questions,
                    topics=excluded.topics, participants=excluded.participants;
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
                    (id, meeting_id, title, assignee, due, confidence, state, task_id, position,
                     quote, source_start, source_end, commitment_state, completed_at, reminded_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """,
                    [.text(item.id.uuidString), .text(m.id.uuidString), .text(item.title),
                     item.assignee.map { .text($0) } ?? .null, .date(item.dueDate),
                     .double(item.confidence), .text(item.state.rawValue),
                     item.taskID.map { .text($0.uuidString) } ?? .null, .double(item.position),
                     item.quote.map { .text($0) } ?? .null,
                     item.sourceStart.map { .double($0) } ?? .null,
                     item.sourceEnd.map { .double($0) } ?? .null,
                     .text(item.commitmentState.rawValue), .date(item.completedAt),
                     .date(item.remindedAt)])
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

    // MARK: - SQL: automations

    private static func loadAutomationRules(from db: SQLiteDatabase) throws -> [AutomationRule] {
        var out: [AutomationRule] = []
        let decoder = JSONDecoder()
        try db.query("""
            SELECT id, name, enabled, trigger, conditions, actions, created, last_run
            FROM automation_rules ORDER BY created;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            let conditions = (try? decoder.decode(AutomationConditions.self,
                                                  from: Data(row.string(4).utf8)))
                ?? AutomationConditions()
            let actions = (try? decoder.decode([AutomationAction].self,
                                               from: Data(row.string(5).utf8))) ?? []
            out.append(AutomationRule(
                id: id, name: row.string(1), enabled: row.int(2) != 0,
                trigger: AutomationTrigger(rawValue: row.string(3)) ?? .meetingCompleted,
                conditions: conditions, actions: actions,
                createdAt: Date(timeIntervalSince1970: row.double(6)),
                lastRunAt: row.doubleOrNil(7).map(Date.init(timeIntervalSince1970:))))
        }
        return out
    }

    private static func loadAutomationRuns(from db: SQLiteDatabase) throws -> [AutomationRun] {
        var out: [AutomationRun] = []
        try db.query("""
            SELECT id, rule_id, rule_name, meeting_id, status, detail, started, finished
            FROM automation_runs ORDER BY started DESC LIMIT 200;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            out.append(AutomationRun(
                id: id,
                ruleID: row.stringOrNil(1).flatMap(UUID.init(uuidString:)),
                ruleName: row.string(2),
                meetingID: row.stringOrNil(3).flatMap(UUID.init(uuidString:)),
                status: AutomationRun.Status(rawValue: row.string(4)) ?? .completed,
                detail: row.string(5),
                startedAt: Date(timeIntervalSince1970: row.double(6)),
                finishedAt: row.doubleOrNil(7).map(Date.init(timeIntervalSince1970:))
                    ?? Date(timeIntervalSince1970: row.double(6))))
        }
        return out
    }

    private static func loadLocalMessages(from db: SQLiteDatabase) throws -> [LocalMessage] {
        var out: [LocalMessage] = []
        try db.query("""
            SELECT id, kind, status, recipients, subject, body, meeting_id, commitment_id,
                   created, sent
            FROM local_messages ORDER BY created DESC LIMIT 200;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            let recipients = (try? JSONDecoder().decode([String].self,
                                                        from: Data(row.string(3).utf8))) ?? []
            out.append(LocalMessage(
                id: id,
                kind: LocalMessage.Kind(rawValue: row.string(1)) ?? .email,
                status: LocalMessage.Status(rawValue: row.string(2)) ?? .draft,
                recipients: recipients, subject: row.string(4), body: row.string(5),
                meetingID: row.stringOrNil(6).flatMap(UUID.init(uuidString:)),
                commitmentID: row.stringOrNil(7).flatMap(UUID.init(uuidString:)),
                createdAt: Date(timeIntervalSince1970: row.double(8)),
                sentAt: row.doubleOrNil(9).map(Date.init(timeIntervalSince1970:))))
        }
        return out
    }

    // MARK: - SQL: scheduled meetings

    private static func loadScheduledMeetings(from db: SQLiteDatabase) throws -> [ScheduledMeeting] {
        var out: [ScheduledMeeting] = []
        try db.query("""
            SELECT id, title, notes, location, starts, ends, participants, meeting_id,
                   created, updated
            FROM scheduled_meetings ORDER BY starts;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            out.append(ScheduledMeeting(
                id: id,
                title: row.string(1),
                notes: row.string(2),
                location: row.string(3),
                startsAt: Date(timeIntervalSince1970: row.double(4)),
                endsAt: Date(timeIntervalSince1970: row.double(5)),
                participants: decodeStrings(row.string(6)),
                meetingID: row.stringOrNil(7).flatMap(UUID.init(uuidString:)),
                createdAt: Date(timeIntervalSince1970: row.double(8)),
                updatedAt: Date(timeIntervalSince1970: row.double(9))))
        }
        return out
    }

    private static func writeScheduledMeeting(_ meeting: ScheduledMeeting,
                                              into db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO scheduled_meetings
            (id, title, notes, location, starts, ends, participants, meeting_id, created, updated)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title, notes=excluded.notes, location=excluded.location,
                starts=excluded.starts, ends=excluded.ends,
                participants=excluded.participants, meeting_id=excluded.meeting_id,
                created=excluded.created, updated=excluded.updated;
            """,
            [.text(meeting.id.uuidString), .text(meeting.title), .text(meeting.notes),
             .text(meeting.location), .double(meeting.startsAt.timeIntervalSince1970),
             .double(meeting.endsAt.timeIntervalSince1970),
             .text(encodeStrings(meeting.participants)),
             meeting.meetingID.map { .text($0.uuidString) } ?? .null,
             .double(meeting.createdAt.timeIntervalSince1970),
             .double(meeting.updatedAt.timeIntervalSince1970)])
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
