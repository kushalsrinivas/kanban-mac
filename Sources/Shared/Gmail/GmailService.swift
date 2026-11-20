import Foundation
import Observation

public enum GmailSendResult: Sendable {
    case sent(GmailMessage)
    case queued
}

/// User-visible Gmail actions. Local state changes first, the queue preserves the
/// intent, and the sync engine replays it. Sending is the one action that requires
/// an explicit `confirmed: true` from the UI.
@MainActor
@Observable
public final class GmailService {

    public private(set) var lastError: String?

    private let store: GmailStore
    private let sync: GmailSyncEngine
    private let factory: GmailAPIFactory

    public init(store: GmailStore, sync: GmailSyncEngine, factory: GmailAPIFactory) {
        self.store = store
        self.sync = sync
        self.factory = factory
    }

    // MARK: - Flags and folders

    public func markRead(accountID: UUID, threadIDs: [String], read: Bool) {
        guard requireUnlocked() else { return }
        apply(accountID: accountID, threadIDs: threadIDs,
              add: read ? [] : ["UNREAD"], remove: read ? ["UNREAD"] : [])
    }

    public func setStarred(accountID: UUID, threadIDs: [String], starred: Bool) {
        guard requireUnlocked() else { return }
        apply(accountID: accountID, threadIDs: threadIDs,
              add: starred ? ["STARRED"] : [], remove: starred ? [] : ["STARRED"])
    }

    public func archive(accountID: UUID, threadIDs: [String]) {
        guard requireUnlocked() else { return }
        apply(accountID: accountID, threadIDs: threadIDs, add: [], remove: ["INBOX"])
    }

    public func moveToInbox(accountID: UUID, threadIDs: [String]) {
        guard requireUnlocked() else { return }
        apply(accountID: accountID, threadIDs: threadIDs, add: ["INBOX"], remove: ["TRASH", "SPAM"])
    }

    public func trash(accountID: UUID, threadIDs: [String]) {
        guard requireUnlocked(), !threadIDs.isEmpty else { return }
        store.applyLabels(accountID: accountID, threadIDs: threadIDs,
                          add: ["TRASH"], remove: ["INBOX"])
        for threadID in threadIDs {
            store.enqueue(accountID: accountID, kind: "trash", threadID: threadID)
        }
        flushLater(accountID: accountID)
    }

    public func untrash(accountID: UUID, threadIDs: [String]) {
        guard requireUnlocked(), !threadIDs.isEmpty else { return }
        store.applyLabels(accountID: accountID, threadIDs: threadIDs,
                          add: ["INBOX"], remove: ["TRASH"])
        for threadID in threadIDs {
            store.enqueue(accountID: accountID, kind: "untrash", threadID: threadID)
        }
        flushLater(accountID: accountID)
    }

    public func markSpam(accountID: UUID, threadIDs: [String]) {
        guard requireUnlocked() else { return }
        apply(accountID: accountID, threadIDs: threadIDs, add: ["SPAM"], remove: ["INBOX"])
    }

    public func applyLabel(accountID: UUID, threadIDs: [String], labelID: String,
                           add: Bool) {
        guard requireUnlocked() else { return }
        apply(accountID: accountID, threadIDs: threadIDs,
              add: add ? [labelID] : [], remove: add ? [] : [labelID])
    }

    private func apply(accountID: UUID, threadIDs: [String],
                       add: [String], remove: [String]) {
        guard !threadIDs.isEmpty else { return }
        store.applyLabels(accountID: accountID, threadIDs: threadIDs, add: add, remove: remove)
        for threadID in threadIDs {
            store.enqueue(accountID: accountID, kind: "modify", threadID: threadID,
                          payload: try? JSONEncoder().encode(
                            GmailOutboxPayload(addLabels: add, removeLabels: remove,
                                               raw: nil, threadID: threadID,
                                               draftID: nil, gmailDraftID: nil)))
        }
        flushLater(accountID: accountID)
    }

