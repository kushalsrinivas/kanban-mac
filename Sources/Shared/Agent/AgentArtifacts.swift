import Foundation

// MARK: - Artifact kind

/// The closed set of things the agent can put in front of the user.
///
/// A new type is added in three places and nowhere else: one payload case, one
/// builder, one renderer registered in `AgentArtifactRegistry`. The transcript
/// view iterates artifacts and asks the registry for a view, so it never grows a
/// switch of its own.
public enum AgentArtifactKind: String, CaseIterable, Sendable, Hashable {
    case taskList
    case meetingList
    case meetingSummary
    case recording
    case transcript
    case actionItems
    case participants
    case scheduledMeetingList
    case scheduledMeeting
    case scheduledBrief
    case emailList
    case emailThread
    case emailCommitments
    case emailDraft

    public var label: String {
        switch self {
        case .taskList: return "TASKS"
        case .meetingList: return "MEETINGS"
        case .meetingSummary: return "SUMMARY"
        case .recording: return "RECORDING"
        case .transcript: return "TRANSCRIPT"
        case .actionItems: return "ACTION ITEMS"
        case .participants: return "PARTICIPANTS"
        case .scheduledMeetingList: return "SCHEDULE"
        case .scheduledMeeting: return "SCHEDULED"
        case .scheduledBrief: return "BRIEF"
        case .emailList: return "EMAIL"
        case .emailThread: return "CONVERSATION"
        case .emailCommitments: return "COMMITMENTS"
        case .emailDraft: return "DRAFT"
        }
    }
}

// MARK: - Payloads

public struct TaskListArtifact: Equatable, Sendable {
    public var title: String
    public var tasks: [TaskItem]
    public var note: String?
    public var emptyMessage: String

    public init(title: String, tasks: [TaskItem], note: String? = nil,
                emptyMessage: String = "No tasks match.") {
        self.title = title
        self.tasks = tasks
        self.note = note
        self.emptyMessage = emptyMessage
    }
}

public struct MeetingListArtifact: Equatable, Sendable {
    public var title: String
    public var meetings: [Meeting]
    public var note: String?
    public var emptyMessage: String

    public init(title: String, meetings: [Meeting], note: String? = nil,
                emptyMessage: String = "No meetings match.") {
        self.title = title
        self.meetings = meetings
        self.note = note
        self.emptyMessage = emptyMessage
    }
}

public struct MeetingSummaryArtifact: Equatable, Sendable {
    public var meeting: Meeting
    /// Real transcript segments with timecodes, not generated prose.
    public var highlights: [TranscriptSegment]
    public var relatedTasks: [TaskItem]
    public var note: String?

    public init(meeting: Meeting, highlights: [TranscriptSegment] = [],
                relatedTasks: [TaskItem] = [], note: String? = nil) {
        self.meeting = meeting
        self.highlights = highlights
        self.relatedTasks = relatedTasks
        self.note = note
    }
}

public struct RecordingArtifact: Equatable, Sendable {
    public var meeting: Meeting
    /// A local file exists at this path, so playback works with no network.
    public var localAudio: URL?
    /// The server has the audio object and a backend is configured.
    public var remoteAvailable: Bool
    public var unavailableReason: String?

    public var isPlayable: Bool { localAudio != nil || remoteAvailable }

    public init(meeting: Meeting, localAudio: URL?, remoteAvailable: Bool,
                unavailableReason: String? = nil) {
        self.meeting = meeting
        self.localAudio = localAudio
        self.remoteAvailable = remoteAvailable
        self.unavailableReason = unavailableReason
    }
}

public struct TranscriptArtifact: Equatable, Sendable {
    public var meeting: Meeting
    public var segments: [TranscriptSegment]
    public var totalCount: Int
    public var query: String?
    public var note: String?

    public init(meeting: Meeting, segments: [TranscriptSegment], totalCount: Int,
                query: String? = nil, note: String? = nil) {
        self.meeting = meeting
        self.segments = segments
        self.totalCount = totalCount
        self.query = query
        self.note = note
    }

    public var isFiltered: Bool { !(query ?? "").isEmpty }
}

/// An action item joined to its meeting and, when it was accepted, the real task.
public struct ActionItemCard: Identifiable, Equatable, Sendable {
    public var item: ActionItem
    public var meetingTitle: String
    public var meetingID: UUID
    public var linkedTask: TaskItem?

    public var id: UUID { item.id }

    public init(item: ActionItem, meetingTitle: String, meetingID: UUID,
                linkedTask: TaskItem?) {
        self.item = item
        self.meetingTitle = meetingTitle
        self.meetingID = meetingID
        self.linkedTask = linkedTask
    }
}

