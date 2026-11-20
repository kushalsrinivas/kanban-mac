import Foundation
import NaturalLanguage

// MARK: - Semantic index

/// On-device sentence embeddings. This is the only "model" involved in mail search:
/// no message, attachment or query leaves the Mac. If the system embedding is not
/// available, search falls back to SQLite FTS and still works.
@MainActor
public enum GmailSemanticIndex {
    public static var isAvailable: Bool {
        NLEmbedding.sentenceEmbedding(for: .english) != nil
    }

    public static func indexPending(store: GmailStore, accountID: UUID? = nil,
                                    limit: Int = 200) async {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return }
        let messages = store.messagesWithoutEmbeddings(accountID: accountID, limit: limit)
        guard !messages.isEmpty else { return }
        for message in messages {
            if Task.isCancelled { return }
            let text = "\(message.subject). \(String(message.bodyText.prefix(1800)))"
            if let vector = embedding.vector(for: text), !vector.isEmpty {
                store.storeEmbedding(messageID: message.id, accountID: message.accountID,
                                     vector: vector.map(Float.init))
            }
            await Task.yield()
        }
    }

    public static func queryVector(_ query: String) -> [Float]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let vector = embedding.vector(for: query), !vector.isEmpty else { return nil }
        return vector.map(Float.init)
    }

    public static func cosine(_ left: [Float], _ right: [Float]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var dot: Double = 0
        var a: Double = 0
        var b: Double = 0
        for index in left.indices {
            let x = Double(left[index])
            let y = Double(right[index])
            dot += x * y
            a += x * x
            b += y * y
        }
        guard a > 0, b > 0 else { return 0 }
        return dot / (a.squareRoot() * b.squareRoot())
    }
}

// MARK: - Search

public extension GmailStore {
    /// Searches threads locally. FTS runs first; a semantic pass adds paraphrases
    /// ("the pricing conversation" → "commercial terms") when the on-device
    /// embedding is available. Nothing is sent to Google.
    func searchThreads(_ query: GmailQuery, accountID: UUID? = nil,
                       limit: Int = 30) -> [GmailThreadSummary] {
        var out = threads(accountID: accountID, query: query, limit: limit, offset: 0)
        if out.count >= limit || query.text.trimmingCharacters(in: .whitespaces).isEmpty {
            return out
        }

        // A strict AND over every token is precise but brittle. Retry with OR
        // before giving up, so "pricing meeting notes" still finds a message that
        // only contains two of the three words.
        if out.isEmpty {
            var relaxed = query
            relaxed.matchAllTokens = false
            out = threads(accountID: accountID, query: relaxed, limit: limit, offset: 0)
            if !out.isEmpty { return out }
        }

        guard let vector = GmailSemanticIndex.queryVector(query.text) else { return out }
        var best: [String: (accountID: UUID, threadID: String, score: Double)] = [:]
        for item in embeddings(accountID: accountID) {
            let score = GmailSemanticIndex.cosine(vector, item.vector)
            guard score > 0.22 else { continue }
            guard let threadID = threadID(accountID: item.accountID,
                                          messageID: item.messageID) else { continue }
            let key = "\(item.accountID.uuidString)|\(threadID)"
            if let existing = best[key], existing.score >= score { continue }
            best[key] = (item.accountID, threadID, score)
        }
        var seen = Set(out.map { "\($0.accountID.uuidString)|\($0.id)" })
        for (key, value) in best.sorted(by: { $0.value.score > $1.value.score }) {
            guard out.count < limit, !seen.contains(key) else { continue }
            guard let summary = summary(accountID: value.accountID,
                                        threadID: value.threadID),
                  matchesFilters(summary, query: query) else { continue }
            seen.insert(key)
            out.append(summary)
        }
        return out
    }