    private func flushLater(accountID: UUID) {
        Task { await sync.flushOutbox(accountID: accountID) }
    }

    // MARK: - Drafts

    @discardableResult
    public func saveDraft(_ draft: GmailDraft) -> GmailDraft {
        guard requireUnlocked() else { return draft }
        return store.saveDraft(draft)
    }

    /// Queues a local draft for Gmail. Called when the composer closes or the user
    /// asks for the draft to live in Gmail too.
    public func pushDraft(_ draft: GmailDraft) async {
        guard requireUnlocked(), let account = store.account(draft.accountID) else { return }
        guard !draft.isEmpty else { return }
        guard draft.attachments.allSatisfy({
            !$0.localPath.isEmpty && FileManager.default.fileExists(atPath: $0.localPath)
        }) else {
            lastError = "Download the attachments before saving this draft to Gmail."
            return
        }
        let raw = GmailMime.build(outgoing(for: draft, account: account))
        store.saveDraft(withStatus(draft, .queued))
        store.removePendingDraft(draft.id)
        store.enqueue(accountID: account.id, kind: "draft", threadID: draft.threadID,
                      payload: try? JSONEncoder().encode(
                        GmailOutboxPayload(addLabels: nil, removeLabels: nil, raw: raw,
                                           threadID: draft.threadID, draftID: draft.id,
                                           gmailDraftID: draft.gmailDraftID)))
        await sync.flushOutbox(accountID: account.id)
    }

    public func deleteDraft(_ draft: GmailDraft) async {
        guard requireUnlocked() else { return }
        store.removePendingSend(draft.id)
        if let messageID = draft.gmailMessageID {
            store.removeMessage(accountID: draft.accountID, messageID: messageID)
        }
        store.deleteDraft(draft.id)
        if let gmailDraftID = draft.gmailDraftID {
            store.enqueue(accountID: draft.accountID, kind: "draft_delete",
                          payload: try? JSONEncoder().encode(
                            GmailOutboxPayload(addLabels: nil, removeLabels: nil, raw: nil,
                                               threadID: nil, draftID: draft.id,
                                               gmailDraftID: gmailDraftID)))
            await sync.flushOutbox(accountID: draft.accountID)
        }
    }

    // MARK: - Sending

    /// The only send path. `confirmed` is deliberately required: the agent can
    /// create a draft, but no code path can send one without the user pressing SEND.
    public func send(_ draft: GmailDraft, confirmed: Bool) async throws -> GmailSendResult {
        guard !store.isSecurityLocked else {
            throw GmailAPIError.invalidRequest(
                "Mail is locked until FileVault is verified.")
        }
        guard confirmed else {
            throw GmailAPIError.invalidRequest("Sending needs explicit confirmation.")
        }
        guard let account = store.account(draft.accountID) else {
            throw GmailAPIError.notConnected
        }
        if draft.attachments.contains(where: {
            $0.localPath.isEmpty || !FileManager.default.fileExists(atPath: $0.localPath)
        }) {
            throw GmailAPIError.invalidRequest(
                "Download the attachments before sending. Reopen the draft while online to fetch them.")
        }
        let raw = GmailMime.build(outgoing(for: draft, account: account))
        do {
            let api = try await factory.makeClient(for: account)
            let sent = try await api.send(raw: raw, threadID: draft.threadID)
            if let draftMessageID = draft.gmailMessageID, draftMessageID != sent.id {
                store.removeMessage(accountID: account.id, messageID: draftMessageID)
            }
            store.cacheMessage(sent)
            if let gmailDraftID = draft.gmailDraftID {
                do {
                    try await api.deleteDraft(id: gmailDraftID)
                } catch {
                    store.enqueue(accountID: account.id, kind: "draft_delete",
                                  payload: try? JSONEncoder().encode(
                                    GmailOutboxPayload(addLabels: nil, removeLabels: nil,
                                                       raw: nil, threadID: nil,
                                                       draftID: nil,
                                                       gmailDraftID: gmailDraftID)))
                }
            }
            store.deleteDraft(draft.id)
            return .sent(sent)
        } catch let error as GmailAPIError where error.isTransient || error.needsReauthentication {
            store.saveDraft(withStatus(draft, .queued))
            store.enqueue(accountID: account.id, kind: "send", threadID: draft.threadID,
                          payload: try? JSONEncoder().encode(
                            GmailOutboxPayload(addLabels: nil, removeLabels: nil, raw: raw,
                                               threadID: draft.threadID, draftID: draft.id,
                                               gmailDraftID: draft.gmailDraftID)))
            return .queued
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            store.saveDraft(withStatus(draft, .failed))
            throw error
        }
    }

