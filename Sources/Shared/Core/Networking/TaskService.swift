import Foundation

/// The one place a task mutation is defined on the Mac.
///
/// Every call does two things: apply the change to the local cache immediately so the
/// UI never waits, and queue the equivalent request for the VPS. When no VPS is
/// configured the queue is skipped and the app is simply local. The server remains the
/// source of truth; this is an optimistic client, not a second backend.
@MainActor
public struct TaskService {

    public let store: LocalStore
    /// False until a VPS URL is configured; then every mutation also hits the outbox.
    public var syncEnabled: Bool

    public init(store: LocalStore, syncEnabled: Bool = false) {
        self.store = store
        self.syncEnabled = syncEnabled
    }

    // MARK: Read

    public func list(_ q: ListQuery = ListQuery(), now: Date = Date()) -> [TaskItem] {
        var items = store.tasks.filter { t in
            if !q.includeArchived && t.isArchived { return false }
            if !q.includeDone && t.isDone { return false }
            if let s = q.status, t.status != s { return false }
            if let p = q.priority, t.priority != p { return false }
            if let source = q.source, t.source != source { return false }
            if let meetingID = q.meetingID, t.meetingID != meetingID { return false }
            if let tag = q.tag, !t.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return false }
            if let query = q.query, !query.isEmpty, !t.matches(query: query) { return false }
            if let due = q.due?.lowercased() {
                let cal = Calendar.current
                switch due {
                case "today": if !t.isDueToday(now: now, calendar: cal) { return false }
                case "overdue": if !t.isOverdue(now: now, calendar: cal) { return false }
                case "week":
                    guard let d = t.dueDate,
                          let end = cal.date(byAdding: .day, value: 7, to: now), d <= end else { return false }
                case "none": if t.dueDate != nil { return false }
                case "any": if t.dueDate == nil { return false }
                default: break
                }
            }
            return true
        }
        items = (q.query?.isEmpty == false) ? items.agendaSorted(now: now) : items.boardSorted()
        if let limit = q.limit { items = Array(items.prefix(limit)) }
        return items
    }

    public func summary(now: Date = Date()) -> SummaryDTO {
        let c = store.counts(now: now)
        var byStatus: [String: Int] = [:]
        for status in TaskStatus.allCases {
            byStatus[status.rawValue] = store.tasks.filter { $0.status == status && !$0.isArchived }.count
        }
        let cal = Calendar.current
        let doneToday = store.tasks.filter {
            guard let d = $0.completedAt, !$0.isArchived else { return false }
            return cal.isDate(d, inSameDayAs: now)
        }.count
        let agenda = store.openTasks.agendaSorted(now: now).prefix(10).map { TaskDTO($0, now: now) }
        return SummaryDTO(open: c.open, active: c.active, dueToday: c.dueToday, overdue: c.overdue,
                          doneToday: doneToday, byStatus: byStatus, agenda: Array(agenda),
                          generatedAt: DateInput.iso(now))
    }

    // MARK: Write

    @discardableResult
    public func create(_ body: CreateTaskBody) throws -> TaskItem {
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw APIError.badRequest("title is required") }

        var task = TaskItem(id: body.id.flatMap(UUID.init(uuidString:)) ?? UUID(), title: title)
        task.notes = body.notes ?? ""
        if let s = body.status {
            guard let status = TaskStatus.parse(s) else { throw APIError.badRequest("unknown status '\(s)'") }
            task.status = status
        }
        if let p = body.priority {
            guard let priority = Priority.parse(p) else { throw APIError.badRequest("unknown priority '\(p)'") }
            task.priority = priority
        }
        if let d = body.due, !d.isEmpty {
            guard let date = DateInput.parse(d) else { throw APIError.badRequest("could not parse due '\(d)'") }
            task.dueDate = date
        }
        task.tags = Self.normalise(body.tags ?? [])
        task.subtasks = (body.subtasks ?? []).enumerated().map { Subtask(title: $1, position: Double($0)) }
        if let pos = body.position { task.position = pos }
        task.source = body.source.flatMap(TaskSource.init(rawValue:)) ?? .manual
        task.meetingID = body.meetingId.flatMap(UUID.init(uuidString:))
        task.actionItemID = body.actionItemId.flatMap(UUID.init(uuidString:))

        let created = store.createTask(task)
        queue(.init(kind: "task.create", method: "POST", path: "/tasks",
                    body: Self.createBody(for: created), entityID: created.id))
        return created
    }

    @discardableResult
    public func patch(_ id: UUID, _ body: PatchTaskBody) throws -> TaskItem {
        guard store.task(id) != nil else { throw APIError.notFound("no task with id \(id.uuidString)") }

        var status: TaskStatus?
        if let s = body.status {
            guard let parsed = TaskStatus.parse(s) else { throw APIError.badRequest("unknown status '\(s)'") }
            status = parsed
        }
        var priority: Priority?
        if let p = body.priority {
            guard let parsed = Priority.parse(p) else { throw APIError.badRequest("unknown priority '\(p)'") }
            priority = parsed
        }
        var due: Date??
        if let d = body.due {
            if d.isEmpty || ["none", "clear", "never", "-"].contains(d.lowercased()) {
                due = .some(nil)
            } else if let date = DateInput.parse(d) {
                due = .some(date)
            } else {
                throw APIError.badRequest("could not parse due '\(d)'")
            }
        }

        if let status { store.moveTask(id, to: status, index: 0) }

        guard let updated = store.updateTask(id, { t in
            if let v = body.title { t.title = v }
            if let v = body.notes { t.notes = v }
            if let priority { t.priority = priority }
            if let due { t.dueDate = due }
            if let v = body.tags { t.tags = Self.normalise(v) }
            if let v = body.archived { t.archivedAt = v ? (t.archivedAt ?? Date()) : nil }
            if let v = body.position { t.position = v }
        }) ?? store.task(id) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.update", method: "PATCH", path: "/tasks/\(id.uuidString)",
                    body: Self.patchBody(for: updated), entityID: id))
        return updated
    }

    @discardableResult
    public func move(_ id: UUID, to status: TaskStatus, index: Int? = nil) throws -> TaskItem {
        guard let moved = store.moveTask(id, to: status, index: index) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.move", method: "POST", path: "/tasks/\(id.uuidString)/move",
                    body: MoveBody(status: status.rawValue, index: index, position: moved.position),
                    entityID: id))
        return moved
    }

    @discardableResult
    public func complete(_ id: UUID) throws -> TaskItem {
        guard let t = store.completeTask(id) else { throw APIError.notFound("no task with id \(id.uuidString)") }
        queue(.init(kind: "task.complete", method: "POST", path: "/tasks/\(id.uuidString)/complete",
                    body: Empty(), entityID: id))
        return t
    }

    @discardableResult
    public func reopen(_ id: UUID, to status: TaskStatus = .todo) throws -> TaskItem {
        guard let t = store.reopenTask(id, to: status) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.move", method: "POST", path: "/tasks/\(id.uuidString)/move",
                    body: MoveBody(status: status.rawValue, index: 0), entityID: id))
        return t
    }

    /// `hard: false` archives (recoverable); `hard: true` removes the row.
    @discardableResult
    public func delete(_ id: UUID, hard: Bool = false) throws -> TaskItem {
        guard let existing = store.task(id) else { throw APIError.notFound("no task with id \(id.uuidString)") }
        if hard {
            store.deleteTask(id)
            queue(.init(kind: "task.delete", method: "DELETE", path: "/tasks/\(id.uuidString)",
                        body: Empty(), entityID: id, collapse: false))
            return existing
        }
        guard let archived = store.archiveTask(id) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.update", method: "PATCH", path: "/tasks/\(id.uuidString)",
                    body: Self.patchBody(for: archived), entityID: id))
        return archived
    }

    /// Closure-style edit for the inspector and context menus. Applies locally and
    /// queues the resulting state for the server, same as `patch`.
    @discardableResult
    public func edit(_ id: UUID, _ mutate: (inout TaskItem) -> Void) throws -> TaskItem {
        guard let updated = store.updateTask(id, mutate) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.update", method: "PATCH", path: "/tasks/\(id.uuidString)",
                    body: Self.patchBody(for: updated), entityID: id))
        return updated
    }

    @discardableResult
    public func unarchive(_ id: UUID) throws -> TaskItem {
        try patch(id, PatchTaskBody(archived: false))
    }

    // MARK: Subtasks

    @discardableResult
    public func addSubtask(_ id: UUID, title: String) throws -> TaskItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.badRequest("subtask title is required") }
        guard store.addSubtask(to: id, title: trimmed) != nil, let t = store.task(id) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.update", method: "PATCH", path: "/tasks/\(id.uuidString)",
                    body: Self.patchBody(for: t), entityID: id))
        return t
    }

    @discardableResult
    public func setSubtask(_ subtaskID: UUID, on id: UUID, done: Bool? = nil, title: String? = nil) throws -> TaskItem {
        guard let t = store.setSubtask(subtaskID, on: id, done: done, title: title) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.update", method: "PATCH", path: "/tasks/\(id.uuidString)",
                    body: Self.patchBody(for: t), entityID: id))
        return t
    }

    @discardableResult
    public func removeSubtask(_ subtaskID: UUID, from id: UUID) throws -> TaskItem {
        guard let t = store.removeSubtask(subtaskID, from: id) else {
            throw APIError.notFound("no task with id \(id.uuidString)")
        }
        queue(.init(kind: "task.update", method: "PATCH", path: "/tasks/\(id.uuidString)",
                    body: Self.patchBody(for: t), entityID: id))
        return t
    }

    // MARK: Outbox plumbing

    struct Operation<Body: Encodable> {
        var kind: String
        var method: String
        var path: String
        var body: Body
        var entityID: UUID
        var collapse: Bool = true
    }

    struct Empty: Encodable {}

    private func queue<Body: Encodable>(_ op: Operation<Body>) {
        guard syncEnabled else { return }
        let data = (op.body is Empty) ? nil : try? JSONEncoder().encode(op.body)
        store.enqueue(kind: op.kind, method: op.method, path: op.path,
                      body: data, entityID: op.entityID, collapse: op.collapse)
    }

    /// The shape `POST /api/v1/tasks` expects. The local id is included so a replay
    /// after reconnecting is idempotent rather than creating a duplicate.
    static func createBody(for task: TaskItem) -> CreateTaskBody {
        CreateTaskBody(
            id: task.id.uuidString,
            title: task.title,
            notes: task.notes,
            status: task.status.rawValue,
            priority: task.priority.longLabel.lowercased(),
            due: task.dueDate.map(DateInput.iso),
            tags: task.tags,
            subtasks: task.subtasks.map(\.title),
            position: task.position,
            source: task.source.rawValue,
            meetingId: task.meetingID?.uuidString,
            actionItemId: task.actionItemID?.uuidString)
    }

    /// The shape `PATCH /api/v1/tasks/:id` expects. Sends the full current state:
    /// the outbox collapses repeat edits, so last-write-wins is the intended result.
    static func patchBody(for task: TaskItem) -> PatchTaskBody {
        PatchTaskBody(
            title: task.title,
            notes: task.notes,
            status: task.status.rawValue,
            priority: task.priority.longLabel.lowercased(),
            due: task.dueDate.map(DateInput.iso) ?? "none",
            tags: task.tags,
            archived: task.isArchived,
            position: task.position)
    }

    nonisolated static func normalise(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #")).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
