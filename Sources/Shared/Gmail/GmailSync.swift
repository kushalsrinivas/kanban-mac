import Foundation
import Observation

/// Pulls Gmail into the local cache and replays queued edits. It talks only to
/// Google's API and to SQLite; there is no Work Console backend in this path.
@Observable
@MainActor
public final class GmailSyncEngine {

    public private(set) var progress: [UUID: GmailSyncProgress] = [:]
    public private(set) var syncingAccounts: Set<UUID> = []
    public private(set) var lastError: String?
    public private(set) var lastSyncAt: Date?

    @ObservationIgnored private let store: GmailStore
    @ObservationIgnored private let factory: GmailAPIFactory
    @ObservationIgnored private var initialLimit: () -> Int
    @ObservationIgnored private var semanticIndex: (() async -> Void)?
    /// A queued send must never be replayed twice by two overlapping flushes.
    @ObservationIgnored private var outboxFlushInFlight = false

    public init(store: GmailStore, factory: GmailAPIFactory,
                initialLimit: @escaping () -> Int = { 500 }) {
        self.store = store
        self.factory = factory
        self.initialLimit = initialLimit
    }

    public var isSyncing: Bool { !syncingAccounts.isEmpty }

    public func isSyncing(_ accountID: UUID) -> Bool { syncingAccounts.contains(accountID) }

    public func progress(for accountID: UUID) -> GmailSyncProgress? {
        progress[accountID]
    }

    public func setInitialLimitProvider(_ provider: @escaping () -> Int) {
        initialLimit = provider
    }

    public func setSemanticIndexer(_ indexer: @escaping () async -> Void) {
        semanticIndex = indexer
    }

    // MARK: - Sync

    public func syncAll(accountIDs: [UUID]? = nil) async {
        let targets = store.accounts.filter {
            accountIDs?.contains($0.id) ?? true
        }
        for account in targets {
            await sync(account: account, forceFull: false)
        }
    }

    public func sync(accountID: UUID, forceFull: Bool = false) async {
        guard let account = store.account(accountID) else { return }
        await sync(account: account, forceFull: forceFull)
    }

    public func sync(account: GmailAccount, forceFull: Bool = false) async {
        guard !syncingAccounts.contains(account.id) else { return }
        syncingAccounts.insert(account.id)
        defer {
            syncingAccounts.remove(account.id)
            progress[account.id] = nil
            lastSyncAt = Date()
        }
        lastError = nil
        progress[account.id] = GmailSyncProgress(accountID: account.id, phase: "CONNECTING")
        do {
            let api = try await factory.makeClient(for: account)
            // Push local edits first so the pull cannot overwrite them.
            if !outboxFlushInFlight {
                outboxFlushInFlight = true
                defer { outboxFlushInFlight = false }
                try await flushOutbox(api: api, accountID: account.id)
            }
            let labels = try await api.labels()
            store.replaceLabels(labels, accountID: account.id)
            if forceFull || (account.historyID ?? "").isEmpty {
                try await fullSync(account: account, api: api)
            } else {
                do {
                    try await incrementalSync(account: account, api: api)
                } catch GmailAPIError.historyExpired {
                    try await fullSync(account: account, api: api)
                }
            }
            try await reconcileDrafts(account: account, api: api)
            store.setHistory(account.id, historyID: store.account(account.id)?.historyID,
                             error: nil, syncedAt: Date())
            if let semanticIndex { await semanticIndex() }
        } catch is CancellationError {
            // A cancelled sync leaves the last complete state untouched.
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = message
            store.setSyncError(account.id, message)
            progress[account.id] = GmailSyncProgress(
                accountID: account.id, phase: "ERROR", error: message)
        }
    }

