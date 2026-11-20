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
        case createEmailDraft = "create_email_draft"
        case labelEmail = "label_email"
        case archiveEmail = "archive_email"
        case trashEmail = "trash_email"
        case markEmailRead = "mark_email_read"
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
    /// Mail writes carry their own target and payload. Sending is deliberately not
    /// a kind: the agent can draft, never send.
    public var emailAccountID: UUID?
    public var emailThreadIDs: [String]?
    public var emailLabels: [String]?
    public var emailRead: Bool?
    public var emailAddLabel: Bool?
    public var emailDraft: GmailDraft?

    public init(id: String = UUID().uuidString, kind: Kind, taskID: UUID? = nil,
                title: String? = nil, notes: String? = nil, status: TaskStatus? = nil,
                priority: Priority? = nil, due: String? = nil, tags: [String]? = nil,
                summary: String, emailAccountID: UUID? = nil,
                emailThreadIDs: [String]? = nil, emailLabels: [String]? = nil,
                emailRead: Bool? = nil, emailAddLabel: Bool? = nil,
                emailDraft: GmailDraft? = nil) {
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
        self.emailAccountID = emailAccountID
        self.emailThreadIDs = emailThreadIDs
        self.emailLabels = emailLabels
        self.emailRead = emailRead
        self.emailAddLabel = emailAddLabel
        self.emailDraft = emailDraft
    }

    public var destructive: Bool {
        kind == .archiveTask || kind == .deleteTask || kind == .trashEmail
    }

    /// Board writes that can be applied immediately without a second confirmation.
    /// Archive and delete stay proposals; mail writes stay proposals.
    public var isSafeLocalWrite: Bool {
        switch kind {
        case .createTask, .updateTask, .moveTask, .completeTask:
            return true
        default:
            return false
        }
    }

    public var isEmailOperation: Bool {
        switch kind {
        case .createEmailDraft, .labelEmail, .archiveEmail, .trashEmail, .markEmailRead:
            return true
        default:
            return false
        }
    }

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

    // MARK: Mail factories

    public static func createDraft(_ draft: GmailDraft, accountEmail: String) -> AgentOperation {
        let recipients = draft.to.map(\.displayName).joined(separator: ", ")
        var summary = "DRAFT EMAIL · \(draft.subject.isEmpty ? "(no subject)" : draft.subject)"
        summary += "\nFROM \(accountEmail)"
        if !recipients.isEmpty { summary += " · TO \(recipients)" }
        if !draft.bodyText.isEmpty { summary += "\n" + AgentText.brief(draft.bodyText, 120) }
        return AgentOperation(kind: .createEmailDraft, summary: summary,
                              emailAccountID: draft.accountID, emailDraft: draft)
    }

    public static func emailLabels(_ threads: [GmailThreadSummary], labels: [String],
                                   add: Bool, accountEmail: String) -> AgentOperation? {
        guard let first = threads.first else { return nil }
        let verb = add ? "LABEL" : "UNLABEL"
        let names = labels.joined(separator: ", ")
        var summary = "\(verb) EMAIL · \(names)"
        summary += "\n\(threads.count) conversation\(threads.count == 1 ? "" : "s") · \(accountEmail)"
        if let subject = threads.first?.displaySubject {
            summary += "\n\(subject)"
            if threads.count > 1 { summary += " +\(threads.count - 1) more" }
        }
        return AgentOperation(kind: .labelEmail, summary: summary,
                              emailAccountID: first.accountID,
                              emailThreadIDs: threads.map(\.id),
                              emailLabels: labels, emailAddLabel: add)
    }

    public static func archiveEmail(_ threads: [GmailThreadSummary],
                                    accountEmail: String) -> AgentOperation? {
        guard let first = threads.first else { return nil }
        var summary = "ARCHIVE EMAIL · \(threads.count) conversation\(threads.count == 1 ? "" : "s")"
        summary += "\n\(first.displaySubject)"
        summary += "\n\(accountEmail)"
        return AgentOperation(kind: .archiveEmail, summary: summary,
                              emailAccountID: first.accountID,
                              emailThreadIDs: threads.map(\.id))
    }

    public static func trashEmail(_ threads: [GmailThreadSummary],
                                  accountEmail: String) -> AgentOperation? {
        guard let first = threads.first else { return nil }
        var summary = "TRASH EMAIL · \(threads.count) conversation\(threads.count == 1 ? "" : "s")"
        summary += "\n\(first.displaySubject)"
        summary += "\n\(accountEmail)"
        return AgentOperation(kind: .trashEmail, summary: summary,
                              emailAccountID: first.accountID,
                              emailThreadIDs: threads.map(\.id))
    }

    public static func markEmailRead(_ threads: [GmailThreadSummary], read: Bool,
                                     accountEmail: String) -> AgentOperation? {
        guard let first = threads.first else { return nil }
        let summary = "MARK \(read ? "READ" : "UNREAD") · \(threads.count) conversation\(threads.count == 1 ? "" : "s")\n\(accountEmail)"
        return AgentOperation(kind: .markEmailRead, summary: summary,
                              emailAccountID: first.accountID,
                              emailThreadIDs: threads.map(\.id), emailRead: read)
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
