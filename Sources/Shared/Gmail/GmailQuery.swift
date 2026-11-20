import Foundation

/// A local Gmail-style query. The parser understands the operators people already
/// type in Gmail (`from:`, `is:unread`, `label:`) and maps them to SQLite; nothing
/// is forwarded to Google, so search works offline.
public struct GmailQuery: Equatable, Sendable {
    public var text: String
    public var from: String?
    public var to: String?
    public var subject: String?
    public var label: String?
    public var mailbox: GmailMailbox?
    public var unread: Bool?
    public var starred: Bool?
    public var hasAttachment: Bool?
    public var newerThan: Date?
    public var olderThan: Date?
    public var limit: Int
    /// FTS combines tokens with AND by default; the semantic fallback retries with OR.
    public var matchAllTokens: Bool

    public init(text: String = "", from: String? = nil, to: String? = nil,
                subject: String? = nil, label: String? = nil,
                mailbox: GmailMailbox? = nil, unread: Bool? = nil,
                starred: Bool? = nil, hasAttachment: Bool? = nil,
                newerThan: Date? = nil, olderThan: Date? = nil,
                limit: Int = 50, matchAllTokens: Bool = true) {
        self.text = text
        self.from = from
        self.to = to
        self.subject = subject
        self.label = label
        self.mailbox = mailbox
        self.unread = unread
        self.starred = starred
        self.hasAttachment = hasAttachment
        self.newerThan = newerThan
        self.olderThan = olderThan
        self.limit = limit
        self.matchAllTokens = matchAllTokens
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && from == nil && to == nil && subject == nil && label == nil
            && mailbox == nil && unread == nil && starred == nil
            && hasAttachment == nil && newerThan == nil && olderThan == nil
    }

    /// True when this looks like a natural-language question rather than a keyword
    /// search. The agent uses it to prefer semantic ranking.
    public var isNaturalLanguage: Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count >= 3 && !text.contains(":")
    }

    public static func parse(_ raw: String, now: Date = Date()) -> GmailQuery {
        var query = GmailQuery()
        var free: [String] = []
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in raw {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        for token in tokens {
            let lower = token.lowercased()
            func value(after prefix: String) -> String? {
                guard lower.hasPrefix(prefix) else { return nil }
                var result = String(token.dropFirst(prefix.count))
                if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
                    result.removeFirst(); result.removeLast()
                }
                return result.isEmpty ? nil : result
            }
            if let value = value(after: "from:") { query.from = value; continue }
            if let value = value(after: "to:") { query.to = value; continue }
            if let value = value(after: "subject:") { query.subject = value; continue }
            if let value = value(after: "label:") { query.label = value; continue }
            if let value = value(after: "in:") {
                query.mailbox = GmailMailbox(rawValue: value.lowercased())
                    ?? (value.lowercased() == "anywhere" ? nil : query.mailbox)
                continue
            }
            if let value = value(after: "is:") {
                switch value.lowercased() {
                case "unread": query.unread = true
                case "read": query.unread = false
                case "starred": query.starred = true
                case "unstarred": query.starred = false
                case "important": query.label = "IMPORTANT"
                default: break
                }
                continue
            }
            if value(after: "has:")?.lowercased() == "attachment" {
                query.hasAttachment = true
                continue
            }
            if let value = value(after: "newer_than:") {
                query.newerThan = parseWindow(value, now: now)
                continue
            }
            if let value = value(after: "older_than:") {
                query.olderThan = parseWindow(value, now: now)
                continue
            }
            if let value = value(after: "after:") {
                query.newerThan = DateInput.parse(value, now: now)
                continue
            }
            if let value = value(after: "before:") {
                query.olderThan = DateInput.parse(value, now: now)
                continue
            }
            var plain = token
            if plain.hasPrefix("\""), plain.hasSuffix("\""), plain.count >= 2 {
                plain.removeFirst(); plain.removeLast()
            }
            free.append(plain)
        }
        query.text = free.joined(separator: " ")
        return query
    }

    private static func parseWindow(_ raw: String, now: Date) -> Date? {
        let value = raw.lowercased()
        guard let amount = Int(value.dropLast()), amount > 0,
              let unit = value.last else { return nil }
        let calendar = Calendar.current
        switch unit {
        case "d": return calendar.date(byAdding: .day, value: -amount, to: now)
        case "w": return calendar.date(byAdding: .day, value: -7 * amount, to: now)
        case "m": return calendar.date(byAdding: .month, value: -amount, to: now)
        case "y": return calendar.date(byAdding: .year, value: -amount, to: now)
        default: return nil
        }
    }
}

/// Translates free text into an FTS5 MATCH expression that cannot be interpreted as
/// an operator. Every token is quoted; the last token gets a prefix wildcard so
/// "pric" still finds "pricing".
public enum GmailSearchSQL {
    public static func matchExpression(_ raw: String, allTokens: Bool = true) -> String? {
        let tokens = raw
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return nil }
        var seen = Set<String>()
        let unique = tokens.filter { seen.insert($0).inserted }
        return unique.enumerated().map { index, token in
            let quoted = "\"\(token.replacingOccurrences(of: "\"", with: ""))\""
            return index == unique.count - 1 ? quoted + "*" : quoted
        }.joined(separator: allTokens ? " AND " : " OR ")
    }

}