    // MARK: - Attachments

    public func downloadAttachment(_ attachment: GmailAttachment) async throws -> URL {
        guard !store.isSecurityLocked else {
            throw GmailAPIError.invalidRequest("Mail is locked until FileVault is verified.")
        }
        return try await sync.downloadAttachment(accountID: attachment.accountID,
                                          attachment: attachment)
    }

    public func inlineImages(for message: GmailMessage) async -> [String: Data] {
        guard !store.isSecurityLocked else { return [:] }
        return await sync.inlineImages(accountID: message.accountID,
                                attachments: message.attachments)
    }

    // MARK: - Compose helpers

    public func outgoing(for draft: GmailDraft, account: GmailAccount) -> GmailOutgoingMessage {
        var html = draft.bodyHTML
        var outgoingAttachments: [GmailOutgoingAttachment] = []
        for attachment in draft.attachments {
            try? store.crypto.encryptFileInPlace(attachment.localURL)
            guard let data = try? store.crypto.readFile(attachment.localURL) else { continue }
            let contentID = attachment.contentID
                ?? "\(attachment.id.uuidString)@meet.local"
            outgoingAttachments.append(GmailOutgoingAttachment(
                filename: attachment.filename, mimeType: attachment.mimeType,
                data: data, isInline: attachment.isInline, contentID: contentID))
        }
        if let value = html {
            html = GmailMime.inlineFileReferences(
                value,
                attachments: draft.attachments.filter(\.isInline))
        }
        return GmailOutgoingMessage(
            from: GmailAddress(email: account.email),
            to: draft.to, cc: draft.cc, bcc: draft.bcc,
            subject: draft.subject, text: draft.bodyText, html: html,
            attachments: outgoingAttachments,
            inReplyTo: draft.inReplyTo, references: draft.references,
            threadID: draft.threadID)
    }

    public func replyDraft(to thread: GmailThread, message: GmailMessage,
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
            .split(separator: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        let body = "\n\nOn \(GmailFormat.fullDate(message.internalDate)), \(message.from.displayName) wrote:\n\(quote)"
        let htmlQuote = """
            <br><br><blockquote style="margin:0 0 0 12px;padding-left:12px;border-left:2px solid #999;color:#555">
            <p>On \(GmailFormat.fullDate(message.internalDate)), \(escape(message.from.displayName)) wrote:</p>
            <p>\(escape(message.bodyText).replacingOccurrences(of: "\n", with: "<br>"))</p>
            </blockquote>
            """
        return GmailDraft(
            accountID: account.id, threadID: thread.id,
            to: recipients, subject: subject, bodyText: body,
            bodyHTML: "<p><br></p>" + htmlQuote,
            inReplyTo: message.rfcMessageID,
            references: (message.references + [message.rfcMessageID].compactMap { $0 }))
    }

    public func forwardDraft(of thread: GmailThread, message: GmailMessage,
                             account: GmailAccount) async -> GmailDraft {
        let subject = message.subject.lowercased().hasPrefix("fwd:")
            ? message.subject : "Fwd: \(message.subject)"
        let header = "---------- Forwarded message ----------\n"
            + "From: \(message.from.mailbox)\n"
            + "Date: \(GmailFormat.fullDate(message.internalDate))\n"
            + "Subject: \(message.subject)\n"
            + "To: \(message.to.map(\.mailbox).joined(separator: ", "))\n\n"
        let body = header + message.bodyText
        let html = """
            <p><br></p><div style="color:#555">---------- Forwarded message ----------<br>
            From: \(escape(message.from.mailbox))<br>
            Date: \(GmailFormat.fullDate(message.internalDate))<br>
            Subject: \(escape(message.subject))</div>
            <div>\(escape(message.bodyText).replacingOccurrences(of: "\n", with: "<br>"))</div>
            """
        let draftID = UUID()
        var attachments: [GmailDraftAttachment] = []
        if let draftsDir = try? draftDirectory(draftID) {
            for attachment in message.attachments {
                guard let url = try? await downloadAttachment(attachment) else { continue }
                let destination = draftsDir.appendingPathComponent(
                    "\(UUID().uuidString)-\(GmailFileName.safe(attachment.filename))")
                if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
                    // Forwarded inline images become ordinary attachments; the
                    // forwarded body is plain text, so there is no cid to attach to.
                    attachments.append(GmailDraftAttachment(
                        filename: attachment.filename, mimeType: attachment.mimeType,
                        localPath: destination.path, isInline: false))
                }
            }
        }
        return GmailDraft(
            id: draftID, accountID: account.id, threadID: nil, to: [],
            subject: subject,
            bodyText: body + (attachments.isEmpty ? "" : "\n\n[Attachments included]"),
            bodyHTML: html, attachments: attachments)
    }

