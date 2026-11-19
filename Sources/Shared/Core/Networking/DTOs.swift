import CryptoKit
import Foundation

// MARK: - Tasks

/// Task as it crosses the wire. Dates are ISO-8601 so no client has to think about epochs.
public struct TaskDTO: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var notes: String
    public var status: String
    public var priority: String
    public var due: String?
    public var tags: [String]
    public var subtasks: [SubtaskDTO]
    public var position: Double
    public var created: String
    public var updated: String
    public var completed: String?
    public var archived: String?
    public var source: String
    public var meetingId: String?
    public var actionItemId: String?
    public var overdue: Bool
    public var dueToday: Bool

    public init(_ t: TaskItem, now: Date = Date()) {
        id = t.id.uuidString
        title = t.title
        notes = t.notes
        status = t.status.rawValue
        priority = t.priority.longLabel.lowercased()
        due = t.dueDate.map(DateInput.iso)
        tags = t.tags
        subtasks = t.subtasks.map(SubtaskDTO.init)
        position = t.position
        created = DateInput.iso(t.createdAt)
        updated = DateInput.iso(t.updatedAt)
        completed = t.completedAt.map(DateInput.iso)
        archived = t.archivedAt.map(DateInput.iso)
        source = t.source.rawValue
        meetingId = t.meetingID?.uuidString
        actionItemId = t.actionItemID?.uuidString
        overdue = t.isOverdue(now: now)
        dueToday = t.isDueToday(now: now)
    }

    /// Server -> local model. Unknown enum values fall back rather than dropping the row.
    public func toTask() -> TaskItem? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return TaskItem(
            id: uuid,
            title: title,
            notes: notes,
            status: TaskStatus.parse(status) ?? .inbox,
            priority: Priority.parse(priority) ?? .medium,
            dueDate: due.flatMap { DateInput.parse($0) },
            tags: tags,
            subtasks: subtasks.compactMap { $0.toSubtask() },
            position: position,
            createdAt: DateInput.parse(created) ?? Date(),
            updatedAt: DateInput.parse(updated) ?? Date(),
            completedAt: completed.flatMap { DateInput.parse($0) },
            archivedAt: archived.flatMap { DateInput.parse($0) },
            source: TaskSource(rawValue: source) ?? .manual,
            meetingID: meetingId.flatMap(UUID.init(uuidString:)),
            actionItemID: actionItemId.flatMap(UUID.init(uuidString:))
        )
    }
}

public struct SubtaskDTO: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var done: Bool

    public init(_ s: Subtask) {
        id = s.id.uuidString
        title = s.title
        done = s.isDone
    }

    public func toSubtask(position: Double = 0) -> Subtask? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Subtask(id: uuid, title: title, isDone: done, position: position)
    }
}

public struct CreateTaskBody: Codable, Sendable {
    public var id: String?
    public var title: String
    public var notes: String?
    public var status: String?
    public var priority: String?
    public var due: String?
    public var tags: [String]?
    public var subtasks: [String]?
    public var position: Double?
    public var source: String?
    public var meetingId: String?
    public var actionItemId: String?

    public init(id: String? = nil, title: String, notes: String? = nil, status: String? = nil,
                priority: String? = nil, due: String? = nil, tags: [String]? = nil,
                subtasks: [String]? = nil, position: Double? = nil, source: String? = nil,
                meetingId: String? = nil, actionItemId: String? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.due = due
        self.tags = tags
        self.subtasks = subtasks
        self.position = position
        self.source = source
        self.meetingId = meetingId
        self.actionItemId = actionItemId
    }
}

/// Every field optional. `due: ""` or `"none"` clears the date.
public struct PatchTaskBody: Codable, Sendable {
    public var title: String?
    public var notes: String?
    public var status: String?
    public var priority: String?
    public var due: String?
    public var tags: [String]?
    public var archived: Bool?
    public var position: Double?

