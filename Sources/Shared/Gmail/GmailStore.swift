import Foundation
import Observation

/// The Gmail cache. Every read and write goes through SQLite on this Mac; there is
/// no Work Console server involved anywhere in this file.
@Observable
@MainActor
public final class GmailStore {

    public private(set) var accounts: [GmailAccount] = []
    public private(set) var lastError: String?
    /// Bumped after every local mutation so SwiftUI readers that compute counts
    /// from SQL re-render when a sync lands.
    public private(set) var revision: Int = 0
    /// AES-GCM key wrapper for drafts and attachment files. Lazy, so constructing
    /// the store does not touch the Keychain before a window exists.
    public let crypto: GmailCrypto
    /// Set when FileVault is off/unknown. Every read path returns empty and every
    /// write path refuses, so cached plaintext message rows are not exposed.
    public var isSecurityLocked = false
    public private(set) var encryptionError: String?

    @ObservationIgnored private var db: SQLiteDatabase?

    public init(url: URL? = nil, ephemeral: Bool = false, crypto: GmailCrypto? = nil) {
        self.crypto = crypto ?? (ephemeral ? GmailCrypto.ephemeral() : GmailCrypto.live())
        let path: String
        if ephemeral {
            path = ":memory:"
        } else {
            KanbanPaths.ensureSupportDirectory()
            path = (url ?? KanbanPaths.databaseURL).path
        }
        do {
            let database = try SQLiteDatabase(path: path)
            try Schema.migrate(database)
            db = database
            accounts = try loadAccounts()
        } catch {
            lastError = "\(error)"
            db = nil
        }
    }

    // MARK: - Accounts

    public func account(_ id: UUID) -> GmailAccount? {
        accounts.first { $0.id == id }
    }

    public func account(email: String) -> GmailAccount? {
        accounts.first { $0.email.lowercased() == email.lowercased() }
    }

    @discardableResult
    public func upsertAccount(_ account: GmailAccount) -> GmailAccount {
        var value = account
        value.updatedAt = Date()
        if let index = accounts.firstIndex(where: { $0.id == value.id }) {
            accounts[index] = value
        } else {
            accounts.append(value)
            accounts.sort { $0.createdAt < $1.createdAt }
        }
        write { db in
            try db.run("""
                INSERT INTO gmail_accounts
                    (id, email, display_name, history_id, last_sync, sync_error, created, updated)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    email = excluded.email,
                    display_name = excluded.display_name,
                    history_id = excluded.history_id,
                    last_sync = excluded.last_sync,
                    sync_error = excluded.sync_error,
                    updated = excluded.updated;
                """,
                [.text(value.id.uuidString), .text(value.email),
                 .text(value.displayName), value.historyID.map { .text($0) } ?? .null,
                 .date(value.lastSyncAt), value.syncError.map { .text($0) } ?? .null,
                 .double(value.createdAt.timeIntervalSince1970),
                 .double(value.updatedAt.timeIntervalSince1970)])
        }
        return value
    }