    private func matchesFilters(_ thread: GmailThreadSummary, query: GmailQuery) -> Bool {
        if let mailbox = query.mailbox {
            let has = { (label: String) in thread.labelIDs.contains(label) }
            switch mailbox {
            case .inbox: guard has("INBOX") else { return false }
            case .starred: guard thread.starred else { return false }
            case .important: guard has("IMPORTANT") else { return false }
            case .sent: guard has("SENT") else { return false }
            case .drafts: guard has("DRAFT") else { return false }
            case .spam: guard has("SPAM") else { return false }
            case .trash: guard has("TRASH") else { return false }
            case .archive:
                guard !has("INBOX") && !has("SENT") && !has("DRAFT")
                        && !has("SPAM") && !has("TRASH") else { return false }
            case .all: break
            }
        }
        if let unread = query.unread, thread.isUnread != unread { return false }
        if let starred = query.starred, thread.starred != starred { return false }
        if query.hasAttachment == true, !thread.hasAttachments { return false }
        if let newer = query.newerThan, thread.lastDate < newer { return false }
        if let older = query.olderThan, thread.lastDate > older { return false }
        if let from = query.from, !from.isEmpty {
            let haystack = thread.participants.map { "\($0.name) \($0.email)" }
                .joined(separator: " ").lowercased()
            if !haystack.contains(from.lowercased()) { return false }
        }
        if let subject = query.subject, !subject.isEmpty,
           !thread.subject.localizedCaseInsensitiveContains(subject) { return false }
        if let label = query.label, !label.isEmpty {
            let labels = labels(accountID: thread.accountID)
            let id = labels.first {
                $0.id.caseInsensitiveCompare(label) == .orderedSame
                    || $0.name.caseInsensitiveCompare(label) == .orderedSame
            }?.id
            if let id, !thread.labelIDs.contains(id) { return false }
            if id == nil, !thread.labelIDs.contains(where: {
                $0.caseInsensitiveCompare(label) == .orderedSame
            }) { return false }
        }
        return true
    }
}


// MARK: - Local insight

public struct GmailUnreadSummary: Sendable {
    public var totalUnread: Int
    public var threads: [GmailThreadSummary]
    public var senders: [String]
    public var subjects: [String]
    public var generatedAt: Date

    public var reply: String {
        guard totalUnread > 0 else { return "Your inbox is clear." }
        var line = "\(totalUnread) unread message\(totalUnread == 1 ? "" : "s") in \(threads.count) conversation\(threads.count == 1 ? "" : "s")."
        if !senders.isEmpty {
            line += " Most recent from \(senders.prefix(3).joined(separator: ", "))."
        }
        return line
    }
}

public struct GmailEmailCommitment: Identifiable, Equatable, Sendable {
    public var accountID: UUID
    public var threadID: String
    public var messageID: String
    public var sender: String
    public var subject: String
    public var date: Date
    public var quote: String
    public var dueText: String?

    public var id: String { "\(threadID)-\(messageID)-\(quote.prefix(24))" }
}

public struct GmailAttentionItem: Identifiable, Sendable {
    public var accountID: UUID
    public var thread: GmailThreadSummary
    public var score: Double
    public var reason: String

    public var id: String { "\(accountID.uuidString)-\(thread.id)" }
}

@MainActor
public enum GmailInsight {
    public static func unreadSummary(store: GmailStore,
                                     accountID: UUID? = nil) -> GmailUnreadSummary {
        var query = GmailQuery(mailbox: .inbox)
        query.unread = true
        query.limit = 60
        let threads = store.searchThreads(query, accountID: accountID, limit: 60)
        var senders: [String] = []
        var subjects: [String] = []
        var seen = Set<String>()
        for thread in threads {
            if let sender = thread.participants.first?.displayName,
               seen.insert(sender.lowercased()).inserted {
                senders.append(sender)
            }
            if !thread.displaySubject.isEmpty { subjects.append(thread.displaySubject) }
        }
        return GmailUnreadSummary(
            totalUnread: threads.reduce(0) { $0 + $1.unreadCount },
            threads: threads, senders: senders, subjects: subjects,
            generatedAt: Date())
    }

    public static func commitments(in thread: GmailThread,
                                   accountID: UUID) -> [GmailEmailCommitment] {
        var out: [GmailEmailCommitment] = []
        for message in thread.orderedMessages {
            for sentence in sentences(message.bodyText + "\n" + message.snippet) {
                guard looksLikeCommitment(sentence) else { continue }
                out.append(GmailEmailCommitment(
                    accountID: accountID, threadID: thread.id, messageID: message.id,
                    sender: message.from.displayName, subject: message.subject,
                    date: message.internalDate, quote: sentence,
                    dueText: detectedDate(sentence)))
                if out.count >= 12 { return out }
            }
        }
        return out
    }

