import Foundation

/// The read surface the agent is allowed to see. It is deliberately narrow: the
/// agent can search, open a thread and save a draft, but it cannot send.
@MainActor
public protocol GmailDataSource: AnyObject {
    var accounts: [GmailAccount] { get }
    var isSecurityLocked: Bool { get }
    func account(_ id: UUID) -> GmailAccount?
    func threads(accountID: UUID?, query: GmailQuery, limit: Int, offset: Int) -> [GmailThreadSummary]
    func searchThreads(_ query: GmailQuery, accountID: UUID?, limit: Int) -> [GmailThreadSummary]
    func thread(accountID: UUID, threadID: String) -> GmailThread?
    func drafts(accountID: UUID?) -> [GmailDraft]
    func relatedThreads(participants: [String], accountID: UUID?, since: Date?, limit: Int) -> [GmailThreadSummary]
    func summary(accountID: UUID, threadID: String) -> GmailThreadSummary?
    func labels(accountID: UUID) -> [GmailLabel]
    @discardableResult func saveDraft(_ draft: GmailDraft) -> GmailDraft
    func deleteDraft(_ id: UUID)
}

extension GmailStore: GmailDataSource {}

// MARK: - Agent reads

@MainActor
public enum GmailAgentReader {
    public static func accounts(_ source: GmailDataSource) -> [GmailAccount] {
        source.accounts
    }

    public static func search(_ query: GmailQuery, accountID: UUID? = nil,
                              source: GmailDataSource, limit: Int = 20) -> [GmailThreadSummary] {
        source.searchThreads(query, accountID: accountID, limit: limit)
    }

    public static func unread(_ source: GmailDataSource,
                              accountID: UUID? = nil) -> GmailUnreadSummary {
        // The protocol has no insight dependency; build it from the same reads.
        var query = GmailQuery(mailbox: .inbox)
        query.unread = true
        let threads = source.searchThreads(query, accountID: accountID, limit: 60)
        var senders: [String] = []
        var subjects: [String] = []
        var seen = Set<String>()
        for thread in threads {
            if let name = thread.participants.first?.displayName,
               seen.insert(name.lowercased()).inserted {
                senders.append(name)
            }
            subjects.append(thread.displaySubject)
        }
        return GmailUnreadSummary(
            totalUnread: threads.reduce(0) { $0 + $1.unreadCount },
            threads: threads, senders: senders, subjects: subjects,
            generatedAt: Date())
    }

    public static func conversation(_ person: String, source: GmailDataSource,
                                    accountID: UUID? = nil,
                                    limit: Int = 12) -> [GmailThreadSummary] {
        let clean = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var query = GmailQuery()
        if clean.contains("@") { query.from = clean } else { query.text = clean }
        var out = source.searchThreads(query, accountID: accountID, limit: limit)
        if out.isEmpty {
            // Fall back to a participant match across recent threads.
            out = source.relatedThreads(participants: [clean], accountID: accountID,
                                        since: nil, limit: limit)
        }
        return out
    }

    public static func commitments(person: String?, source: GmailDataSource,
                                    accountID: UUID? = nil,
                                    limit: Int = 20) -> [GmailEmailCommitment] {
        let threads: [GmailThreadSummary]
        if let person, !person.isEmpty {
            threads = conversation(person, source: source, accountID: accountID, limit: 12)
        } else {
            var query = GmailQuery(mailbox: .inbox)
            query.limit = 40
            threads = source.searchThreads(query, accountID: accountID, limit: 40)
        }
        var out: [GmailEmailCommitment] = []
        for summary in threads {
            guard let thread = source.thread(accountID: summary.accountID,
                                             threadID: summary.id) else { continue }
            out.append(contentsOf: GmailInsight.commitments(in: thread,
                                                            accountID: summary.accountID))
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    public static func attention(source: GmailDataSource, accountID: UUID? = nil,
                                 limit: Int = 12) -> [GmailAttentionItem] {
        var query = GmailQuery(mailbox: .inbox)
        query.limit = 200
        let candidates = source.searchThreads(query, accountID: accountID, limit: 200)
        let now = Date()
        let accounts = Dictionary(uniqueKeysWithValues: source.accounts.map { ($0.id, $0) })
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
               }) {
                score += 1
            }
            guard score > 2 else { continue }
            out.append(GmailAttentionItem(accountID: thread.accountID, thread: thread,
                                          score: score,
                                          reason: reasons.joined(separator: " · ")))
        }
        return out.sorted {
            $0.score == $1.score ? $0.thread.lastDate > $1.thread.lastDate : $0.score > $1.score
        }.prefix(limit).map { $0 }
    }
}