    private func fullSync(account: GmailAccount, api: GmailAPIProtocol) async throws {
        progress[account.id] = GmailSyncProgress(
            accountID: account.id, phase: "LISTING", completed: 0, total: 0)
        var pageToken: String?
        var refs: [GmailMessageRef] = []
        let limit = max(50, min(5_000, initialLimit()))
        repeat {
            let page = try await api.listMessages(pageToken: pageToken, maxResults: 100)
            refs.append(contentsOf: page.messages ?? [])
            pageToken = page.nextPageToken
            if refs.count >= limit { break }
            progress[account.id] = GmailSyncProgress(
                accountID: account.id, phase: "LISTING", completed: refs.count, total: limit)
            try Task.checkCancellation()
        } while pageToken != nil

        let selected = Array(refs.prefix(limit))
        progress[account.id] = GmailSyncProgress(
            accountID: account.id, phase: "DOWNLOADING", completed: 0, total: selected.count)
        var completed = 0
        for chunk in selected.chunked(into: 6) {
            try Task.checkCancellation()
            let messages = await withTaskGroup(of: GmailMessage?.self) { group in
                for ref in chunk {
                    group.addTask {
                        try? await api.getMessage(id: ref.id)
                    }
                }
                var out: [GmailMessage] = []
                for await message in group {
                    if let message { out.append(message) }
                }
                return out
            }
            for message in messages {
                store.cacheMessage(message)
                completed += 1
            }
            progress[account.id] = GmailSyncProgress(
                accountID: account.id, phase: "DOWNLOADING",
                completed: completed, total: selected.count)
        }

        // The profile history id is the cursor for the next incremental sync.
        let profile = try await api.profile()
        store.setHistory(account.id, historyID: profile.historyId, error: nil, syncedAt: Date())
    }

    private func incrementalSync(account: GmailAccount, api: GmailAPIProtocol) async throws {
        guard let start = account.historyID, !start.isEmpty else {
            try await fullSync(account: account, api: api)
            return
        }
        progress[account.id] = GmailSyncProgress(
            accountID: account.id, phase: "UPDATING", completed: 0, total: 0)
        var pageToken: String?
        var processed = 0
        var latestHistory = start
        repeat {
            let page = try await api.history(startHistoryID: start, pageToken: pageToken)
            for id in page.messageIDs {
                try Task.checkCancellation()
                do {
                    let message = try await api.getMessage(id: id)
                    store.cacheMessage(message)
                } catch GmailAPIError.notFound {
                    store.removeMessage(accountID: account.id, messageID: id)
                } catch {
                    // One broken message must not abort the whole sync, but a
                    // network failure should: the next pass retries it.
                    if let apiError = error as? GmailAPIError, apiError.isTransient {
                        throw error
                    }
                }
                processed += 1
                progress[account.id] = GmailSyncProgress(
                    accountID: account.id, phase: "UPDATING",
                    completed: processed, total: processed)
            }
            for id in page.deletedMessageIDs {
                store.removeMessage(accountID: account.id, messageID: id)
                processed += 1
            }
            if let history = page.historyID { latestHistory = history }
            pageToken = page.nextPageToken
            store.setHistory(account.id, historyID: latestHistory, error: nil,
                             syncedAt: Date())
        } while pageToken != nil
        store.setHistory(account.id, historyID: latestHistory, error: nil, syncedAt: Date())
    }

    // MARK: - Drafts