    public static func attention(store: GmailStore, accountID: UUID? = nil,
                                 limit: Int = 12) -> [GmailAttentionItem] {
        var query = GmailQuery(mailbox: .inbox)
        query.limit = 200
        let candidates = store.searchThreads(query, accountID: accountID, limit: 200)
        let now = Date()
        let accounts = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0) })
        var out: [GmailAttentionItem] = []
        for thread in candidates {
            var score = 0.0
            var reasons: [String] = []
            if thread.isUnread { score += 4; reasons.append("unread") }
            if thread.starred { score += 5; reasons.append("starred") }
            if thread.labelIDs.contains("IMPORTANT") {
                score += 3; reasons.append("important")
            }
            let age = now.timeIntervalSince(thread.lastDate)
            if age < 86_400 { score += 3; reasons.append("today") }
            else if age < 3 * 86_400 { score += 1.5; reasons.append("recent") }
            let text = (thread.subject + " " + thread.snippet).lowercased()
            if text.contains("?") { score += 2; reasons.append("question") }
            if ["deadline", "due", "asap", "urgent", "today", "tomorrow", "eod", "blocked"]
                .contains(where: text.contains) {
                score += 3; reasons.append("time-sensitive")
            }
            let sender = thread.participants.first?.email.lowercased() ?? ""
            if ["noreply", "no-reply", "newsletter", "notifications", "digest"]
                .contains(where: sender.contains) {
                score -= 4
            }
            if let account = accounts[thread.accountID],
               thread.participants.contains(where: {
                   $0.email.lowercased() == account.email.lowercased()
                       || thread.labelIDs.contains("SENT")
               }) {
                score += 1
            }
            guard score > 2 else { continue }
            out.append(GmailAttentionItem(
                accountID: thread.accountID, thread: thread, score: score,
                reason: reasons.joined(separator: " · ")))
        }
        return out.sorted {
            $0.score == $1.score ? $0.thread.lastDate > $1.thread.lastDate : $0.score > $1.score
        }.prefix(limit).map { $0 }
    }

    public static func conversation(store: GmailStore, person: String,
                                    accountID: UUID? = nil,
                                    limit: Int = 12) -> [GmailThreadSummary] {
        let clean = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var query = GmailQuery()
        if clean.contains("@") { query.from = clean } else { query.text = clean }
        var out = store.searchThreads(query, accountID: accountID, limit: limit)
        if out.isEmpty {
            query = GmailQuery()
            query.text = clean
            out = store.searchThreads(query, accountID: accountID, limit: limit)
        }
        return out
    }

    public static func insight(for thread: GmailThread,
                               accountID: UUID) -> (summary: String, commitments: [GmailEmailCommitment]) {
        let messages = thread.orderedMessages
        let subjectWords = Set(AgentText.keywords(thread.summary.subject))
        var candidates: [(text: String, score: Double, date: Date)] = []
        for message in messages {
            for sentence in sentences(message.bodyText) where !sentence.hasPrefix(">") {
                let words = AgentText.keywords(sentence)
                guard !words.isEmpty else { continue }
                var score = Double(words.count)
                if words.contains(where: subjectWords.contains) { score += 2 }
                if message == messages.last { score += 1 }
                if sentence.contains("?") { score += 0.5 }
                candidates.append((sentence, score, message.internalDate))
            }
        }
        let highlights = candidates
            .sorted { $0.score == $1.score ? $0.date > $1.date : $0.score > $1.score }
            .prefix(4)
            .sorted { $0.date < $1.date }
            .map(\.text)
        var lines: [String] = []
        lines.append("\(thread.summary.displaySubject) · \(thread.summary.messageCount) message\(thread.summary.messageCount == 1 ? "" : "s")")
        let participants = thread.summary.participants.map(\.displayName)
            .prefix(4).joined(separator: ", ")
        if !participants.isEmpty { lines.append("With \(participants).") }
        lines.append(contentsOf: highlights.map { "• \($0)" })
        return (lines.joined(separator: "\n"),
                commitments(in: thread, accountID: accountID))
    }

    public static func sentences(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { line -> [String] in
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.components(separatedBy: ". ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
            .filter { $0.count >= 12 && $0.count <= 400 }
    }

    private static func looksLikeCommitment(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        let patterns = ["i will", "we will", "i'll", "we'll", "will send", "will share",
                        "promise", "commit", "deliver", "follow up", "get back to you",
                        "by tomorrow", "by monday", "by tuesday", "by wednesday",
                        "by thursday", "by friday", "deadline", "due", "action item",
                        "next step", "will review", "will prepare", "will finish"]
        return patterns.contains { lower.contains($0) }
    }

    private static func detectedDate(_ sentence: String) -> String? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(location: 0, length: (sentence as NSString).length)
        guard let match = detector.firstMatch(in: sentence, range: range),
              let date = match.date else { return nil }
        return GmailFormat.fullDate(date)
    }
}