    public func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        write { db in
            try db.run("DELETE FROM gmail_fts WHERE account_id = ?;", [.text(id.uuidString)])
            try db.run("DELETE FROM gmail_accounts WHERE id = ?;", [.text(id.uuidString)])
        }
    }

    public func setHistory(_ id: UUID, historyID: String?, error: String? = nil,
                           syncedAt: Date? = nil) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let historyID { accounts[index].historyID = historyID }
        if let syncedAt { accounts[index].lastSyncAt = syncedAt }
        accounts[index].syncError = error
        accounts[index].updatedAt = Date()
        let account = accounts[index]
        write { db in
            try db.run("""
                UPDATE gmail_accounts SET history_id = ?, last_sync = ?, sync_error = ?,
                                          updated = ? WHERE id = ?;
                """,
                [account.historyID.map { .text($0) } ?? .null,
                 .date(account.lastSyncAt),
                 error.map { .text($0) } ?? .null,
                 .double(account.updatedAt.timeIntervalSince1970),
                 .text(id.uuidString)])
        }
    }

    public func setSyncError(_ id: UUID, _ message: String?) {
        setHistory(id, historyID: nil, error: message)
    }

    private func loadAccounts() throws -> [GmailAccount] {
        guard let db else { return [] }
        var out: [GmailAccount] = []
        try db.query("""
            SELECT id, email, display_name, history_id, last_sync, sync_error, created, updated
            FROM gmail_accounts ORDER BY created;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            out.append(GmailAccount(
                id: id, email: row.string(1), displayName: row.string(2),
                historyID: row.stringOrNil(3), lastSyncAt: row.doubleOrNil(4).map(Date.init(timeIntervalSince1970:)),
                syncError: row.stringOrNil(5),
                createdAt: Date(timeIntervalSince1970: row.double(6)),
                updatedAt: Date(timeIntervalSince1970: row.double(7))))
        }
        return out
    }

    // MARK: - Labels

    public func labels(accountID: UUID) -> [GmailLabel] {
        guard !isSecurityLocked, let db else { return [] }
        var out: [GmailLabel] = []
        try? db.query("""
            SELECT id, name, type, unread, total, color_text, color_bg
            FROM gmail_labels WHERE account_id = ?
            ORDER BY CASE type WHEN 'system' THEN 0 ELSE 1 END, name COLLATE NOCASE;
            """, [.text(accountID.uuidString)]) { row in
            out.append(GmailLabel(
                id: row.string(0), name: row.string(1), type: row.string(2),
                unreadCount: Int(row.int(3)), totalCount: Int(row.int(4)),
                colorText: row.stringOrNil(5), colorBackground: row.stringOrNil(6)))
        }
        return out
    }

    public func replaceLabels(_ labels: [GmailLabel], accountID: UUID) {
        write { db in
            try db.transaction {
                try db.run("DELETE FROM gmail_labels WHERE account_id = ?;",
                           [.text(accountID.uuidString)])
                for label in labels {
                    try db.run("""
                        INSERT INTO gmail_labels
                            (account_id, id, name, type, unread, total, color_text, color_bg)
                        VALUES (?,?,?,?,?,?,?,?);
                        """,
                        [.text(accountID.uuidString), .text(label.id), .text(label.name),
                         .text(label.type), .int(Int64(label.unreadCount)),
                         .int(Int64(label.totalCount)),
                         label.colorText.map { .text($0) } ?? .null,
                         label.colorBackground.map { .text($0) } ?? .null])
                }
            }
        }
    }

    public func label(named name: String, accountID: UUID) -> GmailLabel? {
        labels(accountID: accountID).first {
            $0.id.caseInsensitiveCompare(name) == .orderedSame
                || $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    // MARK: - Threads

    public func threads(accountID: UUID?, query: GmailQuery = GmailQuery(),
                        limit: Int = 50, offset: Int = 0) -> [GmailThreadSummary] {
        guard !isSecurityLocked else { return [] }
        _ = revision
        guard let db else { return [] }
        var sql = """
            SELECT t.account_id, t.id, t.subject, t.snippet, t.last_date,
                   t.message_count, t.unread_count, t.starred, t.has_attachments,
                   t.labels, t.participants
            FROM gmail_threads t
            WHERE 1 = 1
            """
        var binds: [SQLiteDatabase.Value] = []

        if let accountID {
            sql += " AND t.account_id = ?"
            binds.append(.text(accountID.uuidString))
        }

        let mailbox = query.mailbox
        if let mailbox {
            switch mailbox {
            case .inbox:
                sql += " AND EXISTS (SELECT 1 FROM gmail_thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id AND l.label_id = 'INBOX')"
            case .starred:
                sql += " AND t.starred = 1"
            case .important:
                sql += " AND EXISTS (SELECT 1 FROM gmail_thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id AND l.label_id = 'IMPORTANT')"
            case .sent:
                sql += " AND EXISTS (SELECT 1 FROM gmail_thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id AND l.label_id = 'SENT')"
            case .drafts:
                sql += " AND (EXISTS (SELECT 1 FROM gmail_thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id AND l.label_id = 'DRAFT') OR EXISTS (SELECT 1 FROM gmail_drafts d WHERE d.account_id = t.account_id AND d.thread_id = t.id AND d.status != 'sent'))"
            case .archive:
                sql += """
                 AND NOT EXISTS (SELECT 1 FROM gmail_thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id AND l.label_id IN ('INBOX','SENT','DRAFT','SPAM','TRASH'))
                """
            case .spam:
                sql += " AND EXISTS (SELECT 1 FROM gmail_thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id AND l.label_id = 'SPAM')"
            case .trash:
                sql += " AND EXISTS (SELECT 1 FROM gmail_thread_labels l WHERE l.account_id = t.account_id AND l.thread_id = t.id AND l.label_id = 'TRASH')"
            case .all:
                break
            }
        }

        if let label = query.label, !label.isEmpty {
            sql += """
             AND EXISTS (
                SELECT 1 FROM gmail_thread_labels l
                JOIN gmail_labels lb ON lb.account_id = l.account_id AND lb.id = l.label_id
                WHERE l.account_id = t.account_id AND l.thread_id = t.id
                  AND (l.label_id = ? OR lb.name = ? COLLATE NOCASE))
            """
            binds.append(.text(label)); binds.append(.text(label))
        }

        if let unread = query.unread {
            sql += unread ? " AND t.unread_count > 0" : " AND t.unread_count = 0"
        }
        if let starred = query.starred {
            sql += starred ? " AND t.starred = 1" : " AND t.starred = 0"
        }
        if query.hasAttachment == true { sql += " AND t.has_attachments = 1" }
        if let newer = query.newerThan {
            sql += " AND t.last_date >= ?"
            binds.append(.double(newer.timeIntervalSince1970))
        }
        if let older = query.olderThan {
            sql += " AND t.last_date <= ?"
            binds.append(.double(older.timeIntervalSince1970))
        }

        appendAddressFilter("from", value: query.from, column: "from_name", second: "from_email",
                            sql: &sql, binds: &binds)
        appendAddressFilter("recipient", value: query.to, column: "to_json", second: "cc_json",
                            sql: &sql, binds: &binds)
        if let subject = query.subject, !subject.isEmpty {
            sql += " AND EXISTS (SELECT 1 FROM gmail_messages m WHERE m.account_id = t.account_id AND m.thread_id = t.id AND m.subject LIKE ? ESCAPE '\\')"
            binds.append(.text(Self.like(subject)))
        }

        if let match = GmailSearchSQL.matchExpression(query.text,
                                                      allTokens: query.matchAllTokens) {
            sql += """
             AND EXISTS (
                SELECT 1 FROM gmail_fts f
                JOIN gmail_messages m ON m.account_id = f.account_id AND m.id = f.message_id
                WHERE f.account_id = t.account_id AND m.thread_id = t.id
                  AND gmail_fts MATCH ?)
            """
            binds.append(.text(match))
        }

        sql += " ORDER BY t.last_date DESC LIMIT ? OFFSET ?"
        binds.append(.int(Int64(max(1, limit))))
        binds.append(.int(Int64(max(0, offset))))

        var out: [GmailThreadSummary] = []
        do {
            try db.query(sql, binds) { row in
                guard let account = UUID(uuidString: row.string(0)) else { return }
                out.append(decodeThreadSummary(row, accountID: account))
            }
        } catch {
            lastError = "\(error)"
        }
        return out
    }

    public func recentThreads(accountID: UUID?, limit: Int = 30) -> [GmailThreadSummary] {
        threads(accountID: accountID, query: GmailQuery(), limit: limit)
    }

    public func thread(accountID: UUID, threadID: String) -> GmailThread? {
        guard !isSecurityLocked else { return nil }
        _ = revision
        guard let db else { return nil }
        var summary: GmailThreadSummary?
        try? db.query("""
            SELECT account_id, id, subject, snippet, last_date, message_count,
                   unread_count, starred, has_attachments, labels, participants
            FROM gmail_threads WHERE account_id = ? AND id = ?;
            """, [.text(accountID.uuidString), .text(threadID)]) { row in
            summary = decodeThreadSummary(row, accountID: accountID)
        }
        guard let summary else { return nil }
        return GmailThread(summary: summary, messages: messages(accountID: accountID, threadID: threadID))
    }

    public func messages(accountID: UUID, threadID: String) -> [GmailMessage] {
        guard !isSecurityLocked, let db else { return [] }
        var out: [GmailMessage] = []
        try? db.query("""
            SELECT id, thread_id, label_ids, history_id, internal_date, from_name, from_email,
                   to_json, cc_json, bcc_json, reply_to_json, subject, snippet,
                   body_text, body_html, size_estimate, is_draft, rfc_message_id,
                   references_json
            FROM gmail_messages
            WHERE account_id = ? AND thread_id = ?
            ORDER BY internal_date ASC;
            """, [.text(accountID.uuidString), .text(threadID)]) { row in
            var message = decodeMessage(row, accountID: accountID)
            message.attachments = attachments(accountID: accountID, messageID: message.id)
            out.append(message)
        }
        return out
    }

    public func message(accountID: UUID, messageID: String) -> GmailMessage? {
        guard !isSecurityLocked, let db else { return nil }
        var out: GmailMessage?
        try? db.query("""
            SELECT id, thread_id, label_ids, history_id, internal_date, from_name, from_email,
                   to_json, cc_json, bcc_json, reply_to_json, subject, snippet,
                   body_text, body_html, size_estimate, is_draft, rfc_message_id,
                   references_json
            FROM gmail_messages WHERE account_id = ? AND id = ?;
            """, [.text(accountID.uuidString), .text(messageID)]) { row in
            var message = decodeMessage(row, accountID: accountID)
            message.attachments = attachments(accountID: accountID, messageID: messageID)
            out = message
        }
        return out
    }

    public func attachments(accountID: UUID, messageID: String) -> [GmailAttachment] {
        guard !isSecurityLocked, let db else { return [] }
        var out: [GmailAttachment] = []
        try? db.query("""
            SELECT id, filename, mime_type, size, content_id, is_inline, local_path
            FROM gmail_attachments WHERE account_id = ? AND message_id = ?
            ORDER BY rowid;
            """, [.text(accountID.uuidString), .text(messageID)]) { row in
            out.append(GmailAttachment(
                id: row.string(0), messageID: messageID, accountID: accountID,
                filename: row.string(1), mimeType: row.string(2),
                size: Int(row.int(3)), contentID: row.stringOrNil(4),
                isInline: row.int(5) != 0, localPath: row.stringOrNil(6)))
        }
        return out
    }


    // MARK: - Counts

    public func counts(accountID: UUID?) -> GmailCounts {
        guard !isSecurityLocked else { return .zero }
        _ = revision
        var counts = GmailCounts()
        counts.inboxTotal = countThreads(mailbox: .inbox, accountID: accountID)
        counts.inboxUnread = countUnreadInbox(accountID: accountID)
        counts.drafts = countThreads(mailbox: .drafts, accountID: accountID)
        counts.starred = countThreads(mailbox: .starred, accountID: accountID)
        counts.spam = countThreads(mailbox: .spam, accountID: accountID)
        counts.trash = countThreads(mailbox: .trash, accountID: accountID)
        counts.archive = countThreads(mailbox: .archive, accountID: accountID)
        return counts
    }

    public func countThreads(mailbox: GmailMailbox, accountID: UUID?) -> Int {
        threads(accountID: accountID,
                query: GmailQuery(mailbox: mailbox), limit: 1_000_000, offset: 0).count
    }

    private func countUnreadInbox(accountID: UUID?) -> Int {
        guard let db else { return 0 }
        var sql = """
            SELECT COALESCE(SUM(t.unread_count), 0) FROM gmail_threads t
            WHERE EXISTS (SELECT 1 FROM gmail_thread_labels l
                          WHERE l.account_id = t.account_id AND l.thread_id = t.id
                            AND l.label_id = 'INBOX')
            """
        var binds: [SQLiteDatabase.Value] = []
        if let accountID {
            sql += " AND t.account_id = ?"
            binds.append(.text(accountID.uuidString))
        }
        var value = 0
        try? db.query(sql, binds) { value = Int($0.int(0)) }
        return value
    }

    // MARK: - Cache writes

    /// Inserts a fully fetched thread and removes any local messages the server no
    /// longer has. Used by both full sync and opening a thread.
    public func cacheThread(_ thread: GmailThread) {
        guard !isSecurityLocked else { return }
        let accountID = thread.accountID
        write { db in
            try db.transaction {
                try ensureThreadRow(thread.id, accountID: accountID, in: db)
                var kept: [String] = []
                for message in thread.messages {
                    try Self.upsertMessage(message, in: db)
                    kept.append(message.id)
                }
                if kept.isEmpty {
                    try db.run("""
                        DELETE FROM gmail_fts WHERE account_id = ? AND message_id IN
                        (SELECT id FROM gmail_messages WHERE account_id = ? AND thread_id = ?);
                        """, [.text(accountID.uuidString), .text(accountID.uuidString),
                              .text(thread.id)])
                    try db.run("DELETE FROM gmail_messages WHERE account_id = ? AND thread_id = ?;",
                               [.text(accountID.uuidString), .text(thread.id)])
                } else {
                    let placeholders = kept.map { _ in "?" }.joined(separator: ",")
                    var staleBinds: [SQLiteDatabase.Value] = [.text(accountID.uuidString), .text(thread.id)]
                    staleBinds.append(contentsOf: kept.map { .text($0) })
                    try db.run("""
                        DELETE FROM gmail_fts WHERE account_id = ? AND message_id IN
                        (SELECT id FROM gmail_messages WHERE account_id = ? AND thread_id = ?
                         AND id NOT IN (\(placeholders)));
                        """,
                        [.text(accountID.uuidString), .text(accountID.uuidString),
                         .text(thread.id)] + kept.map { .text($0) })
                    var binds: [SQLiteDatabase.Value] = [.text(accountID.uuidString), .text(thread.id)]
                    binds.append(contentsOf: kept.map { .text($0) })
                    try db.run("""
                        DELETE FROM gmail_messages
                        WHERE account_id = ? AND thread_id = ? AND id NOT IN (\(placeholders));
                        """, binds)
                }
                try recomputeThread(thread.id, accountID: accountID, in: db)
            }
        }
    }

    /// Upserts one message (incremental history). The thread is recomputed from the
    /// messages we already have, which is what keeps labels and snippets correct
    /// without fetching the whole conversation again.
    public func cacheMessage(_ message: GmailMessage) {
        guard !isSecurityLocked else { return }
        write { db in
            try db.transaction {
                try ensureThreadRow(message.threadID, accountID: message.accountID, in: db)
                try Self.upsertMessage(message, in: db)
                try recomputeThread(message.threadID, accountID: message.accountID, in: db)
            }
        }
    }

    public func removeMessage(accountID: UUID, messageID: String) {
        guard let db else { return }
        var threadID: String?
        try? db.query("SELECT thread_id FROM gmail_messages WHERE account_id = ? AND id = ?;",
                      [.text(accountID.uuidString), .text(messageID)]) { threadID = $0.string(0) }
        write { db in
            try db.transaction {
                try db.run("DELETE FROM gmail_fts WHERE account_id = ? AND message_id = ?;",
                           [.text(accountID.uuidString), .text(messageID)])
                try db.run("DELETE FROM gmail_messages WHERE account_id = ? AND id = ?;",
                           [.text(accountID.uuidString), .text(messageID)])
                if let threadID {
                    var remaining = 0
                    try db.query("SELECT COUNT(*) FROM gmail_messages WHERE account_id = ? AND thread_id = ?;",
                                 [.text(accountID.uuidString), .text(threadID)]) { remaining = Int($0.int(0)) }
                    if remaining == 0 {
                        try db.run("DELETE FROM gmail_threads WHERE account_id = ? AND id = ?;",
                                   [.text(accountID.uuidString), .text(threadID)])
                        try db.run("DELETE FROM gmail_drafts WHERE account_id = ? AND thread_id = ?;",
                                   [.text(accountID.uuidString), .text(threadID)])
                    } else {
                        try recomputeThread(threadID, accountID: accountID, in: db)
                    }
                }
            }
        }
    }

    public func removeThread(accountID: UUID, threadID: String) {
        write { db in
            try db.transaction {
                try db.run("""
                    DELETE FROM gmail_fts WHERE account_id = ? AND message_id IN
                    (SELECT id FROM gmail_messages WHERE account_id = ? AND thread_id = ?);
                    """, [.text(accountID.uuidString), .text(accountID.uuidString), .text(threadID)])
                try db.run("DELETE FROM gmail_embeddings WHERE account_id = ? AND message_id IN (SELECT id FROM gmail_messages WHERE account_id = ? AND thread_id = ?);",
                           [.text(accountID.uuidString), .text(accountID.uuidString), .text(threadID)])
                try db.run("DELETE FROM gmail_threads WHERE account_id = ? AND id = ?;",
                           [.text(accountID.uuidString), .text(threadID)])
                try db.run("DELETE FROM gmail_drafts WHERE account_id = ? AND thread_id = ?;",
                           [.text(accountID.uuidString), .text(threadID)])
            }
        }
    }

    private func ensureThreadRow(_ threadID: String, accountID: UUID,
                                 in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO gmail_threads (account_id, id, subject, snippet, last_date,
                                       message_count, unread_count, starred,
                                       has_attachments, labels, participants)
            VALUES (?,?,?,'',?,0,0,0,0,'[]','[]')
            ON CONFLICT(account_id, id) DO NOTHING;
            """, [.text(accountID.uuidString), .text(threadID), .text(""),
                  .double(Date().timeIntervalSince1970)])
    }

    private func recomputeThread(_ threadID: String, accountID: UUID,
                                 in db: SQLiteDatabase) throws {
        var messages: [(id: String, date: Date, subject: String, snippet: String,
                        from: GmailAddress, recipients: [GmailAddress],
                        labels: [String], unread: Bool, starred: Bool, attachment: Bool)] = []
        try db.query("""
            SELECT id, internal_date, subject, snippet, from_name, from_email,
                   to_json, cc_json, label_ids, is_unread, is_starred
            FROM gmail_messages WHERE account_id = ? AND thread_id = ?
            ORDER BY internal_date DESC;
            """, [.text(accountID.uuidString), .text(threadID)]) { row in
            messages.append((
                row.string(0), Date(timeIntervalSince1970: row.double(1)),
                row.string(2), row.string(3),
                GmailAddress(name: row.string(4), email: row.string(5)),
                (Self.decodeAddresses(row.string(6)) + Self.decodeAddresses(row.string(7))),
                Self.decodeStrings(row.string(8)),
                row.int(9) != 0, row.int(10) != 0,
                Self.attachmentCount(accountID: accountID, messageID: row.string(0), db: db) > 0))
        }
        guard let latest = messages.first else {
            try db.run("DELETE FROM gmail_threads WHERE account_id = ? AND id = ?;",
                       [.text(accountID.uuidString), .text(threadID)])
            return
        }
        var labels = Set<String>()
        for message in messages { labels.formUnion(message.labels) }
        var participants: [GmailAddress] = []
        var seen = Set<String>()
        for message in messages {
            for address in [message.from] + message.recipients
            where !address.email.isEmpty && seen.insert(address.email.lowercased()).inserted {
                participants.append(address)
            }
        }
        let unread = messages.filter(\.unread).count
        let starred = messages.contains(where: \.starred)
        let hasAttachments = messages.contains(where: \.attachment)
        let snippet = latest.snippet.isEmpty
            ? String(latest.subject.prefix(160))
            : latest.snippet
        let labelsJSON = Self.encodeStrings(Array(labels).sorted())
        let participantsJSON = Self.encodeAddresses(participants)

        try db.run("""
            UPDATE gmail_threads SET subject = ?, snippet = ?, last_date = ?,
                message_count = ?, unread_count = ?, starred = ?, has_attachments = ?,
                labels = ?, participants = ?
            WHERE account_id = ? AND id = ?;
            """,
            [.text(latest.subject), .text(snippet),
             .double(latest.date.timeIntervalSince1970), .int(Int64(messages.count)),
             .int(Int64(unread)), .int(starred ? 1 : 0), .int(hasAttachments ? 1 : 0),
             .text(labelsJSON), .text(participantsJSON),
             .text(accountID.uuidString), .text(threadID)])

        try db.run("DELETE FROM gmail_thread_labels WHERE account_id = ? AND thread_id = ?;",
                   [.text(accountID.uuidString), .text(threadID)])
        for label in labels {
            try db.run("""
                INSERT OR IGNORE INTO gmail_thread_labels (account_id, thread_id, label_id)
                VALUES (?,?,?);
                """, [.text(accountID.uuidString), .text(threadID), .text(label)])
        }
    }

    private static func upsertMessage(_ message: GmailMessage,
                                      in db: SQLiteDatabase) throws {
        let account = message.accountID.uuidString
        try db.run("""
            INSERT INTO gmail_messages
                (account_id, id, thread_id, history_id, internal_date, from_name, from_email,
                 to_json, cc_json, bcc_json, reply_to_json, subject, snippet, body_text,
                 body_html, size_estimate, is_draft, is_unread, is_starred, label_ids,
                 rfc_message_id, references_json)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account_id, id) DO UPDATE SET
                thread_id = excluded.thread_id,
                history_id = excluded.history_id,
                internal_date = excluded.internal_date,
                from_name = excluded.from_name,
                from_email = excluded.from_email,
                to_json = excluded.to_json,
                cc_json = excluded.cc_json,
                bcc_json = excluded.bcc_json,
                reply_to_json = excluded.reply_to_json,
                subject = excluded.subject,
                snippet = excluded.snippet,
                body_text = excluded.body_text,
                body_html = excluded.body_html,
                size_estimate = excluded.size_estimate,
                is_draft = excluded.is_draft,
                is_unread = excluded.is_unread,
                is_starred = excluded.is_starred,
                label_ids = excluded.label_ids,
                rfc_message_id = excluded.rfc_message_id,
                references_json = excluded.references_json;
            """,
            [.text(account), .text(message.id), .text(message.threadID),
             message.historyID.map { .text($0) } ?? .null,
             .double(message.internalDate.timeIntervalSince1970),
             .text(message.from.name), .text(message.from.email),
             .text(encodeAddresses(message.to)), .text(encodeAddresses(message.cc)),
             .text(encodeAddresses(message.bcc)), .text(encodeAddresses(message.replyTo)),
             .text(message.subject), .text(message.snippet), .text(message.bodyText),
             message.bodyHTML.map { .text($0) } ?? .null,
             .int(Int64(message.sizeEstimate)), .int(message.isDraft ? 1 : 0),
             .int(message.isUnread ? 1 : 0), .int(message.isStarred ? 1 : 0),
             .text(encodeStrings(message.labelIDs)),
             message.rfcMessageID.map { .text($0) } ?? .null,
             .text(encodeStrings(message.references))])

        // Attachments keep any file already downloaded.
        let ids = message.attachments.map(\.id)
        for attachment in message.attachments {
            try db.run("""
                INSERT INTO gmail_attachments
                    (account_id, message_id, id, filename, mime_type, size, content_id,
                     is_inline, local_path)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(account_id, message_id, id) DO UPDATE SET
                    filename = excluded.filename,
                    mime_type = excluded.mime_type,
                    size = excluded.size,
                    content_id = excluded.content_id,
                    is_inline = excluded.is_inline;
                """,
                [.text(account), .text(message.id), .text(attachment.id),
                 .text(attachment.filename), .text(attachment.mimeType),
                 .int(Int64(attachment.size)),
                 attachment.contentID.map { .text($0) } ?? .null,
                 .int(attachment.isInline ? 1 : 0),
                 attachment.localPath.map { .text($0) } ?? .null])
        }
        if ids.isEmpty {
            try db.run("DELETE FROM gmail_attachments WHERE account_id = ? AND message_id = ?;",
                       [.text(account), .text(message.id)])
        } else {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            var binds: [SQLiteDatabase.Value] = [.text(account), .text(message.id)]
            binds.append(contentsOf: ids.map { .text($0) })
            try db.run("""
                DELETE FROM gmail_attachments
                WHERE account_id = ? AND message_id = ? AND id NOT IN (\(placeholders));
                """, binds)
        }

        try db.run("DELETE FROM gmail_fts WHERE account_id = ? AND message_id = ?;",
                   [.text(account), .text(message.id)])
        try db.run("""
            INSERT INTO gmail_fts (message_id, account_id, subject, sender, recipients, body)
            VALUES (?,?,?,?,?,?);
            """,
            [.text(message.id), .text(account), .text(message.subject),
             .text("\(message.from.name) \(message.from.email)"),
             .text((message.to + message.cc + message.bcc).map(\.mailbox).joined(separator: " ")),
             .text(message.bodyText)])
    }

    // MARK: - Attachments

    public func attachment(accountID: UUID, messageID: String, id: String) -> GmailAttachment? {
        guard let db else { return nil }
        var out: GmailAttachment?
        try? db.query("""
            SELECT id, message_id, filename, mime_type, size, content_id, is_inline, local_path
            FROM gmail_attachments WHERE account_id = ? AND message_id = ? AND id = ?;
            """, [.text(accountID.uuidString), .text(messageID), .text(id)]) { row in
            out = GmailAttachment(
                id: row.string(0), messageID: row.string(1), accountID: accountID,
                filename: row.string(2), mimeType: row.string(3),
                size: Int(row.int(4)), contentID: row.stringOrNil(5),
                isInline: row.int(6) != 0, localPath: row.stringOrNil(7))
        }
        return out
    }

    public func setAttachmentPath(accountID: UUID, messageID: String, id: String,
                                  path: String?) {
        write { db in
            try db.run("""
                UPDATE gmail_attachments SET local_path = ?
                WHERE account_id = ? AND message_id = ? AND id = ?;
                """, [path.map { .text($0) } ?? .null, .text(accountID.uuidString),
                      .text(messageID), .text(id)])
        }
    }

    public func attachmentDirectory(accountID: UUID) -> URL {
        let url = KanbanPaths.ensureSupportDirectory()
            .appendingPathComponent("Gmail", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: url.path)
        return url
    }

    public func removeAttachmentFiles(accountID: UUID) {
        try? FileManager.default.removeItem(at: attachmentDirectory(accountID: accountID))
    }

    // MARK: - Drafts

    public func drafts(accountID: UUID?) -> [GmailDraft] {
        guard !isSecurityLocked, let db else { return [] }
        var sql = """
            SELECT id, account_id, gmail_draft_id, gmail_message_id, thread_id,
                   to_json, cc_json, bcc_json, subject, body_text, body_html,
                   attachments_json, in_reply_to, references_json, created, updated, status
            FROM gmail_drafts
            """
        var binds: [SQLiteDatabase.Value] = []
        if let accountID {
            sql += " WHERE account_id = ?"
            binds.append(.text(accountID.uuidString))
        }
        sql += " ORDER BY updated DESC;"
        var out: [GmailDraft] = []
        try? db.query(sql, binds) { row in
            guard let id = UUID(uuidString: row.string(0)),
                  let account = UUID(uuidString: row.string(1)) else { return }
            out.append(GmailDraft(
                id: id, accountID: account, gmailDraftID: row.stringOrNil(2),
                gmailMessageID: row.stringOrNil(3), threadID: row.stringOrNil(4),
                to: Self.decodeAddresses(opened(row.string(5))),
                cc: Self.decodeAddresses(opened(row.string(6))),
                bcc: Self.decodeAddresses(opened(row.string(7))),
                subject: opened(row.string(8)), bodyText: opened(row.string(9)),
                bodyHTML: row.stringOrNil(10).map(opened),
                attachments: Self.decodeDraftAttachments(opened(row.string(11))),
                inReplyTo: row.stringOrNil(12),
                references: Self.decodeStrings(row.string(13)),
                createdAt: Date(timeIntervalSince1970: row.double(14)),
                updatedAt: Date(timeIntervalSince1970: row.double(15)),
                status: GmailDraftStatus(rawValue: row.string(16)) ?? .local))
        }
        return out
    }

    public func draft(_ id: UUID) -> GmailDraft? {
        drafts(accountID: nil).first { $0.id == id }
    }

    /// IDs only, for account cleanup while the mail UI is locked.
    public func draftIDs(accountID: UUID) -> [UUID] {
        guard let db else { return [] }
        var ids: [UUID] = []
        try? db.query("SELECT id FROM gmail_drafts WHERE account_id = ?;",
                      [.text(accountID.uuidString)]) { row in
            if let id = UUID(uuidString: row.string(0)) { ids.append(id) }
        }
        return ids
    }

    /// Decrypts stored draft fields. Legacy plaintext is accepted and re-encrypted
    /// by `migrateEncryptionIfNeeded`; a sealed value we cannot open becomes empty,
    /// never ciphertext in the UI.
    private func opened(_ raw: String) -> String {
        crypto.openString(raw) ?? ""
    }

    /// One-time upgrade for drafts written before local encryption. Idempotent.
    public func migrateEncryptionIfNeeded() {
        guard !isSecurityLocked else { return }
        guard crypto.isAvailable else {
            encryptionError = GmailCryptoError.keyUnavailable.errorDescription
            return
        }
        guard let db else { return }
        var legacy: [UUID] = []
        try? db.query("""
            SELECT id, to_json, cc_json, bcc_json, subject, body_text, body_html,
                   attachments_json FROM gmail_drafts;
            """) { row in
            guard let id = UUID(uuidString: row.string(0)) else { return }
            let values = (1...7).map { row.string(Int32($0)) }
                .filter { !$0.isEmpty && $0 != "[]" }
            if values.contains(where: { !crypto.isEncryptedString($0) }) {
                legacy.append(id)
            }
        }
        for id in legacy {
            if let draft = draft(id) { _ = saveDraft(draft) }
        }
        encryptionError = nil
    }

    @discardableResult
    public func saveDraft(_ draft: GmailDraft) -> GmailDraft {
        guard !isSecurityLocked else { return draft }
        var value = draft
        value.updatedAt = Date()
        for attachment in value.attachments where !attachment.localPath.isEmpty {
            try? crypto.encryptFileInPlace(URL(fileURLWithPath: attachment.localPath))
        }
        guard let to = crypto.sealString(Self.encodeAddresses(value.to)),
              let cc = crypto.sealString(Self.encodeAddresses(value.cc)),
              let bcc = crypto.sealString(Self.encodeAddresses(value.bcc)),
              let subject = crypto.sealString(value.subject),
              let body = crypto.sealString(value.bodyText),
              let attachments = crypto.sealString(
                Self.encodeDraftAttachments(value.attachments)) else {
            encryptionError = GmailCryptoError.keyUnavailable.errorDescription
            return value
        }
        var html: String?
        if let source = value.bodyHTML {
            guard let sealed = crypto.sealString(source) else {
                encryptionError = GmailCryptoError.keyUnavailable.errorDescription
                return value
            }
            html = sealed
        }
        write { db in
            try db.run("""
                INSERT INTO gmail_drafts
                    (id, account_id, gmail_draft_id, gmail_message_id, thread_id,
                     to_json, cc_json, bcc_json, subject, body_text, body_html,
                     attachments_json, in_reply_to, references_json, created, updated, status)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    gmail_draft_id = excluded.gmail_draft_id,
                    gmail_message_id = excluded.gmail_message_id,
                    thread_id = excluded.thread_id,
                    to_json = excluded.to_json,
                    cc_json = excluded.cc_json,
                    bcc_json = excluded.bcc_json,
                    subject = excluded.subject,
                    body_text = excluded.body_text,
                    body_html = excluded.body_html,
                    attachments_json = excluded.attachments_json,
                    in_reply_to = excluded.in_reply_to,
                    references_json = excluded.references_json,
                    updated = excluded.updated,
                    status = excluded.status;
                """,
                [.text(value.id.uuidString), .text(value.accountID.uuidString),
                 value.gmailDraftID.map { .text($0) } ?? .null,
                 value.gmailMessageID.map { .text($0) } ?? .null,
                 value.threadID.map { .text($0) } ?? .null,
                 .text(to), .text(cc), .text(bcc),
                 .text(subject), .text(body),
                 html.map { .text($0) } ?? .null,
                 .text(attachments),
                 value.inReplyTo.map { .text($0) } ?? .null,
                 .text(Self.encodeStrings(value.references)),
                 .double(value.createdAt.timeIntervalSince1970),
                 .double(value.updatedAt.timeIntervalSince1970),
                 .text(value.status.rawValue)])
        }
        return value
    }

    public func deleteDraft(_ id: UUID) {
        write { db in
            try db.run("DELETE FROM gmail_drafts WHERE id = ?;", [.text(id.uuidString)])
        }
        let dir = KanbanPaths.supportDirectory
            .appendingPathComponent("Gmail", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Outbox

    public struct OutboxItem: Identifiable, Sendable {
        public var id: Int64
        public var accountID: UUID
        public var kind: String
        public var messageID: String?
        public var threadID: String?
        public var payload: Data?
        public var createdAt: Date
        public var attempts: Int
        public var lastError: String?
    }

    public func enqueue(accountID: UUID, kind: String, messageID: String? = nil,
                        threadID: String? = nil, payload: Data? = nil) {
        guard !isSecurityLocked else { return }
        write { db in
            try db.run("""
                INSERT INTO gmail_outbox (account_id, kind, message_id, thread_id, payload, created)
                VALUES (?,?,?,?,?,?);
                """,
                [.text(accountID.uuidString), .text(kind),
                 messageID.map { .text($0) } ?? .null,
                 threadID.map { .text($0) } ?? .null,
                 payload.map { .blob($0) } ?? .null,
                 .double(Date().timeIntervalSince1970)])
        }
    }

    public func pendingOutbox(accountID: UUID? = nil, limit: Int = 100) -> [OutboxItem] {
        guard !isSecurityLocked, let db else { return [] }
        var sql = """
            SELECT id, account_id, kind, message_id, thread_id, payload, created, attempts, last_error
            FROM gmail_outbox
            """
        var binds: [SQLiteDatabase.Value] = []
        if let accountID {
            sql += " WHERE account_id = ?"
            binds.append(.text(accountID.uuidString))
        }
        sql += " ORDER BY id LIMIT ?;"
        binds.append(.int(Int64(limit)))
        var out: [OutboxItem] = []
        try? db.query(sql, binds) { row in
            guard let account = UUID(uuidString: row.string(1)) else { return }
            out.append(OutboxItem(
                id: row.int64(0), accountID: account, kind: row.string(2),
                messageID: row.stringOrNil(3), threadID: row.stringOrNil(4),
                payload: row.blobOrNil(5),
                createdAt: Date(timeIntervalSince1970: row.double(6)),
                attempts: Int(row.int(7)), lastError: row.stringOrNil(8)))
        }
        return out
    }

    public var pendingCount: Int {
        guard !isSecurityLocked, let db else { return 0 }
        var count = 0
        try? db.query("SELECT COUNT(*) FROM gmail_outbox;") { count = Int($0.int(0)) }
        return count
    }

    public func completeOutbox(_ id: Int64) {
        write { db in
            try db.run("DELETE FROM gmail_outbox WHERE id = ?;", [.int(id)])
        }
    }

    public func failOutbox(_ id: Int64, error: String) {
        write { db in
            try db.run("""
                UPDATE gmail_outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?;
                """, [.text(error), .int(id)])
        }
    }

    /// Removes a queued send for a draft the user deleted. A delete means cancel.
    public func removePendingSend(_ draftID: UUID) {
        for item in pendingOutbox(limit: 500) where item.kind == "send" {
            guard let payload = item.payload,
                  let value = try? JSONDecoder().decode(GmailOutboxPayload.self,
                                                        from: payload),
                  value.draftID == draftID else { continue }
            completeOutbox(item.id)
        }
    }

    public func hasPendingSend(_ draftID: UUID) -> Bool {
        pendingOutbox(limit: 500).contains { item in
            guard item.kind == "send", let payload = item.payload,
                  let value = try? JSONDecoder().decode(GmailOutboxPayload.self,
                                                        from: payload) else { return false }
            return value.draftID == draftID
        }
    }

    /// Removes queued draft uploads for one draft. Saving twice offline should
    /// update one Gmail draft, not create two.
    public func removePendingDraft(_ draftID: UUID) {
        for item in pendingOutbox(limit: 500) where item.kind == "draft" {
            guard let payload = item.payload,
                  let value = try? JSONDecoder().decode(GmailOutboxPayload.self,
                                                        from: payload),
                  value.draftID == draftID else { continue }
            completeOutbox(item.id)
        }
    }

    public func clearOutbox(accountID: UUID? = nil) {
        write { db in
            if let accountID {
                try db.run("DELETE FROM gmail_outbox WHERE account_id = ?;",
                           [.text(accountID.uuidString)])
            } else {
                try db.run("DELETE FROM gmail_outbox;")
            }
        }
    }

    // MARK: - Local optimistic state

    public func applyLabels(accountID: UUID, threadIDs: [String],
                            add: [String], remove: [String]) {
        guard !isSecurityLocked, !threadIDs.isEmpty else { return }
        write { db in
            try db.transaction {
                for threadID in threadIDs {
                    var labels = Set<String>()
                    try db.query("""
                        SELECT label_ids FROM gmail_messages WHERE account_id = ? AND thread_id = ?;
                        """, [.text(accountID.uuidString), .text(threadID)]) { row in
                        labels.formUnion(Self.decodeStrings(row.string(0)))
                    }
                    labels.formUnion(add)
                    labels.subtract(remove)
                    let encoded = Self.encodeStrings(Array(labels).sorted())
                    try db.run("""
                        UPDATE gmail_messages SET label_ids = ?, is_unread = ?, is_starred = ?
                        WHERE account_id = ? AND thread_id = ?;
                        """,
                        [.text(encoded), .int(labels.contains("UNREAD") ? 1 : 0),
                         .int(labels.contains("STARRED") ? 1 : 0),
                         .text(accountID.uuidString), .text(threadID)])
                    try recomputeThread(threadID, accountID: accountID, in: db)
                }
            }
        }
    }

    public func applyMessageLabels(accountID: UUID, messageID: String,
                                   add: [String], remove: [String]) {
        guard !isSecurityLocked, let db else { return }
        var threadID: String?
        var labels = Set<String>()
        try? db.query("""
            SELECT thread_id, label_ids FROM gmail_messages WHERE account_id = ? AND id = ?;
            """, [.text(accountID.uuidString), .text(messageID)]) { row in
            threadID = row.string(0)
            labels.formUnion(Self.decodeStrings(row.string(1)))
        }
        guard let threadID else { return }
        labels.formUnion(add)
        labels.subtract(remove)
        write { db in
            try db.transaction {
                try db.run("""
                    UPDATE gmail_messages SET label_ids = ?, is_unread = ?, is_starred = ?
                    WHERE account_id = ? AND id = ?;
                    """,
                    [.text(Self.encodeStrings(Array(labels).sorted())),
                     .int(labels.contains("UNREAD") ? 1 : 0),
                     .int(labels.contains("STARRED") ? 1 : 0),
                     .text(accountID.uuidString), .text(messageID)])
                try recomputeThread(threadID, accountID: accountID, in: db)
            }
        }
    }

    // MARK: - Related mail

    /// Threads whose participants match a meeting's participants. Matching is on
    /// display name and email, both of which are already local.
    public func relatedThreads(participants: [String], accountID: UUID? = nil,
                               since: Date? = nil, limit: Int = 8) -> [GmailThreadSummary] {
        guard !isSecurityLocked else { return [] }
        let needles = participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }
        guard !needles.isEmpty, let db else { return [] }

        var sql = "SELECT account_id, id, participants FROM gmail_threads WHERE 1=1"
        var binds: [SQLiteDatabase.Value] = []
        if let accountID {
            sql += " AND account_id = ?"
            binds.append(.text(accountID.uuidString))
        }
        if let since {
            sql += " AND last_date >= ?"
            binds.append(.double(since.timeIntervalSince1970))
        }
        sql += " ORDER BY last_date DESC LIMIT ?;"
        binds.append(.int(Int64(max(50, limit * 20))))

        var out: [GmailThreadSummary] = []
        try? db.query(sql, binds) { row in
            guard out.count < limit,
                  let account = UUID(uuidString: row.string(0)) else { return }
            let addresses = Self.decodeAddresses(row.string(2))
            let haystack = addresses
                .map { "\($0.name) \($0.email)".lowercased() }
                .joined(separator: " ")
            guard needles.contains(where: { haystack.contains($0) }) else { return }
            if let summary = summary(accountID: account, threadID: row.string(1)) {
                out.append(summary)
            }
        }
        return out
    }

    public func summary(accountID: UUID, threadID: String) -> GmailThreadSummary? {
        guard !isSecurityLocked else { return nil }
        var summary: GmailThreadSummary?
        try? db?.query("""
            SELECT account_id, id, subject, snippet, last_date, message_count,
                   unread_count, starred, has_attachments, labels, participants
            FROM gmail_threads WHERE account_id = ? AND id = ?;
            """, [.text(accountID.uuidString), .text(threadID)]) { row in
            summary = decodeThreadSummary(row, accountID: accountID)
        }
        return summary
    }

    public func threadID(accountID: UUID, messageID: String) -> String? {
        guard let db else { return nil }
        var value: String?
        try? db.query("""
            SELECT thread_id FROM gmail_messages WHERE account_id = ? AND id = ?;
            """, [.text(accountID.uuidString), .text(messageID)]) { value = $0.string(0) }
        return value
    }

    // MARK: - Semantic vectors

    public func storeEmbedding(messageID: String, accountID: UUID, vector: [Float]) {
        guard !isSecurityLocked, !vector.isEmpty else { return }
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        write { db in
            try db.run("""
                INSERT INTO gmail_embeddings (account_id, message_id, vector, updated)
                VALUES (?,?,?,?)
                ON CONFLICT(account_id, message_id) DO UPDATE SET
                    vector = excluded.vector, updated = excluded.updated;
                """, [.text(accountID.uuidString), .text(messageID), .blob(data),
                      .double(Date().timeIntervalSince1970)])
        }
    }

    public func embeddings(accountID: UUID?) -> [(messageID: String, accountID: UUID, vector: [Float])] {
        guard !isSecurityLocked, let db else { return [] }
        var sql = "SELECT account_id, message_id, vector FROM gmail_embeddings"
        var binds: [SQLiteDatabase.Value] = []
        if let accountID {
            sql += " WHERE account_id = ?"
            binds.append(.text(accountID.uuidString))
        }
        var out: [(String, UUID, [Float])] = []
        try? db.query(sql, binds) { row in
            guard let account = UUID(uuidString: row.string(0)),
                  let data = row.blobOrNil(2) else { return }
            var vector: [Float] = []
            vector.reserveCapacity(data.count / 4)
            var index = 0
            while index + 4 <= data.count {
                let bits = data.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt32.self))
                }
                vector.append(Float(bitPattern: bits))
                index += 4
            }
            out.append((row.string(1), account, vector))
        }
        return out
    }

    public func messagesWithoutEmbeddings(accountID: UUID?, limit: Int = 50) -> [GmailMessage] {
        guard !isSecurityLocked, let db else { return [] }
        var sql = """
            SELECT m.account_id, m.id, m.thread_id, m.label_ids, m.history_id, m.internal_date,
                   m.from_name, m.from_email, m.to_json, m.cc_json, m.bcc_json,
                   m.reply_to_json, m.subject, m.snippet, m.body_text, m.body_html,
                   m.size_estimate, m.is_draft, m.rfc_message_id, m.references_json
            FROM gmail_messages m
            LEFT JOIN gmail_embeddings e ON e.account_id = m.account_id AND e.message_id = m.id
            WHERE e.message_id IS NULL
            """
        var binds: [SQLiteDatabase.Value] = []
        if let accountID {
            sql += " AND m.account_id = ?"
            binds.append(.text(accountID.uuidString))
        }
        sql += " ORDER BY m.internal_date DESC LIMIT ?;"
        binds.append(.int(Int64(max(1, limit))))
        var out: [GmailMessage] = []
        try? db.query(sql, binds) { row in
            guard let account = UUID(uuidString: row.string(0)) else { return }
            out.append(decodeMessage(row, accountID: account, offset: 1))
        }
        return out
    }

    // MARK: - Decoding helpers

    private func decodeThreadSummary(_ row: SQLiteDatabase.Row,
                                     accountID: UUID) -> GmailThreadSummary {
        GmailThreadSummary(
            id: row.string(1), accountID: accountID, subject: row.string(2),
            snippet: row.string(3), lastDate: Date(timeIntervalSince1970: row.double(4)),
            messageCount: Int(row.int(5)), unreadCount: Int(row.int(6)),
            starred: row.int(7) != 0, hasAttachments: row.int(8) != 0,
            labelIDs: Self.decodeStrings(row.string(9)),
            participants: Self.decodeAddresses(row.string(10)))
    }

    private func decodeMessage(_ row: SQLiteDatabase.Row, accountID: UUID,
                               offset: Int = 0) -> GmailMessage {
        let i = Int32(offset)
        return GmailMessage(
            id: row.string(i), threadID: row.string(i + 1),
            accountID: accountID,
            labelIDs: Self.decodeStrings(row.string(i + 2)),
            historyID: row.stringOrNil(i + 3),
            internalDate: Date(timeIntervalSince1970: row.double(i + 4)),
            from: GmailAddress(name: row.string(i + 5), email: row.string(i + 6)),
            to: Self.decodeAddresses(row.string(i + 7)),
            cc: Self.decodeAddresses(row.string(i + 8)),
            bcc: Self.decodeAddresses(row.string(i + 9)),
            replyTo: Self.decodeAddresses(row.string(i + 10)),
            subject: row.string(i + 11), snippet: row.string(i + 12),
            bodyText: row.string(i + 13), bodyHTML: row.stringOrNil(i + 14),
            attachments: [],
            sizeEstimate: Int(row.int(i + 15)),
            isDraft: row.int(i + 16) != 0,
            rfcMessageID: row.stringOrNil(i + 17),
            references: Self.decodeStrings(row.string(i + 18)))
    }

    // MARK: - JSON helpers

    static func encodeAddresses(_ values: [GmailAddress]) -> String {
        guard !values.isEmpty else { return "[]" }
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeAddresses(_ raw: String) -> [GmailAddress] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([GmailAddress].self, from: data) else {
            return []
        }
        return values
    }

    static func encodeStrings(_ values: [String]) -> String {
        guard !values.isEmpty else { return "[]" }
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeStrings(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    static func encodeDraftAttachments(_ values: [GmailDraftAttachment]) -> String {
        guard !values.isEmpty else { return "[]" }
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeDraftAttachments(_ raw: String) -> [GmailDraftAttachment] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([GmailDraftAttachment].self, from: data) else {
            return []
        }
        return values
    }

    static func like(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private static func attachmentCount(accountID: UUID, messageID: String,
                                        db: SQLiteDatabase) -> Int {
        var count = 0
        try? db.query("""
            SELECT COUNT(*) FROM gmail_attachments WHERE account_id = ? AND message_id = ?;
            """, [.text(accountID.uuidString), .text(messageID)]) { count = Int($0.int(0)) }
        return count
    }

    private func appendAddressFilter(_ label: String, value: String?, column: String,
                                     second: String, sql: inout String,
                                     binds: inout [SQLiteDatabase.Value]) {
        guard let value, !value.isEmpty else { return }
        sql += """
         AND EXISTS (SELECT 1 FROM gmail_messages m
                     WHERE m.account_id = t.account_id AND m.thread_id = t.id
                       AND (m.\(column) LIKE ? ESCAPE '\\' OR m.\(second) LIKE ? ESCAPE '\\'))
        """
        let pattern = Self.like(value)
        binds.append(.text(pattern))
        binds.append(.text(pattern))
    }

    // MARK: - DB helper

    private func write(_ body: (SQLiteDatabase) throws -> Void) {
        guard let db else { return }
        do {
            try body(db)
            lastError = nil
            revision &+= 1
        } catch {
            lastError = "\(error)"
        }
    }
}