    public init(title: String? = nil, notes: String? = nil, status: String? = nil,
                priority: String? = nil, due: String? = nil, tags: [String]? = nil,
                archived: Bool? = nil, position: Double? = nil) {
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.due = due
        self.tags = tags
        self.archived = archived
        self.position = position
    }
}

public struct MoveBody: Codable, Sendable {
    public var status: String
    public var index: Int?
    public var position: Double?

    public init(status: String, index: Int? = nil, position: Double? = nil) {
        self.status = status
        self.index = index
        self.position = position
    }
}

public struct ListQuery: Sendable {
    public var status: TaskStatus?
    public var query: String?
    public var tag: String?
    public var priority: Priority?
    /// "today" | "overdue" | "week" | "none" | "any"
    public var due: String?
    public var source: TaskSource?
    public var meetingID: UUID?
    public var includeArchived: Bool = false
    public var includeDone: Bool = true
    public var limit: Int?
    public init() {}
}

// MARK: - Meetings

public struct MeetingDTO: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var startedAt: String
    public var duration: Double
    public var status: String
    public var summary: String?
    public var keyPoints: [String]?
    public var decisions: [String]?
    public var questions: [String]?
    public var topics: [String]?
    public var participants: [String]?
    public var actionItems: [ActionItemDTO]?
    public var transcript: TranscriptDTO?
    public var jobId: String?
    public var error: String?

    /// Server -> local. `local` is the existing row, so user-side state (which
    /// suggestions were added or dismissed) survives a refresh.
    public func merged(into existing: Meeting?) -> Meeting? {
        guard let uuid = UUID(uuidString: id) ?? existing?.id else { return nil }
        var meeting = existing ?? Meeting(id: uuid, title: title)
        meeting.remoteID = id
        meeting.title = title
        if let started = DateInput.parse(startedAt) { meeting.startedAt = started }
        if duration > 0 { meeting.duration = duration }
        meeting.status = MeetingStatus(rawValue: status) ?? meeting.status
        meeting.summary = summary ?? meeting.summary
        meeting.keyPoints = keyPoints ?? meeting.keyPoints
        meeting.decisions = decisions ?? meeting.decisions
        meeting.questions = questions ?? meeting.questions
        meeting.topics = topics ?? meeting.topics
        meeting.participants = participants ?? meeting.participants
        meeting.jobID = jobId ?? meeting.jobID
        meeting.failureReason = error ?? meeting.failureReason
        if meeting.status == .completed { meeting.processedAt = meeting.processedAt ?? Date() }

        if let remote = actionItems {
            // A decision made elsewhere (another Mac, or before a reinstall) wins when
            // the server sends `state`; otherwise keep the user's local decision.
            let decided = Dictionary(uniqueKeysWithValues:
                meeting.actionItems.filter { $0.state != .suggested }.map { ($0.id, $0) })
            let localByID = Dictionary(uniqueKeysWithValues:
                meeting.actionItems.map { ($0.id, $0) })
            meeting.actionItems = remote.enumerated().compactMap { index, dto in
                guard var item = dto.toActionItem(meetingID: meeting.id, position: Double(index)) else { return nil }
                // The server is authoritative only once it has a real decision.
                // "suggested" is also what it says before a local ADD/DISMISS has
                // synced, so trusting it would resurrect dismissed suggestions.
                let serverDecided = dto.decidedState.flatMap { $0 == .suggested ? nil : $0 }
                if let serverDecided {
                    item.state = serverDecided
                    item.taskID = dto.taskId.flatMap(UUID.init(uuidString:)) ?? item.taskID
                } else if let existing = decided[item.id] {
                    item.state = existing.state
                    item.taskID = existing.taskID
                }
                // Same rule for execution state: an unsynced local DONE must not be
                // reopened by the server's default "open".
                if item.commitmentState == .open, let local = localByID[item.id],
                   local.commitmentState != .open {
                    item.commitmentState = local.commitmentState
                    item.completedAt = local.completedAt
                }
                if item.quote == nil, let local = localByID[item.id] {
                    item.quote = local.quote
                    item.sourceStart = local.sourceStart
                    item.sourceEnd = local.sourceEnd
                }
                return item
            }
        }
        if let transcript {
            meeting.transcript = transcript.segments.compactMap { $0.toSegment() }
        }
        return meeting
    }
}