public struct ActionItemsArtifact: Equatable, Sendable {
    /// Nil when the list spans several meetings.
    public var meeting: Meeting?
    public var cards: [ActionItemCard]
    public var note: String?
    public var emptyMessage: String

    public init(meeting: Meeting?, cards: [ActionItemCard], note: String? = nil,
                emptyMessage: String = "No action items.") {
        self.meeting = meeting
        self.cards = cards
        self.note = note
        self.emptyMessage = emptyMessage
    }

    public var suggestedCount: Int { cards.filter { $0.item.isSuggested }.count }
    public var addedCount: Int { cards.filter { $0.item.state == .added }.count }
}

/// One participant, with the action items the meeting attributed to them.
public struct ParticipantCard: Identifiable, Equatable, Sendable {
    public var name: String
    public var assignedItems: [ActionItem]
    public var linkedTasks: [TaskItem]

    public var id: String { name.lowercased() }

    public init(name: String, assignedItems: [ActionItem] = [],
                linkedTasks: [TaskItem] = []) {
        self.name = name
        self.assignedItems = assignedItems
        self.linkedTasks = linkedTasks
    }

    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.isEmpty ? String(name.prefix(2)).uppercased() : letters.joined().uppercased()
    }
}

public struct ParticipantsArtifact: Equatable, Sendable {
    public var meeting: Meeting
    public var participants: [ParticipantCard]
    public var note: String?
    public var emptyMessage: String

    public init(meeting: Meeting, participants: [ParticipantCard], note: String? = nil,
                emptyMessage: String = "No participants were identified.") {
        self.meeting = meeting
        self.participants = participants
        self.note = note
        self.emptyMessage = emptyMessage
    }
}

public struct ScheduledMeetingListArtifact: Equatable, Sendable {
    public var title: String
    public var meetings: [ScheduledMeeting]
    public var note: String?
    public var emptyMessage: String

    public init(title: String, meetings: [ScheduledMeeting], note: String? = nil,
                emptyMessage: String = "No scheduled meetings.") {
        self.title = title
        self.meetings = meetings
        self.note = note
        self.emptyMessage = emptyMessage
    }
}

public struct ScheduledMeetingArtifact: Equatable, Sendable {
    public var meeting: ScheduledMeeting
    public var note: String?

    public init(meeting: ScheduledMeeting, note: String? = nil) {
        self.meeting = meeting
        self.note = note
    }
}

public struct ScheduledBriefArtifact: Equatable, Sendable {
    public var brief: ScheduledMeetingBrief
    public var note: String?

    public init(brief: ScheduledMeetingBrief, note: String? = nil) {
        self.brief = brief
        self.note = note
    }
}

// MARK: - Mail

/// One conversation row in an agent answer. `reason` explains why a mail was
/// surfaced; it is nil for a plain search result.
public struct EmailThreadCard: Identifiable, Equatable, Sendable {
    public var accountID: UUID
    public var accountEmail: String
    public var thread: GmailThreadSummary
    public var reason: String?

    public var id: String { "\(accountID.uuidString)|\(thread.id)" }

    public init(accountID: UUID, accountEmail: String,
                thread: GmailThreadSummary, reason: String? = nil) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.thread = thread
        self.reason = reason
    }
}

public struct EmailListArtifact: Equatable, Sendable {
    public var title: String
    public var cards: [EmailThreadCard]
    public var note: String?
    public var emptyMessage: String

    public init(title: String, cards: [EmailThreadCard], note: String? = nil,
                emptyMessage: String = "No emails match.") {
        self.title = title
        self.cards = cards
        self.note = note
        self.emptyMessage = emptyMessage
    }
}

public struct EmailThreadArtifact: Equatable, Sendable {
    public var accountID: UUID
    public var accountEmail: String
    public var thread: GmailThread
    public var insight: String?
    public var commitments: [GmailEmailCommitment]
    public var note: String?

    public init(accountID: UUID, accountEmail: String, thread: GmailThread,
                insight: String? = nil, commitments: [GmailEmailCommitment] = [],
                note: String? = nil) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.thread = thread
        self.insight = insight
        self.commitments = commitments
        self.note = note
    }
}

public struct EmailCommitmentsArtifact: Equatable, Sendable {
    public var title: String
    public var commitments: [GmailEmailCommitment]
    public var note: String?
    public var emptyMessage: String

    public init(title: String, commitments: [GmailEmailCommitment],
                note: String? = nil,
                emptyMessage: String = "No commitments found in email.") {
        self.title = title
        self.commitments = commitments
        self.note = note
        self.emptyMessage = emptyMessage
    }
}

