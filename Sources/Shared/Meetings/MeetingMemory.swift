import Foundation

// MARK: - Entries and hits

/// One retrievable fact from a meeting. Derived, never authoritative: it can be
/// rebuilt from the meetings table at any time.
public struct LocalMemoryEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Hashable {
        case summary, decision, commitment, discussion, question, transcript
        public var label: String {
            switch self {
            case .summary: return "SUMMARY"
            case .decision: return "DECISION"
            case .commitment: return "COMMITMENT"
            case .discussion: return "DISCUSSION"
            case .question: return "QUESTION"
            case .transcript: return "TRANSCRIPT"
            }
        }
    }

    public var id: String
    public var meetingID: UUID
    public var kind: Kind
    public var text: String
    public var speaker: String?
    public var start: TimeInterval?
    public var end: TimeInterval?
    public var participants: [String]
    public var topics: [String]
    public var occurredAt: Date

    public init(id: String, meetingID: UUID, kind: Kind, text: String,
                speaker: String? = nil, start: TimeInterval? = nil,
                end: TimeInterval? = nil, participants: [String] = [],
                topics: [String] = [], occurredAt: Date) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.text = text
        self.speaker = speaker
        self.start = start
        self.end = end
        self.participants = participants
        self.topics = topics
        self.occurredAt = occurredAt
    }
}

public struct LocalMemoryHit: Identifiable, Hashable, Sendable {
    public var entry: LocalMemoryEntry
    public var meetingTitle: String
    public var score: Double
    public var snippet: String

    public var id: String { entry.id }
    public var meetingID: UUID { entry.meetingID }
    public var meetingDate: Date { entry.occurredAt }
    public var kind: LocalMemoryEntry.Kind { entry.kind }
    public var text: String { entry.text }

    public init(entry: LocalMemoryEntry, meetingTitle: String, score: Double, snippet: String) {
        self.entry = entry
        self.meetingTitle = meetingTitle
        self.score = score
        self.snippet = snippet
    }
}

public struct LocalContradiction: Identifiable, Hashable, Sendable {
    public var earlier: LocalMemoryHit
    public var later: LocalMemoryHit
    public var similarity: Double
    public var reason: String

    public var id: String { "\(earlier.id)|\(later.id)" }
}

public struct LocalMemoryAnswer: Sendable {
    public var answer: String
    public var citations: [LocalMemoryHit]
    public var confident: Bool

    public init(answer: String, citations: [LocalMemoryHit], confident: Bool) {
        self.answer = answer
        self.citations = citations
        self.confident = confident
    }
}

// MARK: - Engine

public enum MeetingMemory {

    // MARK: Index

    public static func entries(meetings: [Meeting]) -> [LocalMemoryEntry] {
        var out: [LocalMemoryEntry] = []
        for meeting in meetings {
            var index = 0
            func add(_ kind: LocalMemoryEntry.Kind, _ text: String,
                     start: TimeInterval? = nil, end: TimeInterval? = nil,
                     speaker: String? = nil) {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                out.append(LocalMemoryEntry(
                    id: "\(meeting.id.uuidString):\(kind.rawValue):\(index)",
                    meetingID: meeting.id, kind: kind, text: cleaned,
                    speaker: speaker, start: start, end: end,
                    participants: meeting.participants, topics: meeting.topics,
                    occurredAt: meeting.startedAt))
                index += 1
            }
            add(.summary, meeting.summary)
            for decision in meeting.decisions { add(.decision, decision) }
            for point in meeting.keyPoints { add(.discussion, point) }
            for question in meeting.questions { add(.question, question) }
            for item in meeting.actionItems {
                let text = item.quote.map { "\(item.title) — \"\($0)\"" } ?? item.title
                add(.commitment, text, start: item.sourceStart, end: item.sourceEnd,
                    speaker: item.assignee)
            }
        }
        return out
    }

    // MARK: Search