    private func reconcileDrafts(account: GmailAccount, api: GmailAPIProtocol) async throws {
        let remote = try await api.listDrafts()
        let local = store.drafts(accountID: account.id)
        let remoteIDs = Set(remote.map(\.id))
        for draft in remote {
            // Cache the underlying message so the thread list has content.
            store.cacheMessage(draft.message)
            if let existing = local.first(where: { $0.gmailDraftID == draft.id }) {
                // A local edit wins until SAVE DRAFT pushes it. Otherwise a routine
                // sync would silently replace what the user just typed.
                guard existing.status != .dirty,
                      existing.status != .queued,
                      existing.status != .failed else { continue }
                var updated = existing
                if let oldMessageID = existing.gmailMessageID,
                   oldMessageID != draft.message.id {
                    store.removeMessage(accountID: account.id, messageID: oldMessageID)
                }
                updated.gmailMessageID = draft.message.id
                updated.threadID = draft.message.threadID
                updated.to = draft.message.to
                updated.cc = draft.message.cc
                updated.bcc = draft.message.bcc
                updated.subject = draft.message.subject
                updated.bodyText = draft.message.bodyText
                updated.bodyHTML = draft.message.bodyHTML
                if updated.attachments.isEmpty {
                    updated.attachments = draft.message.attachments.map {
                        GmailDraftAttachment(
                            filename: $0.filename, mimeType: $0.mimeType,
                            localPath: "", isInline: $0.isInline,
                            contentID: $0.contentID)
                    }
                }
                updated.status = .synced
                store.saveDraft(updated)
            } else if !local.contains(where: { $0.threadID == draft.message.threadID
                && $0.subject == draft.message.subject }) {
                store.saveDraft(GmailDraft(
                    accountID: account.id, gmailDraftID: draft.id,
                    gmailMessageID: draft.message.id, threadID: draft.message.threadID,
                    to: draft.message.to, cc: draft.message.cc, bcc: draft.message.bcc,
                    subject: draft.message.subject, bodyText: draft.message.bodyText,
                    bodyHTML: draft.message.bodyHTML,
                    attachments: draft.message.attachments.map {
                        GmailDraftAttachment(
                            filename: $0.filename, mimeType: $0.mimeType,
                            localPath: "", isInline: $0.isInline,
                            contentID: $0.contentID)
                    },
                    status: .synced))
            }
        }
        // A draft deleted elsewhere is removed locally unless it has never been
        // synced or is waiting to send.
        for draft in local where draft.status == .synced {
            if let id = draft.gmailDraftID, !remoteIDs.contains(id) {
                store.deleteDraft(draft.id)
            }
        }
    }

    // MARK: - Outbox