public struct EmailDraftArtifact: Equatable, Sendable {
    public var accountEmail: String
    public var draft: GmailDraft
    public var note: String?

    public init(accountEmail: String, draft: GmailDraft, note: String? = nil) {
        self.accountEmail = accountEmail
        self.draft = draft
        self.note = note
    }
}

// MARK: - Artifact

public struct AgentArtifact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let payload: Payload

    public init(_ payload: Payload) {
        self.id = UUID()
        self.payload = payload
    }

    public enum Payload: Equatable, Sendable {
        case taskList(TaskListArtifact)
        case meetingList(MeetingListArtifact)
        case meetingSummary(MeetingSummaryArtifact)
        case recording(RecordingArtifact)
        case transcript(TranscriptArtifact)
        case actionItems(ActionItemsArtifact)
        case participants(ParticipantsArtifact)
        case scheduledMeetingList(ScheduledMeetingListArtifact)
        case scheduledMeeting(ScheduledMeetingArtifact)
        case scheduledBrief(ScheduledBriefArtifact)
        case emailList(EmailListArtifact)
        case emailThread(EmailThreadArtifact)
        case emailCommitments(EmailCommitmentsArtifact)
        case emailDraft(EmailDraftArtifact)

        public var kind: AgentArtifactKind {
            switch self {
            case .taskList: return .taskList
            case .meetingList: return .meetingList
            case .meetingSummary: return .meetingSummary
            case .recording: return .recording
            case .transcript: return .transcript
            case .actionItems: return .actionItems
            case .participants: return .participants
            case .scheduledMeetingList: return .scheduledMeetingList
            case .scheduledMeeting: return .scheduledMeeting
            case .scheduledBrief: return .scheduledBrief
            case .emailList: return .emailList
            case .emailThread: return .emailThread
            case .emailCommitments: return .emailCommitments
            case .emailDraft: return .emailDraft
            }
        }

        public var title: String {
            switch self {
            case .taskList(let list): return list.title
            case .meetingList(let list): return list.title
            case .meetingSummary(let summary): return summary.meeting.title
            case .recording(let recording): return recording.meeting.title
            case .transcript(let transcript): return transcript.meeting.title
            case .actionItems(let items): return items.meeting?.title ?? "All meetings"
            case .participants(let participants): return participants.meeting.title
            case .scheduledMeetingList(let list): return list.title
            case .scheduledMeeting(let meeting): return meeting.meeting.title
            case .scheduledBrief(let brief): return brief.brief.scheduled.title
            case .emailList(let list): return list.title
            case .emailThread(let thread): return thread.thread.summary.displaySubject
            case .emailCommitments(let items): return items.title
            case .emailDraft(let draft): return draft.draft.subject.isEmpty
                ? "New email" : draft.draft.subject
            }
        }
    }

    public var kind: AgentArtifactKind { payload.kind }
    public var title: String { payload.title }

    /// The meeting this artifact is about, when it is about one.
    public var meeting: Meeting? {
        switch payload {
        case .meetingList: return nil
        case .taskList: return nil
        case .meetingSummary(let s): return s.meeting
        case .recording(let r): return r.meeting
        case .transcript(let t): return t.meeting
        case .actionItems(let a): return a.meeting
        case .participants(let p): return p.meeting
        case .scheduledMeetingList: return nil
        case .scheduledMeeting: return nil
        case .scheduledBrief: return nil
        case .emailList: return nil
        case .emailThread: return nil
        case .emailCommitments: return nil
        case .emailDraft: return nil
        }
    }

    /// The scheduled meeting this artifact is about, when it is about one.
    public var scheduledMeeting: ScheduledMeeting? {
        switch payload {
        case .scheduledMeeting(let value): return value.meeting
        case .scheduledBrief(let value): return value.brief.scheduled
        case .scheduledMeetingList: return nil
        default: return nil
        }
    }
}

// MARK: - Builders

/// Pure construction from stored rows. Nothing here invents a value: every field
/// comes from the task, meeting or transcript the store returned.
public enum AgentArtifactBuilder {

    public static func recording(_ meeting: Meeting, remotePlayback: Bool) -> AgentArtifact {
        var local: URL?
        if let filename = meeting.audioFilename, !filename.isEmpty {
            let url = KanbanPaths.recordingURL(filename: filename)
            if FileManager.default.fileExists(atPath: url.path) { local = url }
        }
        let remote = remotePlayback && meeting.remoteID != nil
        let reason: String? = (local != nil || remote) ? nil
            : (meeting.audioFilename == nil
                ? "The audio was removed after processing."
                : "The recording file is no longer on this Mac.")
        return AgentArtifact(.recording(RecordingArtifact(
            meeting: meeting, localAudio: local, remoteAvailable: remote,
            unavailableReason: reason)))
    }