// MARK: - Compose

@MainActor
public enum GmailCompose {
    public static func reply(thread: GmailThread, message: GmailMessage,
                             account: GmailAccount, all: Bool) -> GmailDraft {
        let own = account.email.lowercased()
        // A reply to something I sent goes to its recipients, not back to me.
        let base = message.from.email.lowercased() == own
            ? (message.to.isEmpty ? message.replyTo : message.to)
            : (message.replyTo.isEmpty ? [message.from] : message.replyTo)
        var recipients = base
        if all {
            recipients += message.to + message.cc
        }
        var seen = Set<String>()
        recipients = recipients.filter {
            let address = $0.email.lowercased()
            return address != own && !address.isEmpty && seen.insert(address).inserted
        }
        let subject = message.subject.lowercased().hasPrefix("re:")
            ? message.subject : "Re: \(message.subject)"
        let quote = message.bodyText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let text = "\n\nOn \(GmailFormat.fullDate(message.internalDate)), "
            + "\(message.from.displayName) wrote:\n\(quote)"
        let htmlQuote = """
            <br><br><blockquote style="margin:0 0 0 12px;padding-left:12px;border-left:2px solid #999;color:#555">
            <p>On \(GmailFormat.fullDate(message.internalDate)), \(escape(message.from.displayName)) wrote:</p>
            <p>\(escape(message.bodyText).replacingOccurrences(of: "\n", with: "<br>"))</p>
            </blockquote>
            """
        return GmailDraft(
            accountID: account.id, threadID: thread.id, to: recipients,
            subject: subject, bodyText: text, bodyHTML: "<p><br></p>" + htmlQuote,
            inReplyTo: message.rfcMessageID,
            references: message.references + [message.rfcMessageID].compactMap { $0 })
    }

    public static func new(account: GmailAccount, to: [GmailAddress],
                           subject: String, body: String = "") -> GmailDraft {
        GmailDraft(accountID: account.id, to: to, subject: subject,
                   bodyText: body, bodyHTML: body.isEmpty ? nil : "<p>\(escape(body))</p>")
    }

