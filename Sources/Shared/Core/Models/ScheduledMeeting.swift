import Foundation

/// A meeting the user has scheduled. Local to this Mac, like the rest of the app's
/// data: no server round trip and no external calendar dependency.
public struct ScheduledMeeting: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var location: String
    public var startsAt: Date
    public var endsAt: Date
    public var participants: [String]
    /// Set once a recording has been linked to this scheduled meeting.
    public var meetingID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, notes: String = "", location: String = "",
                startsAt: Date, endsAt: Date, participants: [String] = [],
                meetingID: UUID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.notes = notes
        self.location = location
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.participants = participants
        self.meetingID = meetingID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var duration: TimeInterval { max(0, endsAt.timeIntervalSince(startsAt)) }
    public var durationMinutes: Int { max(1, Int((duration / 60).rounded())) }

    public func isUpcoming(now: Date = Date()) -> Bool { endsAt >= now }
    public func isPast(now: Date = Date()) -> Bool { endsAt < now }
    public func isLive(now: Date = Date()) -> Bool { startsAt <= now && now <= endsAt }

    public func overlaps(_ other: ScheduledMeeting) -> Bool {
        startsAt < other.endsAt && other.startsAt < endsAt
    }

    public func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: q, options: options) != nil { return true }
        if notes.range(of: q, options: options) != nil { return true }
        if location.range(of: q, options: options) != nil { return true }
        return participants.contains { $0.range(of: q, options: options) != nil }
    }
}

/// What the agent parses before the user confirms a schedule operation.
public struct ScheduledMeetingDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var location: String
    public var startsAt: Date
    public var endsAt: Date
    public var participants: [String]

    public init(id: UUID = UUID(), title: String, notes: String = "", location: String = "",
                startsAt: Date, endsAt: Date, participants: [String] = []) {
        self.id = id
        self.title = title
        self.notes = notes
        self.location = location
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.participants = participants
    }

    public var duration: TimeInterval { max(0, endsAt.timeIntervalSince(startsAt)) }
    public var durationMinutes: Int { max(1, Int((duration / 60).rounded())) }

    public func materialise(now: Date = Date()) -> ScheduledMeeting {
        ScheduledMeeting(id: id, title: title, notes: notes, location: location,
                         startsAt: startsAt, endsAt: endsAt, participants: participants,
                         createdAt: now, updatedAt: now)
    }
}

// MARK: - Local pre-meeting brief

/// Built from the meetings, commitments and schedule already on this Mac: no model
/// call and no server.
public struct ScheduledMeetingBrief: Equatable, Sendable {
    public struct RelatedMeeting: Identifiable, Equatable, Sendable {
        public var meetingID: UUID
        public var title: String
        public var date: Date
        public var summary: String
        public var overlap: [String]

        public var id: UUID { meetingID }
    }

    public struct Action: Identifiable, Equatable, Sendable {
        public var itemID: UUID
        public var meetingID: UUID
        public var meetingTitle: String
        public var title: String
        public var assignee: String?
        public var dueDate: Date?
        public var state: ActionItem.State
        public var taskID: UUID?
        public var taskStatus: TaskStatus?
        /// The sentence and the moment it was said, so this row can be checked.
        public var quote: String?
        public var sourceStart: TimeInterval?
        public var overdue: Bool

        public var id: UUID { itemID }
    }

    public struct Decision: Identifiable, Equatable, Sendable {
        public var meetingID: UUID
        public var meetingTitle: String
        public var date: Date
        public var text: String

        public var id: String { "\(meetingID.uuidString)-\(text)" }
    }

    public struct Conflict: Identifiable, Equatable, Sendable {
        public var other: ScheduledMeeting
        public var id: UUID { other.id }
    }

