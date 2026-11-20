import Foundation

/// What the conversation is currently about.
///
/// Kept separately from the transcript because the transcript is for the model and
/// the reader; this is the small, exact state used to resolve "the second one",
/// "it" and "its recording" without asking the user to repeat themselves.
public struct AgentContext: Equatable, Sendable {
    /// What "it" means right now.
    public enum Focus: String, Equatable, Sendable { case meeting, task, email }

    public struct EmailRef: Hashable, Sendable {
        public var accountID: UUID
        public var threadID: String
        public var messageID: String?

        public init(accountID: UUID, threadID: String, messageID: String? = nil) {
            self.accountID = accountID
            self.threadID = threadID
            self.messageID = messageID
        }
    }

    /// The question the assistant last asked, so a bare "the first one" answers it.
    public enum PendingQuery: Equatable, Sendable {
        case summary, transcript, recording, actionItems, participants, openMeeting
    }

    /// The task write that was waiting on a choice.
    public enum PendingTaskAction: Equatable, Sendable {
        case complete, archive, delete, move(TaskStatus)
    }

    /// The last list the user was shown, in display order.
    public private(set) var meetingIDs: [UUID] = []
    public private(set) var taskIDs: [UUID] = []
    /// The single object the last turn was about.
    public private(set) var lastMeetingID: UUID?
    public private(set) var lastTaskID: UUID?
    public private(set) var lastScheduledMeetingID: UUID?
    public private(set) var lastFocus: Focus?
    /// The last email list the user was shown, and the one the turn was about.
    public private(set) var emailRefs: [EmailRef] = []
    public private(set) var lastEmail: EmailRef?
    /// The topic of the last retrieval ("onboarding"), reused by a bare follow-up.
    public private(set) var lastTopic: String?

    public private(set) var pendingQuery: PendingQuery?
    public private(set) var pendingTaskAction: PendingTaskAction?

    public init() {}

    public mutating func clear() {
        self = AgentContext()
    }

    public mutating func record(meetings: [UUID], last: UUID? = nil, topic: String? = nil) {
        meetingIDs = meetings
        lastMeetingID = last
        if !meetings.isEmpty || last != nil { lastFocus = .meeting }
        if let topic, !topic.isEmpty { lastTopic = topic }
        pendingQuery = nil
        pendingTaskAction = nil
    }

    public mutating func record(tasks: [UUID], last: UUID? = nil) {
        taskIDs = tasks
        lastTaskID = last
        if !tasks.isEmpty || last != nil { lastFocus = .task }
        pendingQuery = nil
        pendingTaskAction = nil
    }

    /// A following turn can still resolve "it" after a single result, and "the
    /// second one" still refers to the last list the user was shown.
    public mutating func focus(meeting: UUID) {
        lastMeetingID = meeting
        if meetingIDs.isEmpty { meetingIDs = [meeting] }
        lastFocus = .meeting
        pendingQuery = nil
        pendingTaskAction = nil
    }

    public mutating func focus(task: UUID) {
        lastTaskID = task
        if taskIDs.isEmpty { taskIDs = [task] }
        lastFocus = .task
        pendingQuery = nil
        pendingTaskAction = nil
    }

    public mutating func focus(scheduledMeeting: UUID) {
        lastScheduledMeetingID = scheduledMeeting
        pendingQuery = nil
        pendingTaskAction = nil
    }

    public mutating func record(emails: [EmailRef], last: EmailRef? = nil,
                                topic: String? = nil) {
        emailRefs = emails
        lastEmail = last ?? emails.first
        if !emails.isEmpty || last != nil { lastFocus = .email }
        if let topic, !topic.isEmpty { lastTopic = topic }
        pendingQuery = nil
        pendingTaskAction = nil
    }

    public mutating func focus(email: EmailRef) {
        lastEmail = email
        if emailRefs.isEmpty { emailRefs = [email] }
        lastFocus = .email
        pendingQuery = nil
        pendingTaskAction = nil
    }

    /// Set after asking "Which meeting?" so the next bare ordinal continues the
    /// same action instead of starting from scratch.
    public mutating func awaitQuery(_ query: PendingQuery?) {
        pendingQuery = query
        if query != nil { pendingTaskAction = nil }
    }

    public mutating func awaitTask(_ action: PendingTaskAction?) {
        pendingTaskAction = action
        if action != nil { pendingQuery = nil }
    }

    public mutating func clearPending() {
        pendingQuery = nil
        pendingTaskAction = nil
    }
}
