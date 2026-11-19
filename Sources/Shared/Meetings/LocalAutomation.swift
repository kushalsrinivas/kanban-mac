import Foundation

// MARK: - Rules

/// A local automation rule. Data, not code: the editor writes these rows and the
/// runner reads them, so a rule can be changed without a new build.
public enum AutomationTrigger: String, Codable, CaseIterable, Sendable {
    case meetingCompleted = "meeting.completed"
    case commitmentOverdue = "commitment.overdue"

    public var label: String {
        switch self {
        case .meetingCompleted: return "WHEN A MEETING ENDS"
        case .commitmentOverdue: return "WHEN A COMMITMENT IS OVERDUE"
        }
    }
}

public struct AutomationConditions: Codable, Hashable, Sendable {
    /// Empty means "any meeting".
    public var titleContains: String
    public var participantContains: String
    public var minDurationMinutes: Int
    public var hasActionItems: Bool
    public var hasDecisions: Bool

    public init(titleContains: String = "", participantContains: String = "",
                minDurationMinutes: Int = 0, hasActionItems: Bool = false,
                hasDecisions: Bool = false) {
        self.titleContains = titleContains
        self.participantContains = participantContains
        self.minDurationMinutes = minDurationMinutes
        self.hasActionItems = hasActionItems
        self.hasDecisions = hasDecisions
    }

    public var isEmpty: Bool {
        titleContains.trimmingCharacters(in: .whitespaces).isEmpty
            && participantContains.trimmingCharacters(in: .whitespaces).isEmpty
            && minDurationMinutes == 0 && !hasActionItems && !hasDecisions
    }
}

public struct AutomationAction: Codable, Hashable, Sendable {
    /// Kept as a string so an unknown action written by a newer build is ignored,
    /// not decoded into the wrong case.
    public var type: String
    public var minConfidence: Double?
    public var recipients: [String]?
    public var url: String?
    public var dryRun: Bool?

    public init(type: String, minConfidence: Double? = nil, recipients: [String]? = nil,
                url: String? = nil, dryRun: Bool? = nil) {
        self.type = type
        self.minConfidence = minConfidence
        self.recipients = recipients
        self.url = url
        self.dryRun = dryRun
    }

    public static func createTasks(minConfidence: Double = 0) -> AutomationAction {
        AutomationAction(type: "tasks.create", minConfidence: minConfidence)
    }
    public static func summaryEmail(to: [String] = []) -> AutomationAction {
        AutomationAction(type: "email.summary", recipients: to)
    }
    public static func followUpEmail(to: [String] = []) -> AutomationAction {
        AutomationAction(type: "email.followup", recipients: to)
    }
    public static func notifyCommitments() -> AutomationAction {
        AutomationAction(type: "notify.commitments")
    }
    public static func remindOwners() -> AutomationAction {
        AutomationAction(type: "commitments.remind")
    }
    public static func webhook(_ url: String, dryRun: Bool = false) -> AutomationAction {
        AutomationAction(type: "webhook.post", url: url, dryRun: dryRun)
    }
    /// Sends created tasks to a project tool through its incoming webhook (Jira
    /// automation, Linear webhook relay, Notion automation, Zapier/Make/n8n). The
    /// server build has first-class Jira/Linear/Todoist/Asana adapters.
    public static func externalTasks(url: String) -> AutomationAction {
        AutomationAction(type: "tasks.external", url: url)
    }

    public var label: String {
        switch type {
        case "tasks.create": return "Create board tasks"
        case "tasks.external": return "Push tasks to an external board"
        case "email.summary": return "Draft a summary email"
        case "email.followup": return "Draft a follow-up email"
        case "notify.commitments": return "Notify commitment owners"
        case "commitments.remind": return "Remind owners once a day"
        case "webhook.post": return "Post to a webhook"
        default: return type
        }
    }
}

public struct AutomationRule: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: AutomationTrigger
    public var conditions: AutomationConditions
    public var actions: [AutomationAction]
    public var createdAt: Date
    public var lastRunAt: Date?

    public init(id: UUID = UUID(), name: String, enabled: Bool = true,
                trigger: AutomationTrigger = .meetingCompleted,
                conditions: AutomationConditions = AutomationConditions(),
                actions: [AutomationAction], createdAt: Date = Date(),
                lastRunAt: Date? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.conditions = conditions
        self.actions = actions
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }

    /// The canonical rule from the product brief: summary, action items, follow-up
    /// and tasks. One press to add, still fully editable afterwards.
    public static func standardFollowUp() -> AutomationRule {
        AutomationRule(
            name: "Meeting follow-up",
            trigger: .meetingCompleted,
            actions: [.summaryEmail(), .followUpEmail(), .createTasks(minConfidence: 0.6),
                      .notifyCommitments()])
    }
}

public struct AutomationRun: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable, Hashable {
        case completed, partial, skipped, failed
    }
    public var id: UUID
    public var ruleID: UUID?
    public var ruleName: String
    public var meetingID: UUID?
    public var status: Status
    public var detail: String
    public var startedAt: Date
    public var finishedAt: Date

    public init(id: UUID = UUID(), ruleID: UUID?, ruleName: String,
                meetingID: UUID?, status: Status, detail: String,
                startedAt: Date, finishedAt: Date = Date()) {
        self.id = id
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.meetingID = meetingID
        self.status = status
        self.detail = detail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// An email or in-app notification produced locally. `draft` is deliberate: the app
/// has no SMTP credentials, so it hands you a composed message instead of pretending
/// to send one.
public struct LocalMessage: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable { case email, notification }
    public enum Status: String, Sendable, Hashable { case draft, sent }

    public var id: UUID
    public var kind: Kind
    public var status: Status
    public var recipients: [String]
    public var subject: String
    public var body: String
    public var meetingID: UUID?
    public var commitmentID: UUID?
    public var createdAt: Date
    public var sentAt: Date?

    public init(id: UUID = UUID(), kind: Kind, status: Status = .draft,
                recipients: [String] = [], subject: String, body: String,
                meetingID: UUID? = nil, commitmentID: UUID? = nil,
                createdAt: Date = Date(), sentAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.meetingID = meetingID
        self.commitmentID = commitmentID
        self.createdAt = createdAt
        self.sentAt = sentAt
    }
}