public struct ActionItemDTO: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var assignee: String?
    public var dueDate: String?
    public var confidence: Double?
    /// The server's decision for this suggestion, when it has one. Absent on older
    /// responses, where the local decision must survive.
    public var state: String?
    /// The task the server linked when the suggestion was accepted.
    public var taskId: String?
    /// Verbatim source and transcript position, when the server kept them.
    public var quote: String?
    public var sourceStart: Double?
    public var sourceEnd: Double?
    public var commitmentState: String?
    public var completedAt: String?
    public var remindedAt: String?

    public init(id: String, title: String, assignee: String? = nil, dueDate: String? = nil,
                confidence: Double? = nil, state: String? = nil, taskId: String? = nil,
                quote: String? = nil, sourceStart: Double? = nil, sourceEnd: Double? = nil,
                commitmentState: String? = nil, completedAt: String? = nil,
                remindedAt: String? = nil) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.dueDate = dueDate
        self.confidence = confidence
        self.state = state
        self.taskId = taskId
        self.quote = quote
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.commitmentState = commitmentState
        self.completedAt = completedAt
        self.remindedAt = remindedAt
    }

    /// nil unless the server actually sent a recognised state.
    var decidedState: ActionItem.State? {
        state.flatMap(ActionItem.State.init(rawValue:))
    }

    public func toActionItem(meetingID: UUID, position: Double) -> ActionItem? {
        // Server ids are opaque strings; derive a stable UUID when they are not one.
        let uuid = UUID(uuidString: id) ?? UUID.stable(from: "\(meetingID.uuidString):\(id)")
        return ActionItem(id: uuid, meetingID: meetingID, title: title, assignee: assignee,
                          dueDate: dueDate.flatMap { DateInput.parse($0) },
                          confidence: confidence ?? 0, state: decidedState ?? .suggested,
                          taskID: taskId.flatMap(UUID.init(uuidString:)), position: position,
                          quote: quote, sourceStart: sourceStart, sourceEnd: sourceEnd,
                          commitmentState: commitmentState
                            .flatMap(ActionItem.Commitment.init(rawValue:)) ?? .open,
                          completedAt: completedAt.flatMap { DateInput.parse($0) },
                          remindedAt: remindedAt.flatMap { DateInput.parse($0) })
    }
}

public struct TranscriptDTO: Codable, Sendable, Equatable {
    public var segments: [TranscriptSegmentDTO]
    public init(segments: [TranscriptSegmentDTO]) { self.segments = segments }
}

public struct TranscriptSegmentDTO: Codable, Sendable, Equatable {
    public var id: String?
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var text: String

    public func toSegment() -> TranscriptSegment? {
        TranscriptSegment(id: id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                          start: start, end: end, speaker: speaker, text: text)
    }
}

public struct CreateMeetingBody: Codable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: String
    public var duration: Double

    public init(id: String, title: String, startedAt: String, duration: Double) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
    }
}

// MARK: - Jobs

public struct JobDTO: Codable, Sendable, Equatable {
    public var id: String
    public var status: String
    public var stage: String?
    public var progress: Double?
    public var error: String?
    public var meetingId: String?

    public init(id: String, status: String, stage: String? = nil, progress: Double? = nil,
                error: String? = nil, meetingId: String? = nil) {
        self.id = id
        self.status = status
        self.stage = stage
        self.progress = progress
        self.error = error
        self.meetingId = meetingId
    }

    /// Maps a server job state onto the meeting status the UI renders.
    public var meetingStatus: MeetingStatus? {
        switch (stage ?? status).lowercased() {
        case "queued": return .queued
        case "uploading": return .uploading
        case "transcribing": return .transcribing
        case "analyzing", "analysing": return .analyzing
        case "completed", "complete", "done": return .completed
        case "failed", "error": return .failed
        default: return nil
        }
    }
}

