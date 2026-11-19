import Foundation

// MARK: - Processing state

/// Lifecycle of a recording, from the microphone to finished notes.
///
/// `local` and `readyToProcess` are Mac-side states; everything from `uploading`
/// onwards mirrors the VPS job state so the UI can render one continuous progress
/// list without knowing where the work is happening.
public enum MeetingStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case recording
    case readyToProcess = "ready_to_process"
    case queued
    case uploading
    case transcribing
    case analyzing
    case completed
    case failed
    /// The user chose SAVE LOCALLY; nothing has been or will be uploaded.
    case localOnly = "local_only"

    public var label: String {
        switch self {
        case .recording: return "RECORDING"
        case .readyToProcess: return "READY"
        case .queued: return "QUEUED"
        case .uploading: return "UPLOADING"
        case .transcribing: return "TRANSCRIBING"
        case .analyzing: return "ANALYZING"
        case .completed: return "COMPLETED"
        case .failed: return "FAILED"
        case .localOnly: return "LOCAL"
        }
    }

    public var isProcessing: Bool {
        switch self {
        case .queued, .uploading, .transcribing, .analyzing: return true
        default: return false
        }
    }

    public var isTerminal: Bool { self == .completed || self == .failed }

    /// Ordered steps shown on the processing screen.
    public static let pipeline: [MeetingStatus] = [.uploading, .transcribing, .analyzing, .completed]
}

// MARK: - Suggested action items

/// An action item the VPS extracted. It is a *suggestion* until the user accepts it —
/// nothing here ever becomes a task on its own.
public struct ActionItem: Identifiable, Hashable, Codable, Sendable {
    public enum State: String, Codable, Sendable, Hashable {
        case suggested
        case added
        case dismissed
    }

    /// Execution state, separate from the review decision. Dismissing the suggestion
    /// and completing the promise are different acts and must not overwrite each other.
    public enum Commitment: String, Codable, Sendable, Hashable {
        case open
        case done
        case cancelled
    }

    public var id: UUID
    public var meetingID: UUID
    public var title: String
    public var assignee: String?
    public var dueDate: Date?
    /// 0...1 from the extraction model. Shown, never used to auto-accept.
    public var confidence: Double
    public var state: State
    /// Set once the user accepts it, linking the suggestion to the real task.
    public var taskID: UUID?
    public var position: Double

    /// The sentence that made the commitment, so it can be checked against the
    /// recording rather than trusted as a paraphrase.
    public var quote: String?
    public var sourceStart: TimeInterval?
    public var sourceEnd: TimeInterval?
    public var commitmentState: Commitment
    public var completedAt: Date?
    public var remindedAt: Date?

    public init(id: UUID = UUID(), meetingID: UUID, title: String, assignee: String? = nil,
                dueDate: Date? = nil, confidence: Double = 0, state: State = .suggested,
                taskID: UUID? = nil, position: Double = 0, quote: String? = nil,
                sourceStart: TimeInterval? = nil, sourceEnd: TimeInterval? = nil,
                commitmentState: Commitment = .open, completedAt: Date? = nil,
                remindedAt: Date? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.title = title
        self.assignee = assignee
        self.dueDate = dueDate
        self.confidence = confidence
        self.state = state
        self.taskID = taskID
        self.position = position
        self.quote = quote
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.commitmentState = commitmentState
        self.completedAt = completedAt
        self.remindedAt = remindedAt
    }

    public var isSuggested: Bool { state == .suggested }
    public var isOpen: Bool { commitmentState == .open }

    /// Overdue means the agreed time has passed. Unlike a task, a commitment made
    /// for 5pm is late at 5:01, not at midnight.
    public func isOverdue(now: Date = Date()) -> Bool {
        guard commitmentState == .open, let dueDate else { return false }
        return dueDate < now
    }

    /// True when a reminder is due and one has not been sent in the last day.
    public func needsReminder(now: Date = Date()) -> Bool {
        guard isOverdue(now: now) else { return false }
        guard let remindedAt else { return true }
        return now.timeIntervalSince(remindedAt) >= 24 * 3600
    }
}

// MARK: - Transcript

public struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String?
    public var text: String

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval,
                speaker: String? = nil, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }

    /// "00:03" / "1:02:14" — the timestamp gutter in the transcript view.
    public var timecode: String { Meeting.timecode(start) }
}

// MARK: - Meeting

public struct Meeting: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Server-side id once uploaded. Nil while the meeting exists only on this Mac.
    public var remoteID: String?
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var status: MeetingStatus

    // Local transport state
    /// Path of the temporary recording, relative to the recordings directory.
    /// Cleared once uploaded, unless the user keeps originals.
    public var audioFilename: String?
    public var uploadedAt: Date?
    public var processedAt: Date?
    public var failureReason: String?
    /// Server job id, used to resume progress after a relaunch.
    public var jobID: String?

    // Results from the VPS
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var questions: [String]
    public var topics: [String]
    public var participants: [String]
    public var actionItems: [ActionItem]
    public var transcript: [TranscriptSegment]

    public init(
        id: UUID = UUID(),
        remoteID: String? = nil,
        title: String,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        status: MeetingStatus = .recording,
        audioFilename: String? = nil,
        uploadedAt: Date? = nil,
        processedAt: Date? = nil,
        failureReason: String? = nil,
        jobID: String? = nil,
        summary: String = "",
        keyPoints: [String] = [],
        decisions: [String] = [],
        questions: [String] = [],
        topics: [String] = [],
        participants: [String] = [],
        actionItems: [ActionItem] = [],
        transcript: [TranscriptSegment] = []
    ) {
        self.id = id
        self.remoteID = remoteID
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.status = status
        self.audioFilename = audioFilename
        self.uploadedAt = uploadedAt
        self.processedAt = processedAt
        self.failureReason = failureReason
        self.jobID = jobID
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.questions = questions
        self.topics = topics
        self.participants = participants
        self.actionItems = actionItems
        self.transcript = transcript
    }

    // MARK: Derived

    public var suggestedCount: Int { actionItems.filter(\.isSuggested).count }
    public var addedCount: Int { actionItems.filter { $0.state == .added }.count }
    public var hasResults: Bool { !summary.isEmpty || !actionItems.isEmpty || !transcript.isEmpty }

    /// True when the recording still exists on disk and has not been uploaded.
    public var awaitsUpload: Bool {
        audioFilename != nil && (status == .readyToProcess || status == .failed)
    }

    public var durationLabel: String { Meeting.durationLabel(duration) }

    public func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: q, options: opts) != nil { return true }
        if summary.range(of: q, options: opts) != nil { return true }
        for segment in transcript where segment.text.range(of: q, options: opts) != nil { return true }
        return false
    }

    // MARK: Formatting

    /// "42 MIN" / "1H 07M" — the compact duration used in lists.
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) SEC" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) MIN" }
        return "\(minutes / 60)H \(String(format: "%02d", minutes % 60))M"
    }

    /// "24:18" / "1:04:32" — the running clock and transcript gutter.
    public static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Default title for a new recording: "MEETING · 18 SEP 14:30".
    public static func defaultTitle(at date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "d MMM HH:mm"
        return "Meeting \(df.string(from: date))"
    }
}

// MARK: - Grouping for the meetings list

public extension Array where Element == Meeting {
    /// Newest first, which is how the list always reads.
    func chronological() -> [Meeting] {
        sorted { $0.startedAt > $1.startedAt }
    }

    /// TODAY / THIS WEEK / EARLIER, matching the meetings screen.
    func grouped(now: Date = Date(), calendar: Calendar = .current) -> [(String, [Meeting])] {
        var today: [Meeting] = [], week: [Meeting] = [], earlier: [Meeting] = []
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        for meeting in chronological() {
            if calendar.isDate(meeting.startedAt, inSameDayAs: now) { today.append(meeting) }
            else if meeting.startedAt >= startOfWeek { week.append(meeting) }
            else { earlier.append(meeting) }
        }
        var out: [(String, [Meeting])] = []
        if !today.isEmpty { out.append(("TODAY", today)) }
        if !week.isEmpty { out.append(("THIS WEEK", week)) }
        if !earlier.isEmpty { out.append(("EARLIER", earlier)) }
        return out
    }
}