    public static func search(_ query: String,
                              meetings: [Meeting],
                              transcripts: [UUID: [TranscriptSegment]] = [:],
                              kind: LocalMemoryEntry.Kind? = nil,
                              participant: String? = nil,
                              since: Date? = nil,
                              until: Date? = nil,
                              limit: Int = 20) -> [LocalMemoryHit] {
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        let byID = Dictionary(meetings.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var hits: [LocalMemoryHit] = []

        for entry in entries(meetings: meetings) {
            guard let meeting = byID[entry.meetingID] else { continue }
            guard kind == nil || kind == entry.kind else { continue }
            guard matchesDate(entry.occurredAt, since: since, until: until) else { continue }
            guard matchesParticipant(meeting, participant) else { continue }
            var score = Double(count(terms, in: entry.text)) * 3
            score += Double(count(terms, in: meeting.title)) * 2
            score += Double(count(terms, in: entry.topics.joined(separator: " ")))
            if entry.text.lowercased().contains(query.lowercased()) { score += 5 }
            guard score > 0 else { continue }
            score += recency(entry.occurredAt)
            hits.append(LocalMemoryHit(entry: entry, meetingTitle: meeting.title,
                                       score: score, snippet: snippet(entry.text, terms)))
        }

        if kind == nil || kind == .transcript {
            for (meetingID, segments) in transcripts {
                guard let meeting = byID[meetingID] else { continue }
                guard matchesDate(meeting.startedAt, since: since, until: until) else { continue }
                guard matchesParticipant(meeting, participant) else { continue }
                for (index, segment) in segments.enumerated() {
                    var score = Double(count(terms, in: segment.text)) * 2
                    guard score > 0 else { continue }
                    if segment.text.lowercased().contains(query.lowercased()) { score += 4 }
                    score += recency(meeting.startedAt)
                    let entry = LocalMemoryEntry(
                        id: "segment:\(meetingID.uuidString):\(index)",
                        meetingID: meetingID, kind: .transcript, text: segment.text,
                        speaker: segment.speaker, start: segment.start, end: segment.end,
                        participants: meeting.participants, topics: meeting.topics,
                        occurredAt: meeting.startedAt)
                    hits.append(LocalMemoryHit(entry: entry, meetingTitle: meeting.title,
                                               score: score, snippet: snippet(segment.text, terms)))
                }
            }
        }

        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.meetingDate > $1.meetingDate
        }
        return Array(hits.prefix(max(1, limit)))
    }

    // MARK: Ask

    /// Extractive answers, no model call and no network. The citations are the
    /// point: every sentence can be opened in its meeting.
    public static func answer(_ question: String,
                              meetings: [Meeting],
                              transcripts: [UUID: [TranscriptSegment]] = [:],
                              since: Date? = nil,
                              limit: Int = 8) -> LocalMemoryAnswer {
        let hits = search(question, meetings: meetings, transcripts: transcripts,
                          since: since, limit: limit)
        guard !hits.isEmpty else {
            return LocalMemoryAnswer(
                answer: "I could not find anything in the meeting history about that.",
                citations: [], confident: false)
        }

        let decisions = hits.filter { $0.kind == .decision }
            .sorted { $0.meetingDate < $1.meetingDate }
        var sentences: [String] = []
        var cited: [LocalMemoryHit] = []

        if decisions.count >= 2,
           let first = decisions.first, let last = decisions.last,
           polarity(first.text) * polarity(last.text) == -1 {
            sentences.append("That changed. On \(date(first.meetingDate)), "
                             + "\"\(first.meetingTitle)\" decided: \(first.text)")
            sentences.append("Later, on \(date(last.meetingDate)), "
                             + "\"\(last.meetingTitle)\" decided: \(last.text)")
            cited = [first, last]
        } else if let decision = decisions.last {
            sentences.append("On \(date(decision.meetingDate)), \"\(decision.meetingTitle)\" "
                             + "decided: \(decision.text)")
            let others = Array(hits.filter { $0.kind != .decision && $0.id != decision.id }.prefix(2))
            for hit in others {
                sentences.append("Earlier context from \"\(hit.meetingTitle)\": \(hit.text)")
            }
            cited = [decision] + others
        } else if let summary = hits.first(where: { $0.kind == .summary }) {
            sentences.append("From \"\(summary.meetingTitle)\" on "
                             + "\(date(summary.meetingDate)): \(summary.text)")
            cited = [summary]
        } else {
            let picked = Array(hits.prefix(3))
            for hit in picked {
                sentences.append("\(hit.meetingTitle) (\(date(hit.meetingDate))): \(hit.text)")
            }
            cited = picked
        }

        return LocalMemoryAnswer(answer: sentences.joined(separator: "\n\n"),
                                 citations: cited, confident: true)
    }

    // MARK: Contradictions