    public var scheduled: ScheduledMeeting
    public var relatedMeetings: [RelatedMeeting]
    public var openActions: [Action]
    public var decisions: [Decision]
    public var conflicts: [Conflict]
    /// Questions previous conversations left unanswered.
    public var unresolvedQuestions: [Decision]
    /// Better times, only when there is a conflict to solve.
    public var suggestedSlots: [DateInterval]
    public var overdueCount: Int
    /// One paragraph the UI can show before opening anything.
    public var summary: String

    public init(scheduled: ScheduledMeeting, relatedMeetings: [RelatedMeeting] = [],
                openActions: [Action] = [], decisions: [Decision] = [],
                conflicts: [Conflict] = [], unresolvedQuestions: [Decision] = [],
                suggestedSlots: [DateInterval] = [], overdueCount: Int = 0,
                summary: String = "") {
        self.scheduled = scheduled
        self.relatedMeetings = relatedMeetings
        self.openActions = openActions
        self.decisions = decisions
        self.conflicts = conflicts
        self.unresolvedQuestions = unresolvedQuestions
        self.suggestedSlots = suggestedSlots
        self.overdueCount = overdueCount
        self.summary = summary
    }
}

public enum ScheduledBriefBuilder {
    public static func build(for scheduled: ScheduledMeeting,
                             meetings: [Meeting],
                             tasks: [TaskItem],
                             scheduledMeetings: [ScheduledMeeting],
                             now: Date = Date()) -> ScheduledMeetingBrief {
        let names = scheduled.participants
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        let related = meetings.compactMap { meeting -> (Meeting, [String])? in
            let overlap = meeting.participants.filter { participant in
                let p = participant.lowercased()
                return names.contains { p.contains($0) || $0.contains(p) }
            }
            return overlap.isEmpty ? nil : (meeting, overlap)
        }
        .sorted { a, b in
            if a.1.count != b.1.count { return a.1.count > b.1.count }
            return a.0.startedAt > b.0.startedAt
        }
        .prefix(5)
        .map { meeting, overlap in
            ScheduledMeetingBrief.RelatedMeeting(
                meetingID: meeting.id, title: meeting.title, date: meeting.startedAt,
                summary: meeting.summary, overlap: overlap)
        }

        let relatedIDs = Set(related.map(\.meetingID))
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var actions: [ScheduledMeetingBrief.Action] = []
        for meeting in meetings where relatedIDs.contains(meeting.id) {
            // Execution state, not the review decision, is what makes a commitment
            // outstanding. Dismissed suggestions and completed promises are excluded.
            for item in meeting.actionItems where item.state != .dismissed && item.isOpen {
                if let taskID = item.taskID, let task = tasksByID[taskID], task.isDone {
                    continue
                }
                actions.append(.init(
                    itemID: item.id, meetingID: meeting.id, meetingTitle: meeting.title,
                    title: item.title, assignee: item.assignee, dueDate: item.dueDate,
                    state: item.state, taskID: item.taskID,
                    taskStatus: item.taskID.flatMap { tasksByID[$0]?.status },
                    quote: item.quote, sourceStart: item.sourceStart,
                    overdue: item.isOverdue(now: now)))
            }
        }
        actions.sort { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }

        var decisions: [ScheduledMeetingBrief.Decision] = []
        for meeting in meetings where relatedIDs.contains(meeting.id) {
            for text in meeting.decisions {
                decisions.append(.init(meetingID: meeting.id, meetingTitle: meeting.title,
                                       date: meeting.startedAt, text: text))
            }
        }
        decisions = Array(decisions.sorted { $0.date > $1.date }.prefix(10))

        let conflicts = scheduledMeetings
            .filter { $0.id != scheduled.id && $0.overlaps(scheduled) }
            .sorted { $0.startsAt < $1.startsAt }
            .map { ScheduledMeetingBrief.Conflict(other: $0) }

        let overdue = actions.filter { $0.overdue }.count
        let busy = scheduledMeetings
            .filter { $0.id != scheduled.id }
            .map { DateInterval(start: $0.startsAt, end: $0.endsAt) }
            .sorted { $0.start < $1.start }
        let slots = conflicts.isEmpty ? [] : FreeTimeFinder.slots(
            duration: max(15 * 60, scheduled.duration),
            after: scheduled.startsAt, days: 7, busy: busy)

        return ScheduledMeetingBrief(
            scheduled: scheduled, relatedMeetings: related, openActions: actions,
            decisions: decisions, conflicts: conflicts, suggestedSlots: slots,
            overdueCount: overdue,
            summary: summaryLine(scheduled: scheduled, related: related, actions: actions,
                                 decisions: decisions, conflicts: conflicts,
                                 slots: slots, overdue: overdue))
    }

