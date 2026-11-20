import Foundation

// MARK: - Account

/// One connected Gmail account. The refresh token is never stored here: it lives in
/// the Keychain, keyed by this row's id.
public struct GmailAccount: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var email: String
    public var displayName: String
    public var historyID: String?
    public var lastSyncAt: Date?
    public var syncError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), email: String, displayName: String = "",
                historyID: String? = nil, lastSyncAt: Date? = nil,
                syncError: String? = nil, createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.historyID = historyID
        self.lastSyncAt = lastSyncAt
        self.syncError = syncError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var label: String {
        displayName.isEmpty ? email : "\(displayName) · \(email)"
    }
}

// MARK: - Address

public struct GmailAddress: Hashable, Codable, Sendable {
    public var name: String
    public var email: String

    public init(name: String = "", email: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    public init(raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"),
           open < close {
            let name = value[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let address = value[value.index(after: open)..<close]
            self.init(name: Self.unquote(name), email: String(address))
        } else {
            self.init(name: "", email: value)
        }
    }

    public var displayName: String { name.isEmpty ? email : name }
    public var mailbox: String { name.isEmpty ? email : "\(name) <\(email)>" }

    /// Parses the comma-separated form Gmail puts in a header, respecting quoted
    /// display names and angle brackets.
    public static func parseList(_ raw: String) -> [GmailAddress] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var depth = 0
        for character in raw {
            switch character {
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<" where !inQuotes:
                depth += 1
                current.append(character)
            case ">" where !inQuotes:
                depth = max(0, depth - 1)
                current.append(character)
            case "," where !inQuotes && depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
            .map { GmailAddress(raw: $0) }
            .filter { !$0.email.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        var text = value
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text.removeFirst()
            text.removeLast()
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

// MARK: - Mailbox

/// The system views Gmail exposes, plus a synthetic ARCHIVE (everything that is
/// no longer in the inbox but is not sent, drafted, spam or trash).
public enum GmailMailbox: String, CaseIterable, Identifiable, Sendable {
    case inbox, starred, important, sent, drafts, archive, spam, trash, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inbox: return "INBOX"
        case .starred: return "STARRED"
        case .important: return "IMPORTANT"
        case .sent: return "SENT"
        case .drafts: return "DRAFTS"
        case .archive: return "ARCHIVE"
        case .spam: return "SPAM"
        case .trash: return "TRASH"
        case .all: return "ALL MAIL"
        }
    }

    /// The Gmail label this view needs, if it maps to one.
    public var labelID: String? {
        switch self {
        case .inbox: return "INBOX"
        case .starred: return "STARRED"
        case .important: return "IMPORTANT"
        case .sent: return "SENT"
        case .drafts: return "DRAFT"
        case .spam: return "SPAM"
        case .trash: return "TRASH"
        case .archive, .all: return nil
        }
    }

    public var icon: String {
        switch self {
        case .inbox: return "tray"
        case .starred: return "star"
        case .important: return "exclamationmark.circle"
        case .sent: return "paperplane"
        case .drafts: return "square.and.pencil"
        case .archive: return "archivebox"
        case .spam: return "exclamationmark.octagon"
        case .trash: return "trash"
        case .all: return "tray.full"
        }
    }
}

// MARK: - Label

public struct GmailLabel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var unreadCount: Int
    public var totalCount: Int
    public var colorText: String?
    public var colorBackground: String?

    public init(id: String, name: String, type: String = "user",
                unreadCount: Int = 0, totalCount: Int = 0,
                colorText: String? = nil, colorBackground: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.colorText = colorText
        self.colorBackground = colorBackground
    }

    public var isUserLabel: Bool { type == "user" }

    /// Gmail's automatic categories are noise in a personal sidebar.
    public var isCategory: Bool { id.hasPrefix("CATEGORY_") }
}

// MARK: - Attachment

public struct GmailAttachment: Identifiable, Hashable, Sendable {
    public var id: String
    public var messageID: String
    public var accountID: UUID
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool
    public var localPath: String?

    public init(id: String, messageID: String, accountID: UUID,
                filename: String, mimeType: String, size: Int = 0,
                contentID: String? = nil, isInline: Bool = false,
                localPath: String? = nil) {
        self.id = id
        self.messageID = messageID
        self.accountID = accountID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
        self.localPath = localPath
    }

    public var localURL: URL? { localPath.map { URL(fileURLWithPath: $0) } }
    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Message

public struct GmailMessage: Identifiable, Equatable, Sendable {
    public var id: String
    public var threadID: String
    public var accountID: UUID
    public var labelIDs: [String]
    public var historyID: String?
    public var internalDate: Date
    public var from: GmailAddress
    public var to: [GmailAddress]
    public var cc: [GmailAddress]
    public var bcc: [GmailAddress]
    public var replyTo: [GmailAddress]
    public var subject: String
    public var snippet: String
    public var bodyText: String
    public var bodyHTML: String?
    public var attachments: [GmailAttachment]
    public var sizeEstimate: Int
    public var isDraft: Bool
    public var rfcMessageID: String?
    public var references: [String]

    public init(id: String, threadID: String, accountID: UUID,
                labelIDs: [String] = [], historyID: String? = nil,
                internalDate: Date = Date(), from: GmailAddress = GmailAddress(email: ""),
                to: [GmailAddress] = [], cc: [GmailAddress] = [],
                bcc: [GmailAddress] = [], replyTo: [GmailAddress] = [],
                subject: String = "", snippet: String = "",
                bodyText: String = "", bodyHTML: String? = nil,
                attachments: [GmailAttachment] = [], sizeEstimate: Int = 0,
                isDraft: Bool = false, rfcMessageID: String? = nil,
                references: [String] = []) {
        self.id = id
        self.threadID = threadID
        self.accountID = accountID
        self.labelIDs = labelIDs
        self.historyID = historyID
        self.internalDate = internalDate
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.snippet = snippet
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.attachments = attachments
        self.sizeEstimate = sizeEstimate
        self.isDraft = isDraft
        self.rfcMessageID = rfcMessageID
        self.references = references
    }

    public var isUnread: Bool { labelIDs.contains("UNREAD") }
    public var isStarred: Bool { labelIDs.contains("STARRED") }
    public var isInInbox: Bool { labelIDs.contains("INBOX") }
    public var isImportant: Bool { labelIDs.contains("IMPORTANT") }
    public var hasAttachments: Bool { !attachments.isEmpty }
    public var dateLabel: String { GmailFormat.listDate(internalDate) }

    public var recipientSummary: String {
        let list = to.map(\.displayName)
        if list.isEmpty { return "" }
        return list.joined(separator: ", ")
    }
}

// MARK: - Thread

public struct GmailThreadSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var accountID: UUID
    public var subject: String
    public var snippet: String
    public var lastDate: Date
    public var messageCount: Int
    public var unreadCount: Int
    public var starred: Bool
    public var hasAttachments: Bool
    public var labelIDs: [String]
    public var participants: [GmailAddress]

    public init(id: String, accountID: UUID, subject: String = "",
                snippet: String = "", lastDate: Date = Date(),
                messageCount: Int = 0, unreadCount: Int = 0,
                starred: Bool = false, hasAttachments: Bool = false,
                labelIDs: [String] = [], participants: [GmailAddress] = []) {
        self.id = id
        self.accountID = accountID
        self.subject = subject
        self.snippet = snippet
        self.lastDate = lastDate
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.starred = starred
        self.hasAttachments = hasAttachments
        self.labelIDs = labelIDs
        self.participants = participants
    }

    public var isUnread: Bool { unreadCount > 0 }
    public var isInInbox: Bool { labelIDs.contains("INBOX") }
    public var isDraft: Bool { labelIDs.contains("DRAFT") }
    public var dateLabel: String { GmailFormat.listDate(lastDate) }
    public var senderDisplay: String {
        guard let first = participants.first else { return "Unknown sender" }
        return first.name.isEmpty ? first.email : first.name
    }

    /// The subject with the reply prefix stripped, so a thread does not turn into
    /// RE: RE: RE: over time.
    public var displaySubject: String {
        var text = subject
        let prefixes = ["re:", "fw:", "fwd:", "aw:", "sv:"]
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for prefix in prefixes where lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text.isEmpty ? "(no subject)" : text
    }
}

public struct GmailThread: Identifiable, Equatable, Sendable {
    public var summary: GmailThreadSummary
    public var messages: [GmailMessage]

    public var id: String { summary.id }
    public var accountID: UUID { summary.accountID }

    public init(summary: GmailThreadSummary, messages: [GmailMessage] = []) {
        self.summary = summary
        self.messages = messages
    }

    /// Oldest first, which is how a conversation reads.
    public var orderedMessages: [GmailMessage] {
        messages.sorted { $0.internalDate < $1.internalDate }
    }
}

// MARK: - Draft

public struct GmailDraftAttachment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var localPath: String
    public var isInline: Bool
    public var contentID: String?

    public init(id: UUID = UUID(), filename: String, mimeType: String,
                localPath: String, isInline: Bool = false,
                contentID: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.localPath = localPath
        self.isInline = isInline
        self.contentID = contentID
    }

    public var localURL: URL { URL(fileURLWithPath: localPath) }
    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

public enum GmailDraftStatus: String, Codable, Sendable {
    case local, dirty, queued, synced, sending, sent, failed
}

public struct GmailDraft: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var gmailDraftID: String?
    public var gmailMessageID: String?
    public var threadID: String?
    public var to: [GmailAddress]
    public var cc: [GmailAddress]
    public var bcc: [GmailAddress]
    public var subject: String
    public var bodyText: String
    public var bodyHTML: String?
    public var attachments: [GmailDraftAttachment]
    public var inReplyTo: String?
    public var references: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var status: GmailDraftStatus

    public init(id: UUID = UUID(), accountID: UUID, gmailDraftID: String? = nil,
                gmailMessageID: String? = nil, threadID: String? = nil,
                to: [GmailAddress] = [], cc: [GmailAddress] = [],
                bcc: [GmailAddress] = [], subject: String = "",
                bodyText: String = "", bodyHTML: String? = nil,
                attachments: [GmailDraftAttachment] = [], inReplyTo: String? = nil,
                references: [String] = [], createdAt: Date = Date(),
                updatedAt: Date = Date(), status: GmailDraftStatus = .local) {
        self.id = id
        self.accountID = accountID
        self.gmailDraftID = gmailDraftID
        self.gmailMessageID = gmailMessageID
        self.threadID = threadID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }

    public var recipientLine: String {
        let names = (to + cc + bcc).map(\.displayName)
        return names.isEmpty ? "No recipients" : names.joined(separator: ", ")
    }

    public var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty
            && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
    }
}

// MARK: - Counts / sync

public struct GmailCounts: Equatable, Sendable {
    public var inboxUnread: Int
    public var inboxTotal: Int
    public var drafts: Int
    public var starred: Int
    public var spam: Int
    public var trash: Int
    public var archive: Int