    /// Lexical candidates, not verdicts. Two decisions must share vocabulary and
    /// carry opposite polarity before this reports them; the UI calls them possible.
    public static func contradictions(meetings: [Meeting], limit: Int = 20) -> [LocalContradiction] {
        let decisions = entries(meetings: meetings)
            .filter { $0.kind == .decision }
            .sorted { $0.occurredAt < $1.occurredAt }
        let titles = Dictionary(meetings.map { ($0.id, $0.title) },
                                uniquingKeysWith: { first, _ in first })
        var out: [LocalContradiction] = []

        for i in 0..<decisions.count {
            for j in (i + 1)..<decisions.count {
                let earlier = decisions[i], later = decisions[j]
                guard earlier.meetingID != later.meetingID else { continue }
                let a = tokens(earlier.text), b = tokens(later.text)
                guard !a.isEmpty, !b.isEmpty else { continue }
                let similarity = Double(a.intersection(b).count) / Double(a.union(b).count)
                guard similarity >= 0.25 else { continue }

                let reversed = ["instead of", "changed from", "reversed", "reversing",
                                "no longer", "walk back", "walked back"]
                    .contains { later.text.lowercased().contains($0) }
                let opposed = polarity(earlier.text) * polarity(later.text) == -1
                guard opposed || (reversed && similarity >= 0.2) else { continue }

                let shared = a.intersection(b).sorted().prefix(5).joined(separator: ", ")
                var reason = opposed ? "Opposite stance on the same topic"
                                     : "Later decision explicitly reverses the earlier one"
                if !shared.isEmpty { reason += " (shared: \(shared))" }

                let earlierHit = hit(earlier, titles: titles)
                let laterHit = hit(later, titles: titles)
                out.append(LocalContradiction(earlier: earlierHit, later: laterHit,
                                              similarity: similarity, reason: reason))
            }
        }
        return Array(out.sorted { $0.similarity > $1.similarity }.prefix(max(1, limit)))
    }

    // MARK: Transcript linkage

    /// Attaches each commitment to the segment that made it. The quote is preferred;
    /// the title is a fallback when the model paraphrased.
    public static func attachSources(to meeting: Meeting,
                                     segments: [TranscriptSegment]) -> Meeting {
        guard !segments.isEmpty else { return meeting }
        var updated = meeting
        for index in updated.actionItems.indices {
            guard updated.actionItems[index].sourceStart == nil else { continue }
            let item = updated.actionItems[index]
            for candidate in [item.quote, item.title].compactMap({ $0 }) {
                guard let match = matchSegment(candidate, in: segments) else { continue }
                updated.actionItems[index].quote = updated.actionItems[index].quote ?? match.text
                updated.actionItems[index].sourceStart = match.start
                updated.actionItems[index].sourceEnd = match.end
                break
            }
        }
        return updated
    }

    // MARK: Brief

    /// Pre-meeting brief built from local meetings, transcripts and the schedule.
    public static func brief(for scheduled: ScheduledMeeting,
                             meetings: [Meeting],
                             transcripts: [UUID: [TranscriptSegment]] = [:],
                             scheduledMeetings: [ScheduledMeeting],
                             tasks: [TaskItem]) -> ScheduledMeetingBrief {
        // The existing builder answers the first four questions; the memory engine
        // adds decisions from questions that were never resolved.
        let builder = ScheduledBriefBuilder.build(for: scheduled, meetings: meetings,
                                                  tasks: tasks,
                                                  scheduledMeetings: scheduledMeetings)
        let relatedIDs = Set(builder.relatedMeetings.map(\.meetingID))
        var questions: [ScheduledMeetingBrief.Decision] = []
        for meeting in meetings where relatedIDs.contains(meeting.id) {
            for text in meeting.questions {
                questions.append(.init(meetingID: meeting.id, meetingTitle: meeting.title,
                                       date: meeting.startedAt, text: text))
            }
        }
        var enriched = builder
        enriched.unresolvedQuestions = Array(questions.sorted { $0.date > $1.date }.prefix(8))
        return enriched
    }

    // MARK: Helpers

    private static let stopwords: Set<String> = [
        "the", "and", "for", "was", "were", "are", "with", "that", "this", "from",
        "have", "has", "had", "will", "would", "could", "should", "about", "what",
        "when", "where", "why", "how", "who", "which", "did", "does", "doing", "our",
        "your", "their", "them", "they", "you", "but", "not", "into", "over", "than",
        "then", "there", "here", "been", "being", "just", "also", "can", "may", "might",
        "must", "shall", "one", "two", "its", "we're", "we've", "i'm", "don't",
        "didn't", "doesn't", "isn't", "wasn't", "previous", "current"
    ]