    public static func followUp(meeting: Meeting, source: GmailDataSource,
                                account: GmailAccount) -> GmailDraft {
        GmailMeetingBridge.followUpDraft(for: meeting, source: source, account: account)
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Meetings ↔ mail

@MainActor
public enum GmailMeetingBridge {

    public static func relatedThreads(for meeting: Meeting, source: GmailDataSource,
                                      accountID: UUID? = nil,
                                      limit: Int = 6) -> [GmailThreadSummary] {
        var tokens = meeting.participants
        tokens.append(contentsOf: emailTokens(in: meeting.summary))
        tokens.append(contentsOf: meeting.transcript.prefix(40).flatMap {
            emailTokens(in: $0.text)
        })
        return source.relatedThreads(participants: tokens, accountID: accountID,
                                     since: meeting.startedAt.addingTimeInterval(-90 * 86_400),
                                     limit: limit)
    }

    public static func relatedThreads(for scheduled: ScheduledMeeting,
                                      source: GmailDataSource, accountID: UUID? = nil,
                                      limit: Int = 6) -> [GmailThreadSummary] {
        source.relatedThreads(participants: scheduled.participants,
                              accountID: accountID,
                              since: scheduled.startsAt.addingTimeInterval(-120 * 86_400),
                              limit: limit)
    }

    public static func addresses(for names: [String], source: GmailDataSource,
                                 accountID: UUID? = nil) -> [GmailAddress] {
        let threads = source.relatedThreads(participants: names, accountID: accountID,
                                            since: nil, limit: 30)
        var out: [GmailAddress] = []
        var seen = Set<String>()
        for thread in threads {
            for address in thread.participants {
                let haystack = "\(address.name) \(address.email)".lowercased()
                guard names.contains(where: {
                    let needle = $0.trimmingCharacters(in: .whitespaces).lowercased()
                    return needle.count >= 2 && haystack.contains(needle)
                }) else { continue }
                if seen.insert(address.email.lowercased()).inserted {
                    out.append(address)
                }
            }
        }
        return out
    }

    /// A deterministic follow-up built from the stored summary, decisions and action
    /// items. No model is called and no email is sent.
    public static func followUpDraft(for meeting: Meeting,
                                     source: GmailDataSource,
                                     account: GmailAccount) -> GmailDraft {
        let recipients = addresses(for: meeting.participants, source: source,
                                   accountID: account.id)
        let subject = "Follow-up: \(meeting.title)"
        var lines: [String] = []
        lines.append("Hi\(meeting.participants.isEmpty ? "" : " team"),")
        lines.append("")
        if !meeting.summary.isEmpty {
            lines.append("Thanks for the conversation. Here is the short version:")
            lines.append(meeting.summary)
            lines.append("")
        }
        if !meeting.decisions.isEmpty {
            lines.append("Decisions")
            lines.append(contentsOf: meeting.decisions.map { "• \($0)" })
            lines.append("")
        }
        let open = meeting.actionItems.filter { $0.state != .dismissed }
        if !open.isEmpty {
            lines.append("Action items")
            for item in open {
                var line = "• \(item.title)"
                if let assignee = item.assignee, !assignee.isEmpty { line += " — \(assignee)" }
                if let due = item.dueDate { line += " (due \(GmailFormat.fullDate(due)))" }
                lines.append(line)
            }
            lines.append("")
        }
        lines.append("Reply here if anything should change.")
        lines.append("")
        lines.append(account.displayName.isEmpty ? account.email : account.displayName)
        let text = lines.joined(separator: "\n")

        var htmlLines: [String] = []
        htmlLines.append("<p>Hi\(meeting.participants.isEmpty ? "" : " team"),</p>")
        if !meeting.summary.isEmpty {
            htmlLines.append("<p>Thanks for the conversation. Here is the short version:</p>")
            htmlLines.append("<p>\(escape(meeting.summary))</p>")
        }
        if !meeting.decisions.isEmpty {
            htmlLines.append("<p><strong>Decisions</strong></p><ul>")
            htmlLines.append(contentsOf: meeting.decisions.map {
                "<li>\(escape($0))</li>"
            })
            htmlLines.append("</ul>")
        }
        if !open.isEmpty {
            htmlLines.append("<p><strong>Action items</strong></p><ul>")
            for item in open {
                var line = escape(item.title)
                if let assignee = item.assignee, !assignee.isEmpty {
                    line += " — \(escape(assignee))"
                }
                if let due = item.dueDate {
                    line += " (due \(GmailFormat.fullDate(due)))"
                }
                htmlLines.append("<li>\(line)</li>")
            }
            htmlLines.append("</ul>")
        }
        htmlLines.append("<p>Reply here if anything should change.</p>")
        htmlLines.append("<p>\(escape(account.displayName.isEmpty ? account.email : account.displayName))</p>")

        return GmailDraft(
            accountID: account.id, to: recipients, subject: subject,
            bodyText: text, bodyHTML: htmlLines.joined(separator: "\n"))
    }

    private static func emailTokens(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
            options: [.caseInsensitive]) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