    public static func summary(_ meeting: Meeting, transcript: [TranscriptSegment],
                               relatedTasks: [TaskItem]) -> AgentArtifact {
        var seen = Set<UUID>()
        var highlights: [TranscriptSegment] = []
        for segment in transcript.prefix(3) + transcript.suffix(2) where !seen.contains(segment.id) {
            seen.insert(segment.id)
            highlights.append(segment)
        }
        return AgentArtifact(.meetingSummary(MeetingSummaryArtifact(
            meeting: meeting,
            highlights: highlights,
            relatedTasks: relatedTasks.sorted { $0.createdAt > $1.createdAt })))
    }

    public static func actionItems(meeting: Meeting?,
                                   items: [(item: ActionItem, meeting: Meeting)],
                                   tasks: [TaskItem]) -> AgentArtifact {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let byAction = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            task.actionItemID.map { ($0, task) }
        })
        let cards = items.map { pair in
            let linked = pair.item.taskID.flatMap { byID[$0] }
                ?? byAction[pair.item.id]
            return ActionItemCard(item: pair.item,
                                  meetingTitle: pair.meeting.title,
                                  meetingID: pair.meeting.id,
                                  linkedTask: linked)
        }
        return AgentArtifact(.actionItems(ActionItemsArtifact(
            meeting: meeting, cards: cards,
            emptyMessage: meeting == nil
                ? "No action items across recent meetings."
                : "This meeting has no extracted action items.")))
    }

    public static func scheduledList(_ meetings: [ScheduledMeeting], title: String,
                                     note: String? = nil) -> AgentArtifact {
        AgentArtifact(.scheduledMeetingList(ScheduledMeetingListArtifact(
            title: title, meetings: meetings, note: note)))
    }

    public static func scheduledMeeting(_ meeting: ScheduledMeeting) -> AgentArtifact {
        AgentArtifact(.scheduledMeeting(ScheduledMeetingArtifact(meeting: meeting)))
    }

    public static func scheduledBrief(_ brief: ScheduledMeetingBrief) -> AgentArtifact {
        AgentArtifact(.scheduledBrief(ScheduledBriefArtifact(brief: brief)))
    }

    public static func participants(_ meeting: Meeting, items: [ActionItem],
                                    tasks: [TaskItem]) -> AgentArtifact {
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let cards = meeting.participants.map { name in
            let assigned = items.filter {
                ($0.assignee ?? "").localizedCaseInsensitiveContains(name)
            }
            let linked = assigned.compactMap { $0.taskID.flatMap { tasksByID[$0] } }
            return ParticipantCard(name: name, assignedItems: assigned, linkedTasks: linked)
        }
        return AgentArtifact(.participants(ParticipantsArtifact(
            meeting: meeting, participants: cards)))
    }

    // MARK: Mail

    public static func emails(_ threads: [GmailThreadSummary], accounts: [UUID: GmailAccount],
                              title: String, reasons: [String: String]? = nil,
                              note: String? = nil) -> AgentArtifact {
        let cards = threads.compactMap { thread -> EmailThreadCard? in
            guard let account = accounts[thread.accountID] else { return nil }
            return EmailThreadCard(accountID: thread.accountID, accountEmail: account.email,
                                   thread: thread, reason: reasons?[thread.id])
        }
        return AgentArtifact(.emailList(EmailListArtifact(
            title: title, cards: cards, note: note,
            emptyMessage: "No emails match. Connect Gmail in Settings or try another search.")))
    }

    public static func emailThread(_ thread: GmailThread, account: GmailAccount,
                                   insight: String? = nil,
                                   commitments: [GmailEmailCommitment] = [],
                                   note: String? = nil) -> AgentArtifact {
        AgentArtifact(.emailThread(EmailThreadArtifact(
            accountID: account.id, accountEmail: account.email, thread: thread,
            insight: insight, commitments: commitments, note: note)))
    }

    public static func emailCommitments(_ items: [GmailEmailCommitment],
                                        title: String, note: String? = nil) -> AgentArtifact {
        AgentArtifact(.emailCommitments(EmailCommitmentsArtifact(
            title: title, commitments: items, note: note)))
    }

    public static func emailDraft(_ draft: GmailDraft, accountEmail: String,
                                  note: String? = nil) -> AgentArtifact {
        AgentArtifact(.emailDraft(EmailDraftArtifact(
            accountEmail: accountEmail, draft: draft, note: note)))
    }
}