// MARK: - Composition

public enum FollowUpComposer {
    public static func summary(meeting: Meeting) -> LocalMessage {
        LocalMessage(kind: .email, recipients: meeting.participants.filter { $0.contains("@") },
                     subject: "Meeting summary: \(meeting.title)",
                     body: body(meeting: meeting, followUp: false),
                     meetingID: meeting.id)
    }

    public static func followUp(meeting: Meeting) -> LocalMessage {
        LocalMessage(kind: .email, recipients: meeting.participants.filter { $0.contains("@") },
                     subject: "Follow-up: \(meeting.title)",
                     body: body(meeting: meeting, followUp: true),
                     meetingID: meeting.id)
    }

    public static func reminder(commitment: ActionItem, meeting: Meeting) -> LocalMessage {
        LocalMessage(kind: .notification, status: .sent,
                     recipients: commitment.assignee.map { [$0] } ?? [],
                     subject: "Reminder: \(commitment.title)",
                     body: reminderBody(commitment: commitment, meeting: meeting),
                     meetingID: meeting.id, commitmentID: commitment.id,
                     sentAt: Date())
    }

    /// The same reminder as an email draft when the owner has an address. The app
    /// has no SMTP credentials, so this is a compose-ready draft, not a fake send.
    public static func reminderEmail(commitment: ActionItem,
                                     meeting: Meeting) -> LocalMessage? {
        guard let owner = commitment.assignee, owner.contains("@") else { return nil }
        return LocalMessage(kind: .email, recipients: [owner],
                            subject: "Reminder: \(commitment.title)",
                            body: reminderBody(commitment: commitment, meeting: meeting),
                            meetingID: meeting.id, commitmentID: commitment.id)
    }

    private static func reminderBody(commitment: ActionItem, meeting: Meeting) -> String {
        var lines = ["You committed to: \(commitment.title)",
                     "Meeting: \(meeting.title) (\(DateInput.shortLabel(meeting.startedAt)))",
                     "Due: \(commitment.dueDate.map { DateInput.shortLabel($0) } ?? "no date agreed")"]
        if let quote = commitment.quote {
            lines.append("Spoken: \"\(quote)\"")
        }
        if let start = commitment.sourceStart {
            lines.append("In the recording at \(Meeting.timecode(start))")
        }
        lines.append("")
        lines.append("Sent by the local Work Console.")
        return lines.joined(separator: "\n")
    }

    public static func body(meeting: Meeting, followUp: Bool) -> String {
        var lines: [String] = []
        let when = DateInput.shortLabel(meeting.startedAt)
        lines.append(followUp
            ? "Thanks all — a short follow-up from \"\(meeting.title)\" on \(when)."
            : "Summary of \"\(meeting.title)\" on \(when).")
        lines.append("")
        lines.append(meeting.summary.isEmpty ? "No summary was generated." : meeting.summary)
        lines.append("")
        if !meeting.keyPoints.isEmpty {
            lines.append("Key points")
            lines.append(contentsOf: meeting.keyPoints.map { "- \($0)" })
            lines.append("")
        }
        if !meeting.decisions.isEmpty {
            lines.append("Decisions")
            lines.append(contentsOf: meeting.decisions.map { "- \($0)" })
            lines.append("")
        }
        let open = meeting.actionItems.filter { $0.state != .dismissed && $0.isOpen }
        if !open.isEmpty {
            lines.append("Action items")
            for item in open {
                var line = "- \(item.title)"
                if let owner = item.assignee, !owner.isEmpty { line += " (\(owner))" }
                if let due = item.dueDate { line += " — due \(DateInput.shortLabel(due))" }
                lines.append(line)
            }
            lines.append("")
        }
        lines.append("— Work Console")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Evaluation

public enum AutomationPlanner {
    public static func matches(_ rule: AutomationRule, meeting: Meeting) -> Bool {
        guard rule.enabled, rule.trigger == .meetingCompleted else { return false }
        let c = rule.conditions
        let title = c.titleContains.trimmingCharacters(in: .whitespaces).lowercased()
        if !title.isEmpty, !meeting.title.lowercased().contains(title) { return false }
        let participant = c.participantContains.trimmingCharacters(in: .whitespaces).lowercased()
        if !participant.isEmpty,
           !meeting.participants.contains(where: { $0.lowercased().contains(participant) }) {
            return false
        }
        if c.minDurationMinutes > 0, meeting.duration < Double(c.minDurationMinutes) * 60 {
            return false
        }
        if c.hasActionItems, meeting.actionItems.isEmpty { return false }
        if c.hasDecisions, meeting.decisions.isEmpty { return false }
        return true
    }

    /// Actions that can run without a user decision. External side effects are
    /// executed by the app; this is the plan the runner walks.
    public static func plan(_ rule: AutomationRule, meeting: Meeting) -> [AutomationAction] {
        rule.actions.filter { action in
            switch action.type {
            case "tasks.create", "tasks.external":
                return meeting.actionItems.contains {
                    $0.isOpen && $0.state != .dismissed
                        && $0.confidence >= (action.minConfidence ?? 0)
                }
            default:
                return true
            }
        }
    }
}