// MARK: - Summary

public struct SummaryDTO: Codable, Sendable, Equatable {
    public var open: Int
    public var active: Int
    public var dueToday: Int
    public var overdue: Int
    public var doneToday: Int
    public var byStatus: [String: Int]
    public var agenda: [TaskDTO]
    public var generatedAt: String
}

// MARK: - Errors

public struct APIErrorBody: Codable, Sendable {
    public var error: String
    public var detail: String?
    public init(error: String, detail: String? = nil) {
        self.error = error
        self.detail = detail
    }
}

public enum APIError: Error, Sendable, LocalizedError {
    case notFound(String)
    case badRequest(String)
    case unauthorized
    case unsupported(String)
    case offline(String)
    case server(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let m): return m
        case .badRequest(let m): return m
        case .unauthorized: return "Not authorised — check the API key in Settings."
        case .unsupported(let m): return m
        case .offline(let m): return "Offline — \(m)"
        case .server(let code, let body):
            return "Server returned \(code)\(body.isEmpty ? "" : " — \(body.prefix(160))")"
        }
    }

    /// Worth retrying from the outbox later, as opposed to permanently rejected.
    public var isTransient: Bool {
        switch self {
        case .offline: return true
        case .server(let code, _): return code >= 500 || code == 429
        default: return false
        }
    }

    /// The HTTP status behind this error, when the server answered at all.
    public var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .notFound: return 404
        // validate() maps both 400 and 422 here; either way the body was rejected.
        case .badRequest: return 400
        case .server(let code, _): return code
        case .offline, .unsupported: return nil
        }
    }
}

// MARK: - Deterministic UUIDs

public extension UUID {
    /// Stable UUID derived from a string, so a server id that is not a UUID still maps
    /// to the same local identity across refreshes and launches.
    ///
    /// SHA-256, not `Hasher`: `Hasher` is seeded per process, so the same string used
    /// to produce different ids after a relaunch.
    static func stable(from string: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Server URL policy

/// One place for what counts as a usable backend URL. Settings gates every remote
/// feature on this and the sync engine refuses the same values, so the two cannot
/// disagree about why the app is local-only.
public enum ServerURLPolicy {

    /// Hosts where plain HTTP never leaves the machine.
    public static func isLoopback(host: String?) -> Bool {
        let host = (host ?? "").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// A private or carrier-grade-NAT address: LAN, link-local, or Tailscale.
    /// Plain HTTP there does not traverse the public internet.
    public static func isPrivateNetwork(host: String?) -> Bool {
        let host = (host ?? "").lowercased()
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        // Every component must be a number; `10.1.2.3.example.com` must not pass.
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // Tailscale / carrier-grade NAT
        default: return false
        }
    }

    /// nil when the URL is usable, or when nothing has been entered yet. Otherwise
    /// the sentence to show the user.
    public static func problem(with raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return "Enter a full URL, e.g. https://vps.example.com."
        }
        if scheme == "http", !isLoopback(host: host), !isPrivateNetwork(host: host) {
            return "Plain HTTP sends the API key in the clear. Use https://, or an address on your local network."
        }
        return nil
    }

    /// True only when a URL is present and acceptable.
    public static func isUsable(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespaces).isEmpty && problem(with: raw) == nil
    }
}

// MARK: - Outbox policy

/// Which failed replays may be dropped. Auth, routing and conflict failures are
/// configuration/state problems: the queued edit is still wanted, so dropping it
/// would lose user data.
public enum OutboxPolicy {
    /// Only a body the server definitively rejected may be dropped.
    public static func holdsQueue(status: Int) -> Bool {
        switch status {
        case 400, 422: return false
        // 409 means the row changed since the edit (or the server already has it).
        // The edit is still wanted; keeping it is safer than deleting it.
        default: return true
        }
    }
}