    private func draftDirectory(_ draftID: UUID) throws -> URL {
        let url = KanbanPaths.ensureSupportDirectory()
            .appendingPathComponent("Gmail", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent(draftID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    private func withStatus(_ draft: GmailDraft, _ status: GmailDraftStatus) -> GmailDraft {
        var value = draft
        value.status = status
        return value
    }

    private func requireUnlocked() -> Bool {
        guard !store.isSecurityLocked else {
            lastError = "Mail is locked until FileVault is verified."
            return false
        }
        return true
    }

    private func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Agent writes

@MainActor
public protocol GmailActionExecutor: AnyObject {
    func emailSetLabels(accountID: UUID, threadIDs: [String],
                        add: [String], remove: [String]) throws
    func emailArchive(accountID: UUID, threadIDs: [String]) throws
    func emailTrash(accountID: UUID, threadIDs: [String]) throws
    func emailCreateDraft(_ draft: GmailDraft) throws
}

extension GmailService: GmailActionExecutor {
    public func emailSetLabels(accountID: UUID, threadIDs: [String],
                               add: [String], remove: [String]) throws {
        guard !store.isSecurityLocked else {
            throw GmailAPIError.invalidRequest("Mail is locked until FileVault is verified.")
        }
        guard store.account(accountID) != nil else { throw GmailAPIError.notConnected }
        apply(accountID: accountID, threadIDs: threadIDs, add: add, remove: remove)
    }

    public func emailArchive(accountID: UUID, threadIDs: [String]) throws {
        guard !store.isSecurityLocked else {
            throw GmailAPIError.invalidRequest("Mail is locked until FileVault is verified.")
        }
        guard store.account(accountID) != nil else { throw GmailAPIError.notConnected }
        archive(accountID: accountID, threadIDs: threadIDs)
    }

    public func emailTrash(accountID: UUID, threadIDs: [String]) throws {
        guard !store.isSecurityLocked else {
            throw GmailAPIError.invalidRequest("Mail is locked until FileVault is verified.")
        }
        guard store.account(accountID) != nil else { throw GmailAPIError.notConnected }
        trash(accountID: accountID, threadIDs: threadIDs)
    }

    public func emailCreateDraft(_ draft: GmailDraft) throws {
        guard !store.isSecurityLocked else {
            throw GmailAPIError.invalidRequest("Mail is locked until FileVault is verified.")
        }
        guard store.account(draft.accountID) != nil else { throw GmailAPIError.notConnected }
        store.saveDraft(draft)
        Task { await pushDraft(draft) }
    }
}