    public init(inboxUnread: Int = 0, inboxTotal: Int = 0, drafts: Int = 0,
                starred: Int = 0, spam: Int = 0, trash: Int = 0,
                archive: Int = 0) {
        self.inboxUnread = inboxUnread
        self.inboxTotal = inboxTotal
        self.drafts = drafts
        self.starred = starred
        self.spam = spam
        self.trash = trash
        self.archive = archive
    }

    public static let zero = GmailCounts()
}

public struct GmailSyncProgress: Equatable, Sendable {
    public var accountID: UUID
    public var phase: String
    public var completed: Int
    public var total: Int
    public var error: String?

    public init(accountID: UUID, phase: String, completed: Int = 0,
                total: Int = 0, error: String? = nil) {
        self.accountID = accountID
        self.phase = phase
        self.completed = completed
        self.total = total
        self.error = error
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

// MARK: - File names

public enum GmailFileName {
    /// A filename from a message is untrusted. Keep one component, remove traversal
    /// and reserved characters, and bound the length.
    public static func safe(_ raw: String, fallback: String = "attachment") -> String {
        var value = raw
            .replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/")
            .last ?? fallback
        value = value.replacingOccurrences(of: "..", with: "_")
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = fallback }
        return String(value.prefix(180))
    }
}

// MARK: - Formatting

public enum GmailFormat {
    public static func listDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "YESTERDAY" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return dayMonthFormatter.string(from: date).uppercased()
        }
        return shortDateFormatter.string(from: date).uppercased()
    }

    public static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    public static func line(_ date: Date) -> String {
        fullDateFormatter.string(from: date).uppercased()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yy"
        return f
    }()
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