    private static func summaryLine(scheduled: ScheduledMeeting,
                                    related: [ScheduledMeetingBrief.RelatedMeeting],
                                    actions: [ScheduledMeetingBrief.Action],
                                    decisions: [ScheduledMeetingBrief.Decision],
                                    conflicts: [ScheduledMeetingBrief.Conflict],
                                    slots: [DateInterval],
                                    overdue: Int) -> String {
        var parts: [String] = []
        if !scheduled.participants.isEmpty {
            parts.append("With \(scheduled.participants.joined(separator: ", ")).")
        }
        if let last = related.first {
            parts.append("Last conversation: \"\(last.title)\" on "
                         + "\(DateInput.shortLabel(last.date)). \(last.summary)")
        } else {
            parts.append("No previous conversation with these people was found.")
        }
        if !actions.isEmpty {
            parts.append("\(actions.count) commitment\(actions.count == 1 ? "" : "s") "
                         + "still open\(overdue > 0 ? ", \(overdue) overdue" : "").")
        }
        if !decisions.isEmpty {
            parts.append("\(decisions.count) earlier decision\(decisions.count == 1 ? "" : "s") "
                         + "to revisit.")
        }
        if let conflict = conflicts.first {
            parts.append("Overlaps with \"\(conflict.other.title)\" at "
                         + "\(CalendarFormat.range(conflict.other.startsAt, conflict.other.endsAt)).")
            if let slot = slots.first {
                parts.append("Suggested alternative: \(CalendarFormat.dateTime(slot.start)).")
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Formatting

public enum CalendarFormat {
    public static func day(_ date: Date, now: Date = Date()) -> String {
        DateInput.shortLabel(date, now: now)
    }

    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    public static func range(_ start: Date, _ end: Date) -> String {
        "\(time(start))–\(time(end))"
    }

    public static func dateTime(_ date: Date) -> String {
        "\(day(date)) \(time(date))"
    }

    public static func line(_ meeting: ScheduledMeeting) -> String {
        "\(day(meeting.startsAt)) · \(range(meeting.startsAt, meeting.endsAt))"
    }

    public static func line(_ draft: ScheduledMeetingDraft) -> String {
        "\(day(draft.startsAt)) · \(range(draft.startsAt, draft.endsAt))"
    }

    public static func proposal(_ draft: ScheduledMeetingDraft) -> String {
        var line = "SCHEDULE · \(draft.title)\n\(CalendarFormat.line(draft))"
        if !draft.participants.isEmpty {
            line += " · \(draft.participants.joined(separator: ", ").uppercased())"
        }
        return line
    }
}

// MARK: - Grouping

public extension Array where Element == ScheduledMeeting {
    /// Newest first within each block.
    func scheduledSorted() -> [ScheduledMeeting] {
        sorted { $0.startsAt < $1.startsAt }
    }

    func upcoming(now: Date = Date()) -> [ScheduledMeeting] {
        filter { $0.isUpcoming(now: now) }.scheduledSorted()
    }

    func past(now: Date = Date()) -> [ScheduledMeeting] {
        filter { $0.isPast(now: now) }.sorted { $0.startsAt > $1.startsAt }
    }
}