    private static let affirm: Set<String> = [
        "approve", "approved", "accept", "accepted", "adopt", "adopted", "keep", "kept",
        "continue", "proceed", "launch", "launched", "ship", "shipped", "enable",
        "enabled", "increase", "increased", "use", "using", "migrate", "migrated",
        "support", "supported", "agree", "agreed", "yes", "go", "retain", "commit",
        "committed", "invest", "build"
    ]

    private static let negate: Set<String> = [
        "not", "no", "never", "cannot", "cant", "won't", "wont", "reject", "rejected",
        "decline", "declined", "cancel", "cancelled", "canceled", "stop", "stopped",
        "drop", "dropped", "remove", "removed", "avoid", "against", "postpone",
        "postponed", "delay", "delayed", "defer", "deferred", "disable", "disabled",
        "deprecate", "deprecated", "sunset", "kill", "killed", "end", "ended", "pause",
        "paused", "abandon", "abandoned"
    ]

    private static func words(_ text: String) -> [String] {
        var seen: [String] = []
        for word in rawWords(text) where word.count >= 3
            && !stopwords.contains(word) && !seen.contains(word) {
            seen.append(word)
            if seen.count == 12 { break }
        }
        return seen
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(rawWords(text).filter { $0.count > 2 && !stopwords.contains($0) })
    }

    private static func rawWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    private static func count(_ terms: [String], in text: String) -> Int {
        let lowered = text.lowercased()
        return terms.reduce(0) { $0 + lowered.components(separatedBy: $1).count - 1 }
    }

    private static func recency(_ date: Date, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(date)) / 86_400
        return 0.5 / (1 + days / 30)
    }

    private static func snippet(_ text: String, _ terms: [String], size: Int = 180) -> String {
        let lowered = text.lowercased()
        guard let position = terms.compactMap({ lowered.range(of: $0)?.lowerBound }).min()
        else { return String(text.prefix(size)) }
        let offset = lowered.distance(from: lowered.startIndex, to: position)
        let start = max(0, offset - size / 3)
        let startIndex = text.index(text.startIndex, offsetBy: min(start, text.count))
        let endIndex = text.index(startIndex, offsetBy: min(size, text.count - start))
        let prefix = start > 0 ? "..." : ""
        let suffix = endIndex < text.endIndex ? "..." : ""
        return prefix + text[startIndex..<endIndex].trimmingCharacters(in: .whitespaces) + suffix
    }

    private static func matchesDate(_ date: Date, since: Date?, until: Date?) -> Bool {
        if let since, date < since { return false }
        if let until, date > until { return false }
        return true
    }

    private static func matchesParticipant(_ meeting: Meeting, _ participant: String?) -> Bool {
        guard let participant, !participant.isEmpty else { return true }
        let needle = participant.lowercased()
        return meeting.participants.contains { $0.lowercased().contains(needle) }
            || meeting.title.lowercased().contains(needle)
    }

    private static func polarity(_ text: String) -> Int {
        let words = Set(rawWords(text))
        let negative = !words.intersection(negate).isEmpty
        let positive = !words.intersection(affirm).isEmpty
        if negative && !positive { return -1 }
        if positive && !negative { return 1 }
        return 0
    }

    private static func hit(_ entry: LocalMemoryEntry, titles: [UUID: String]) -> LocalMemoryHit {
        LocalMemoryHit(entry: entry, meetingTitle: titles[entry.meetingID] ?? "Meeting",
                       score: 0, snippet: snippet(entry.text, words(entry.text)))
    }

    private static func matchSegment(_ candidate: String, in segments: [TranscriptSegment])
        -> TranscriptSegment? {
        let needle = normalized(candidate)
        guard needle.count >= 4 else { return nil }
        for segment in segments where normalized(segment.text).contains(needle) {
            return segment
        }
        let wanted = Set(rawWords(candidate).filter { $0.count > 3 })
        guard !wanted.isEmpty else { return nil }
        var best: (Double, TranscriptSegment)?
        for segment in segments {
            let have = Set(rawWords(segment.text))
            let score = Double(wanted.intersection(have).count) / Double(wanted.count)
            if score >= 0.6, best == nil || score > best!.0 { best = (score, segment) }
        }
        return best?.1
    }

    private static func normalized(_ text: String) -> String {
        rawWords(text).joined(separator: " ")
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
