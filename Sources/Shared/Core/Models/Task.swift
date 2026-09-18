import Foundation

// MARK: - Status

/// Where a task sits on the board. Raw values are the wire contract with the VPS.
public enum TaskStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case inbox
    case todo
    case inProgress = "in_progress"
    case done

    /// Column heading. "IN PROGRESS" is too wide for a 248pt column, so the board
    /// says ACTIVE while the data model stays explicit.
    public var label: String {
        switch self {
        case .inbox: return "INBOX"
        case .todo: return "TODO"
        case .inProgress: return "ACTIVE"
        case .done: return "DONE"
        }
    }

    public var longLabel: String {
        self == .inProgress ? "IN PROGRESS" : label
    }

    /// Accepts loose input from the agent, the command palette and quick-add.
    public static func parse(_ raw: String) -> TaskStatus? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch s {
        case "inbox", "in", "1": return .inbox
        case "todo", "to do", "to_do", "next", "backlog", "2": return .todo
        case "active", "in progress", "in-progress", "in_progress", "inprogress",
             "doing", "wip", "progress", "3": return .inProgress
        case "done", "complete", "completed", "finished", "4": return .done
        default: return nil
        }
    }

    public var isTerminal: Bool { self == .done }
}

// MARK: - Source

/// Where a task came from. Worth tracking because a task the agent or a meeting
/// produced deserves a different level of trust than one the user typed.
public enum TaskSource: String, Codable, CaseIterable, Sendable, Hashable {
    case manual
    case meeting
    case agent

    public var label: String { rawValue.uppercased() }
}

// MARK: - Priority

public enum Priority: Int, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    case urgent = 3

    public var label: String {
        switch self {
        case .low: return "LOW"
        case .medium: return "MED"
        case .high: return "HIGH"
        case .urgent: return "URG"
        }
    }

    public var longLabel: String {
        switch self {
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        case .urgent: return "URGENT"
        }
    }

    public static func parse(_ raw: String) -> Priority? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low", "l", "0": return .low
        case "med", "medium", "m", "normal", "1": return .medium
        case "high", "h", "2": return .high
        case "urg", "urgent", "u", "critical", "crit", "asap", "3": return .urgent
        default: return nil
        }
    }

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Subtask

public struct Subtask: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var isDone: Bool
    public var position: Double

    public init(id: UUID = UUID(), title: String, isDone: Bool = false, position: Double = 0) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.position = position
    }
}

// MARK: - Task

public struct TaskItem: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public var priority: Priority
    public var dueDate: Date?
    public var tags: [String]
    public var subtasks: [Subtask]
    /// Sort key inside a column. Sparse doubles so reordering is one UPDATE.
    public var position: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var archivedAt: Date?

    // Provenance
    public var source: TaskSource
    /// The meeting this task came out of, when `source == .meeting`.
    public var meetingID: UUID?
    /// The specific suggested action item, so the meeting page can show what was added.
    public var actionItemID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        status: TaskStatus = .inbox,
        priority: Priority = .medium,
        dueDate: Date? = nil,
        tags: [String] = [],
        subtasks: [Subtask] = [],
        position: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        source: TaskSource = .manual,
        meetingID: UUID? = nil,
        actionItemID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.tags = tags
        self.subtasks = subtasks
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.source = source
        self.meetingID = meetingID
        self.actionItemID = actionItemID
    }

    public var isArchived: Bool { archivedAt != nil }
    public var isDone: Bool { status == .done }
    public var isOpen: Bool { !isDone && !isArchived }

    public var doneSubtaskCount: Int { subtasks.reduce(0) { $0 + ($1.isDone ? 1 : 0) } }

    public func isDueToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due = dueDate else { return false }
        return calendar.isDate(due, inSameDayAs: now)
    }

    public func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due = dueDate, isOpen else { return false }
        return due < now && !calendar.isDate(due, inSameDayAs: now)
    }

    /// Matches free text across title, notes and tags. Case and diacritic insensitive.
    public func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: q, options: opts) != nil { return true }
        if notes.range(of: q, options: opts) != nil { return true }
        for tag in tags where tag.range(of: q, options: opts) != nil { return true }
        return false
    }
}

// MARK: - Sorting

public extension Array where Element == TaskItem {
    /// Board order: explicit position, newest first as a tiebreaker.
    func boardSorted() -> [TaskItem] {
        sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.createdAt > $1.createdAt
        }
    }

    /// "What should I do next": overdue, then due soonest, then priority, then position.
    func agendaSorted(now: Date = Date()) -> [TaskItem] {
        sorted { a, b in
            let ao = a.isOverdue(now: now), bo = b.isOverdue(now: now)
            if ao != bo { return ao }
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.position < b.position
        }
    }
}
