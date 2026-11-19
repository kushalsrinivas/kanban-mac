import Foundation

/// A validated, user-confirmable write.
///
/// Both planners (the deterministic parser and the Gemini schema) produce this one
/// type, so there is exactly one execution path and one place that can change the
/// board on the agent's behalf.
public struct AgentOperation: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case createTask = "create_task"
        case updateTask = "update_task"
        case moveTask = "move_task"
        case completeTask = "complete_task"
        case archiveTask = "archive_task"
        case deleteTask = "delete_task"
    }

    public var id: String
    public var kind: Kind
    public var taskID: UUID?
    public var title: String?
    public var notes: String?
    public var status: TaskStatus?
    public var priority: Priority?
    /// Kept as text so the same ISO / "tomorrow" parser the rest of the app uses
    /// runs at execution time, not here.
    public var due: String?
    public var tags: [String]?
    public var summary: String

    public init(id: String = UUID().uuidString, kind: Kind, taskID: UUID? = nil,
                title: String? = nil, notes: String? = nil, status: TaskStatus? = nil,
                priority: Priority? = nil, due: String? = nil, tags: [String]? = nil,
                summary: String) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.due = due
        self.tags = tags
        self.summary = summary
    }

    public var destructive: Bool { kind == .archiveTask || kind == .deleteTask }

    /// The card shown in PROPOSED OPERATIONS.
    public var action: AgentAction {
        AgentAction(id: id, tool: kind.rawValue, summary: summary,
                    destructive: destructive, applied: false)
    }

    // MARK: Factories

    public static func create(title: String, notes: String?, due: String?,
                              priority: Priority?, status: TaskStatus?,
                              tags: [String]) -> AgentOperation {
        let column = status ?? .inbox
        var line = "CREATE · \(title) → \(column.label)"
        var meta: [String] = []
        if let priority { meta.append(priority.longLabel) }
        if let due { meta.append("DUE \(AgentText.dueLabel(due))") }
        if !tags.isEmpty { meta.append(tags.map { "#\($0)" }.joined(separator: " ")) }
        if !meta.isEmpty { line += "\n" + meta.joined(separator: " · ") }
        return AgentOperation(kind: .createTask, title: title, notes: notes,
                              status: status, priority: priority, due: due,
                              tags: tags.isEmpty ? nil : tags, summary: line)
    }

    public static func update(_ task: TaskItem, title: String? = nil, notes: String? = nil,
                              priority: Priority? = nil, due: String? = nil,
                              tags: [String]? = nil) -> AgentOperation {
        var changes: [String] = []
        if let title { changes.append("TITLE=\(title)") }
        if let notes { changes.append("NOTES=\(AgentText.brief(notes, 90))") }
        if let priority { changes.append("PRIORITY=\(priority.longLabel)") }
        if let due { changes.append("DUE=\(due.isEmpty ? "CLEAR" : AgentText.dueLabel(due))") }
        if let tags { changes.append("TAGS=\(tags.joined(separator: ", "))") }
        return AgentOperation(kind: .updateTask, taskID: task.id, title: title, notes: notes,
                              priority: priority, due: due, tags: tags,
                              summary: "UPDATE · \(task.title)\n" + changes.joined(separator: ", "))
    }

    public static func move(_ task: TaskItem, to status: TaskStatus) -> AgentOperation {
        AgentOperation(kind: .moveTask, taskID: task.id, status: status,
                       summary: "MOVE · \(task.title) · \(task.status.label) → \(status.label)")
    }

    public static func complete(_ task: TaskItem) -> AgentOperation {
        AgentOperation(kind: .completeTask, taskID: task.id,
                       summary: "COMPLETE · \(task.title)")
    }

    public static func archive(_ task: TaskItem) -> AgentOperation {
        AgentOperation(kind: .archiveTask, taskID: task.id,
                       summary: "ARCHIVE · \(task.title)")
    }

    public static func delete(_ task: TaskItem) -> AgentOperation {
        AgentOperation(kind: .deleteTask, taskID: task.id,
                       summary: "DELETE · \(task.title)")
    }
}

// MARK: - Small text helpers

public enum AgentText {
    /// One-line, whitespace-collapsed rendering for labels and summaries.
    public static func brief(_ value: String, _ limit: Int = 120) -> String {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count <= limit ? text : String(text.prefix(max(1, limit - 1))) + "…"
    }

    /// "TMRW" / "19 NOV" for a proposed due date; falls back to the typed text.
    public static func dueLabel(_ raw: String) -> String {
        if let date = DateInput.parse(raw) { return DateInput.shortLabel(date) }
        return raw.uppercased()
    }

    /// Words with no retrieval value. Deliberately small: over-filtering turns
    /// "who was in the standup with Priya" into "standup priya".
    public static let stopwords: Set<String> = [
        "a", "about", "all", "an", "and", "any", "are", "as", "at", "be", "been",
        "but", "by", "can", "could", "did", "do", "does", "for", "from", "get",
        "give", "go", "had", "has", "have", "how", "i", "in", "into", "is", "it",
        "its", "just", "list", "me", "mine", "my", "of", "on", "or", "our", "out",
        "please", "show", "so", "some", "that", "the", "their", "them", "then",
        "there", "these", "they", "this", "those", "to", "up", "us", "was", "we",
        "were", "what", "whats", "when", "where", "which", "who", "why", "will",
        "with", "would", "you", "your"
    ]

    /// Distinct lowercase words worth matching, longest first.
    public static func keywords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }
            .filter { seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }
}