    public func flushOutbox(accountID: UUID? = nil) async {
        guard !outboxFlushInFlight else { return }
        outboxFlushInFlight = true
        defer { outboxFlushInFlight = false }
        let accounts = store.accounts.filter { accountID == nil || $0.id == accountID }
        for account in accounts {
            do {
                let api = try await factory.makeClient(for: account)
                try await flushOutbox(api: api, accountID: account.id)
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func flushOutbox(api: GmailAPIProtocol, accountID: UUID) async throws {
        for item in store.pendingOutbox(accountID: accountID, limit: 50) {
            try Task.checkCancellation()
            do {
                try await perform(item, api: api, accountID: accountID)
                store.completeOutbox(item.id)
            } catch let error as GmailAPIError {
                store.failOutbox(item.id, error: error.errorDescription ?? "\(error)")
                if error.isTransient || error.needsReauthentication {
                    throw error
                }
                // A permanent error on one item should not block later independent
                // edits, but it stays visible in the account's sync error.
                lastError = error.errorDescription
            } catch {
                store.failOutbox(item.id, error: "\(error)")
                throw error
            }
        }
    }

    private func perform(_ item: GmailStore.OutboxItem,
                         api: GmailAPIProtocol, accountID: UUID) async throws {
        let payload = item.payload.flatMap {
            try? JSONDecoder().decode(GmailOutboxPayload.self, from: $0)
        }
        switch item.kind {
        case "modify":
            guard let threadID = item.threadID else { return }
            try await api.modifyThread(id: threadID,
                                       add: payload?.addLabels ?? [],
                                       remove: payload?.removeLabels ?? [])
        case "trash":
            if let threadID = item.threadID { try await api.trashThread(id: threadID) }
        case "untrash":
            if let threadID = item.threadID { try await api.untrashThread(id: threadID) }
        case "delete":
            if let threadID = item.threadID { try await api.deleteThread(id: threadID) }
        case "send":
            guard let raw = payload?.raw else { return }
            let sent = try await api.send(raw: raw, threadID: payload?.threadID)
            if let draftID = payload?.draftID, let draft = store.draft(draftID),
               let draftMessageID = draft.gmailMessageID, draftMessageID != sent.id {
                store.removeMessage(accountID: accountID, messageID: draftMessageID)
            }
            store.cacheMessage(sent)
            if let gmailDraftID = payload?.gmailDraftID, !gmailDraftID.isEmpty {
                do {
                    try await api.deleteDraft(id: gmailDraftID)
                } catch {
                    // The send succeeded; keep a small cleanup job rather than
                    // leaving a duplicate draft in Gmail.
                    store.enqueue(accountID: accountID, kind: "draft_delete",
                                  payload: try? JSONEncoder().encode(
                                    GmailOutboxPayload(addLabels: nil, removeLabels: nil,
                                                       raw: nil, threadID: nil,
                                                       draftID: nil,
                                                       gmailDraftID: gmailDraftID)))
                }
            }
            if let draftID = payload?.draftID {
                store.deleteDraft(draftID)
            }
        case "draft":
            guard let raw = payload?.raw, let draftID = payload?.draftID,
                  var draft = store.draft(draftID) else { return }
            let server: GmailServerDraft
            if let gmailDraftID = payload?.gmailDraftID, !gmailDraftID.isEmpty {
                do {
                    server = try await api.updateDraft(id: gmailDraftID, raw: raw,
                                                       threadID: payload?.threadID)
                } catch GmailAPIError.notFound {
                    // The draft was deleted in Gmail while this edit was queued.
                    server = try await api.createDraft(raw: raw,
                                                       threadID: payload?.threadID)
                }
            } else {
                server = try await api.createDraft(raw: raw, threadID: payload?.threadID)
            }
            if let oldMessageID = draft.gmailMessageID, oldMessageID != server.message.id {
                store.removeMessage(accountID: accountID, messageID: oldMessageID)
            }
            draft.gmailDraftID = server.id
            draft.gmailMessageID = server.message.id
            draft.threadID = server.message.threadID
            draft.status = .synced
            store.saveDraft(draft)
            store.cacheMessage(server.message)
        case "draft_delete":
            if let gmailDraftID = payload?.gmailDraftID, !gmailDraftID.isEmpty {
                try await api.deleteDraft(id: gmailDraftID)
            }
            if let draftID = payload?.draftID { store.deleteDraft(draftID) }
        default:
            return
        }
    }

    /// Fetches a full conversation on demand. The list sync may deliberately keep a
    /// bounded window, so opening a thread is where missing messages arrive.
    @discardableResult
    public func fetchThread(accountID: UUID, threadID: String) async -> GmailThread? {
        guard let account = store.account(accountID) else { return nil }
        do {
            let api = try await factory.makeClient(for: account)
            let thread = try await api.getThread(id: threadID)
            store.cacheThread(thread)
            lastError = nil
            return store.thread(accountID: accountID, threadID: threadID)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return store.thread(accountID: accountID, threadID: threadID)
        }
    }

    // MARK: - Attachments

    public func downloadAttachment(accountID: UUID,
                                   attachment: GmailAttachment) async throws -> URL {
        if let path = attachment.localPath,
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            try? store.crypto.encryptFileInPlace(url)
            return url
        }
        if let stored = store.attachment(accountID: accountID,
                                         messageID: attachment.messageID,
                                         id: attachment.id),
           let path = stored.localPath,
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            try? store.crypto.encryptFileInPlace(url)
            return url
        }
        guard let account = store.account(accountID) else { throw GmailAPIError.notConnected }
        let api = try await factory.makeClient(for: account)
        let data = try await api.getAttachment(messageID: attachment.messageID,
                                               attachmentID: attachment.id)
        let directory = store.attachmentDirectory(accountID: accountID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let safeName = GmailFileName.safe(attachment.filename)
        let url = directory.appendingPathComponent("\(attachment.id)-\(safeName)")
        try store.crypto.writeFile(data, to: url)
        store.setAttachmentPath(accountID: accountID, messageID: attachment.messageID,
                                id: attachment.id, path: url.path)
        return url
    }

    /// Inline images are downloaded only when a message is actually rendered.
    public func inlineImages(accountID: UUID,
                             attachments: [GmailAttachment]) async -> [String: Data] {
        var out: [String: Data] = [:]
        for attachment in attachments where attachment.isInline && attachment.isImage {
            do {
                let url = try await downloadAttachment(accountID: accountID,
                                                       attachment: attachment)
                if let data = try? store.crypto.readFile(url),
                   let contentID = attachment.contentID {
                    out[contentID] = data
                }
            } catch {
                // A missing inline image must never break the message body.
            }
        }
        return out
    }
}

// MARK: - Outbox payload

struct GmailOutboxPayload: Codable {
    var addLabels: [String]?
    var removeLabels: [String]?
    var raw: String?
    var threadID: String?
    var draftID: UUID?
    var gmailDraftID: String?
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
