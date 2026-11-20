import AppKit
import Foundation
import Observation

/// UI state for the mail workspace. All reads come from `GmailStore`; all writes go
/// through `GmailService` so there is one path to Google and one local outbox.
@Observable
@MainActor
final class MailModel {

    enum ComposeMode {
        case new
        case reply(thread: GmailThread, message: GmailMessage, all: Bool)
        case forward(thread: GmailThread, message: GmailMessage)
        case draft(GmailDraft)
    }

    let store: GmailStore
    let sync: GmailSyncEngine
    let service: GmailService
    let auth: GmailAuthController
    let factory: GmailAPIFactory
    let settings: AppSettings
    let fileVault: FileVaultChecking

    var accountID: UUID?
    var mailbox: GmailMailbox = .inbox
    var labelID: String?
    var searchText = ""

    private(set) var threads: [GmailThreadSummary] = []
    private(set) var drafts: [GmailDraft] = []
    private(set) var selectedThreadID: String?
    private(set) var selectedAccountID: UUID?
    private(set) var thread: GmailThread?
    private(set) var labels: [GmailLabel] = []
    private(set) var isLoading = false
    private(set) var isLoadingThread = false
    private(set) var hasMore = false
    private(set) var error: String?
    private(set) var statusMessage: String?
    private(set) var fileVaultState: FileVaultState = .unknown
    private(set) var encryptionReady = false
    private(set) var storageMessage: String?

    var showingComposer = false
    var composerDraft: GmailDraft?
    var composerMode: ComposeMode = .new
    var showingConnectSheet = false
    var deletingAccount: GmailAccount?
    /// Set by AppModel so a manual selection is visible to the agent's "this email".
    @ObservationIgnored var onThreadSelected: ((UUID, String) -> Void)?

    private var offset = 0
    private let pageSize = 40
    @ObservationIgnored private var fetchedThreads: Set<String> = []
    @ObservationIgnored private var didMigrateEncryption = false

    init(store: GmailStore, sync: GmailSyncEngine, service: GmailService,
         auth: GmailAuthController, factory: GmailAPIFactory, settings: AppSettings,
         fileVault: FileVaultChecking = SystemFileVault()) {
        self.store = store
        self.sync = sync
        self.service = service
        self.auth = auth
        self.factory = factory
        self.settings = settings
        self.fileVault = fileVault
    }

    var isStorageBlocked: Bool {
        !GmailStoragePolicy.canReadMail(state: fileVaultState,
                                        hasAccounts: !store.accounts.isEmpty)
            || (!store.accounts.isEmpty && !encryptionReady)
    }

    // MARK: Derived

    var isSyncing: Bool { sync.isSyncing }

    var syncLabel: String {
        if let id = accountID, let progress = sync.progress(for: id) {
            if progress.error != nil { return "SYNC ERROR" }
            if progress.total > 0 {
                return "\(progress.phase) \(progress.completed)/\(progress.total)"
            }
            return progress.phase
        }
        if sync.isSyncing { return "SYNCING" }
        return "LOCAL"
    }

    var selectedAccount: GmailAccount? {
        accountID.flatMap { store.account($0) }
    }

    var connectedAccounts: [GmailAccount] { store.accounts }

    var counts: GmailCounts { store.counts(accountID: accountID) }

    var accountEmails: [UUID: String] {
        Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0.email) })
    }

    var selectedLabelName: String? {
        guard let labelID else { return nil }
        return labels.first { $0.id == labelID }?.name
    }

    // MARK: Loading

    func start() {
        refreshStorageSecurity()
        reload(reset: true)
        if !isStorageBlocked, settings.gmailSyncOnLaunch, !store.accounts.isEmpty {
            Task { await syncNow() }
        }
    }

    /// Verifies both halves of the at-rest story: FileVault for the SQLite message
    /// cache, and the Keychain key for drafts/attachments. Mail stays locked if
    /// either check fails.
    func refreshStorageSecurity() {
        fileVaultState = fileVault.state()
        let keyReady = store.accounts.isEmpty ? true : store.crypto.isAvailable
        encryptionReady = keyReady
        let blocked = !GmailStoragePolicy.canReadMail(state: fileVaultState,
                                                      hasAccounts: !store.accounts.isEmpty)
            || (!store.accounts.isEmpty && !keyReady)
        if blocked {
            storageMessage = keyReady
                ? GmailStoragePolicy.explanation(fileVaultState)
                : "The mail encryption key is unavailable in the login Keychain. Unlock it and press RECHECK."
        } else {
            storageMessage = nil
        }
        // Migrate/encrypt legacy drafts and files even while the message cache is
        // locked; these are the app-encrypted pieces and do not need FileVault.
        if keyReady, !store.accounts.isEmpty, !didMigrateEncryption {
            didMigrateEncryption = true
            store.isSecurityLocked = false
            store.migrateEncryptionIfNeeded()
            let gmailDirectory = KanbanPaths.ensureSupportDirectory()
                .appendingPathComponent("Gmail", isDirectory: true)
            let crypto = store.crypto
            Task.detached(priority: .utility) {
                _ = crypto.encryptFiles(under: gmailDirectory)
            }
        }
        store.isSecurityLocked = blocked
        reload(reset: true)
    }

    func reload(reset: Bool = true) {
        if reset { offset = 0 }
        labels = accountID.map { store.labels(accountID: $0) }
            ?? store.accounts.flatMap { store.labels(accountID: $0.id) }
        var query = GmailQuery.parse(searchText)
        if query.mailbox == nil {
            query.mailbox = searchText.isEmpty ? mailbox : nil
        }
        if let labelID { query.label = labelID }
        query.limit = pageSize
        if mailbox == .drafts && searchText.isEmpty {
            // Server drafts are reconciled into local draft rows, so showing the
            // DRAFT thread as well would duplicate every draft.
            threads = []
            hasMore = false
            drafts = store.drafts(accountID: accountID)
        } else {
            // Fetch one past the requested page so "load more" knows there is more.
            let fetchLimit = offset + pageSize + 1
            let page = store.searchThreads(query, accountID: accountID, limit: fetchLimit)
            let slice = Array(page.dropFirst(offset).prefix(pageSize))
            if reset { threads = slice } else { threads.append(contentsOf: slice) }
            hasMore = page.count > offset + slice.count
            if mailbox == .drafts {
                let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
                drafts = store.drafts(accountID: accountID).filter {
                    needle.isEmpty || $0.subject.lowercased().contains(needle)
                        || $0.bodyText.lowercased().contains(needle)
                        || $0.recipientLine.lowercased().contains(needle)
                }
            } else {
                drafts = []
            }
        }
        if reset, let selectedThreadID, !threads.contains(where: { $0.id == selectedThreadID }) {
            self.selectedThreadID = nil
            self.thread = nil
        }
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        offset += pageSize
        reload(reset: false)
    }

    func setMailbox(_ mailbox: GmailMailbox) {
        statusMessage = nil
        error = nil
        self.mailbox = mailbox
        labelID = nil
        searchText = ""
        selectedThreadID = nil
        thread = nil
        reload(reset: true)
    }

    func setLabel(_ id: String?) {
        statusMessage = nil
        error = nil
        labelID = id
        mailbox = .all
        searchText = ""
        selectedThreadID = nil
        thread = nil
        reload(reset: true)
    }

    func setAccount(_ id: UUID?) {
        statusMessage = nil
        error = nil
        accountID = id
        selectedThreadID = nil
        thread = nil
        reload(reset: true)
    }

    func search(_ text: String) {
        statusMessage = nil
        error = nil
        searchText = text
        selectedThreadID = nil
        thread = nil
        reload(reset: true)
    }

    // MARK: Threads

    func select(thread summary: GmailThreadSummary) {
        guard !isStorageBlocked else { error = storageMessage; return }
        selectedThreadID = summary.id
        selectedAccountID = summary.accountID
        onThreadSelected?(summary.accountID, summary.id)
        thread = nil
        isLoadingThread = true
        // Local read first; the outbox carries the change to Gmail.
        if summary.isUnread {
            service.markRead(accountID: summary.accountID, threadIDs: [summary.id], read: true)
        }
        Task {
            var local = store.thread(accountID: summary.accountID, threadID: summary.id)
            let key = "\(summary.accountID.uuidString)|\(summary.id)"
            // Fetch the whole conversation once per session. A bounded list sync
            // may only have the newest messages of an old thread.
            if !fetchedThreads.contains(key),
               await factory.hasCredentials(for: summary.accountID) {
                fetchedThreads.insert(key)
                local = await sync.fetchThread(accountID: summary.accountID,
                                               threadID: summary.id)
            }
            isLoadingThread = false
            thread = local
            reload(reset: true)
        }
    }

    func select(accountID: UUID, threadID: String, mailbox: GmailMailbox? = nil) {
        if let mailbox { self.mailbox = mailbox }
        self.accountID = accountID
        guard let summary = store.summary(accountID: accountID, threadID: threadID) else {
            error = "That conversation is not in the local cache yet."
            return
        }
        select(thread: summary)
    }

    func clearSelection() {
        selectedThreadID = nil
        selectedAccountID = nil
        thread = nil
    }

    func refreshThread() {
        guard let accountID = selectedAccountID, let threadID = selectedThreadID else { return }
        thread = store.thread(accountID: accountID, threadID: threadID)
        if mailbox == .drafts { drafts = store.drafts(accountID: self.accountID) }
    }

    // MARK: Sync

    func syncNow(forceFull: Bool = false) async {
        refreshStorageSecurity()
        guard !isStorageBlocked else {
            error = storageMessage
            return
        }
        guard !store.accounts.isEmpty else { return }
        statusMessage = nil
        error = nil
        await factory.updateConfig(settings.gmailOAuthConfig)
        if let accountID {
            await sync.sync(accountID: accountID, forceFull: forceFull)
        } else {
            await sync.syncAll()
        }
        reload(reset: true)
        refreshThread()
    }

    func syncIfStale(now: Date = Date()) async {
        guard settings.gmailSyncOnLaunch else { return }
        refreshStorageSecurity()
        guard !isStorageBlocked else { return }
        guard !store.accounts.isEmpty, !sync.isSyncing else { return }
        let stale = store.accounts.contains {
            guard let last = $0.lastSyncAt else { return true }
            return now.timeIntervalSince(last) > 90
        }
        if stale { await syncNow() }
    }

    // MARK: Account lifecycle

    func connect(clientID: String, clientSecret: String, loginHint: String?) async {
        refreshStorageSecurity()
        guard GmailStoragePolicy.canReadMail(state: fileVaultState, hasAccounts: true) else {
            error = GmailStoragePolicy.explanation(fileVaultState)
            return
        }
        guard store.crypto.isAvailable else {
            error = "The mail encryption key is unavailable in the login Keychain. Unlock it and try again."
            return
        }
        error = nil
        let config = GmailOAuthConfig(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard config.isValid else {
            error = GmailOAuthError.invalidConfig.localizedDescription
            return
        }
        do {
            let authorization = try await auth.authorize(config: config, loginHint: loginHint)
            var account = store.account(email: authorization.email)
                ?? GmailAccount(email: authorization.email)
            account.displayName = authorization.name.isEmpty
                ? account.displayName : authorization.name
            account.syncError = nil
            account = store.upsertAccount(account)
            // Reconnecting replaces the old refresh token; revoke the stale one so
            // it cannot be reused.
            if let old = GmailKeychain().load(for: account.id),
               old.refreshToken != authorization.tokens.refreshToken
                || old.accessToken != authorization.tokens.accessToken {
                await auth.revoke(old)
            }
            await factory.save(authorization.tokens, for: account.id)
            guard await factory.hasCredentials(for: account.id) else {
                store.removeAccount(account.id)
                throw GmailOAuthError.callback(
                    "The tokens could not be written to the login Keychain. Unlock it and try again.")
            }
            settings.gmailClientID = config.clientID
            if let secret = config.clientSecret {
                settings.commitGmailClientSecret(secret)
            }
            await factory.updateConfig(config)
            accountID = account.id
            showingConnectSheet = false
            statusMessage = "CONNECTED · \(account.email)"
            await syncNow(forceFull: true)
        } catch is CancellationError {
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func disconnect(_ account: GmailAccount) async {
        let tokens = GmailKeychain().load(for: account.id)
        let localDraftIDs = store.draftIDs(accountID: account.id)
        await auth.revoke(tokens)
        await factory.forget(account.id)
        for draftID in localDraftIDs {
            let directory = KanbanPaths.supportDirectory
                .appendingPathComponent("Gmail", isDirectory: true)
                .appendingPathComponent("Drafts", isDirectory: true)
                .appendingPathComponent(draftID.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
        store.removeAccount(account.id)
        store.removeAttachmentFiles(accountID: account.id)
        if accountID == account.id { accountID = nil }
        if composerDraft?.accountID == account.id {
            showingComposer = false
            composerDraft = nil
            composerMode = .new
        }
        clearSelection()
        deletingAccount = nil
        statusMessage = "DISCONNECTED · LOCAL DATA DELETED"
        reload(reset: true)
    }

    // MARK: Actions

    func toggleStar(_ summary: GmailThreadSummary) {
        service.setStarred(accountID: summary.accountID, threadIDs: [summary.id],
                           starred: !summary.starred)
        reload(reset: true)
        refreshThread()
    }

    func archive(_ summary: GmailThreadSummary) {
        service.archive(accountID: summary.accountID, threadIDs: [summary.id])
        clearSelection()
        reload(reset: true)
        statusMessage = "ARCHIVED"
    }

    func markSpam(_ summary: GmailThreadSummary) {
        service.markSpam(accountID: summary.accountID, threadIDs: [summary.id])
        clearSelection()
        reload(reset: true)
        statusMessage = "MOVED TO SPAM"
    }

    func trash(_ summary: GmailThreadSummary) {
        service.trash(accountID: summary.accountID, threadIDs: [summary.id])
        clearSelection()
        reload(reset: true)
        statusMessage = "MOVED TO TRASH"
    }

    func moveToInbox(_ summary: GmailThreadSummary) {
        if summary.labelIDs.contains("TRASH") {
            service.untrash(accountID: summary.accountID, threadIDs: [summary.id])
        } else {
            service.moveToInbox(accountID: summary.accountID, threadIDs: [summary.id])
        }
        clearSelection()
        reload(reset: true)
        statusMessage = "MOVED TO INBOX"
    }

    func markRead(_ summary: GmailThreadSummary, read: Bool) {
        service.markRead(accountID: summary.accountID, threadIDs: [summary.id], read: read)
        reload(reset: true)
        refreshThread()
    }

    func applyLabel(_ label: GmailLabel, to summary: GmailThreadSummary, add: Bool) {
        service.applyLabel(accountID: summary.accountID, threadIDs: [summary.id],
                           labelID: label.id, add: add)
        reload(reset: true)
        refreshThread()
    }

    // MARK: Composer

    func composeNew() {
        guard !isStorageBlocked else { error = storageMessage; return }
        guard let account = selectedAccount ?? store.accounts.first else {
            showingConnectSheet = true
            return
        }
        composerMode = .new
        composerDraft = GmailDraft(accountID: account.id)
        showingComposer = true
    }

    func composeReply(all: Bool) {
        guard let accountID = selectedAccountID, let thread else { return }
        composeReply(to: thread, accountID: accountID, all: all)
    }

    func composeReply(to thread: GmailThread, accountID: UUID, all: Bool) {
        guard !isStorageBlocked else { error = storageMessage; return }
        guard let account = store.account(accountID),
              let message = thread.orderedMessages.last else { return }
        composerMode = .reply(thread: thread, message: message, all: all)
        composerDraft = service.replyDraft(to: thread, message: message,
                                          account: account, all: all)
        showingComposer = true
    }

    func composeForward() async {
        guard !isStorageBlocked else { error = storageMessage; return }
        guard let accountID = selectedAccountID,
              let account = store.account(accountID),
              let thread, let message = thread.orderedMessages.last else { return }
        composerMode = .forward(thread: thread, message: message)
        composerDraft = await service.forwardDraft(of: thread, message: message, account: account)
        showingComposer = true
    }

    func editDraft(_ draft: GmailDraft) async {
        guard !isStorageBlocked else { error = storageMessage; return }
        guard !store.hasPendingSend(draft.id) else {
            error = "This message is queued to send. Delete the draft to cancel it."
            return
        }
        var value = draft
        // A draft written in Gmail can carry attachments we have never downloaded.
        // Pull them into the draft's own folder before the composer opens. A failed
        // download leaves a placeholder so send can refuse instead of losing it.
        if let messageID = value.gmailMessageID,
           let message = store.message(accountID: value.accountID, messageID: messageID) {
            if value.attachments.isEmpty {
                value.attachments = message.attachments.map {
                    GmailDraftAttachment(
                        filename: $0.filename, mimeType: $0.mimeType,
                        localPath: "", isInline: $0.isInline,
                        contentID: $0.contentID)
                }
            }
            let directory = KanbanPaths.ensureSupportDirectory()
                .appendingPathComponent("Gmail", isDirectory: true)
                .appendingPathComponent("Drafts", isDirectory: true)
                .appendingPathComponent(value.id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            for index in value.attachments.indices {
                let draftAttachment = value.attachments[index]
                if !draftAttachment.localPath.isEmpty,
                   FileManager.default.fileExists(atPath: draftAttachment.localPath) {
                    continue
                }
                guard let remote = message.attachments.first(where: {
                    $0.filename == draftAttachment.filename
                        && (draftAttachment.contentID == nil
                            || $0.contentID == draftAttachment.contentID)
                }), let url = try? await service.downloadAttachment(remote) else {
                    continue
                }
                let destination = directory.appendingPathComponent(
                    "\(remote.id)-\(GmailFileName.safe(remote.filename))")
                if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
                    value.attachments[index].localPath = destination.path
                }
            }
        }
        composerMode = .draft(value)
        composerDraft = value
        showingComposer = true
    }


    func closeComposer(save: Bool) {
        defer {
            showingComposer = false
            composerDraft = nil
        }
        guard save, var draft = composerDraft else { return }
        if draft.isEmpty {
            if store.draft(draft.id) != nil {
                Task { await service.deleteDraft(draft) }
            }
            return
        }
        draft.status = .local
        service.saveDraft(draft)
        Task { await service.pushDraft(draft) }
    }

    /// SAVE DRAFT: persist locally and push the draft to Gmail.
    func saveDraft(_ draft: GmailDraft) {
        guard !isStorageBlocked else { error = storageMessage; return }
        error = nil
        guard draft.attachments.allSatisfy({
            !$0.localPath.isEmpty && FileManager.default.fileExists(atPath: $0.localPath)
        }) else {
            service.saveDraft(draft)
            error = "Download the attachments before saving this draft to Gmail."
            statusMessage = "DRAFT SAVED LOCALLY"
            return
        }
        service.saveDraft(draft)
        Task {
            await factory.updateConfig(settings.gmailOAuthConfig)
            await service.pushDraft(draft)
        }
        statusMessage = "DRAFT SAVED"
    }

    /// Autosave/close: local only. Gmail is contacted only when the user saves or
    /// sends, so a half-written message is not uploaded every few keystrokes.
    func saveDraftLocally(_ draft: GmailDraft) {
        service.saveDraft(draft)
    }

    func sendDraft(_ draft: GmailDraft) async {
        guard !isStorageBlocked else { error = storageMessage; return }
        error = nil
        do {
            await factory.updateConfig(settings.gmailOAuthConfig)
            let result = try await service.send(draft, confirmed: true)
            showingComposer = false
            composerDraft = nil
            switch result {
            case .sent(let message):
                statusMessage = "SENT · \(message.subject)"
                if let accountID = selectedAccountID,
                   let summary = store.summary(accountID: accountID, threadID: message.threadID) {
                    selectedThreadID = summary.id
                    thread = store.thread(accountID: accountID, threadID: summary.id)
                }
            case .queued:
                statusMessage = "QUEUED · SENDS WHEN ONLINE"
            }
            reload(reset: true)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func deleteDraft(_ draft: GmailDraft) async {
        await service.deleteDraft(draft)
        reload(reset: true)
        statusMessage = "DRAFT DELETED"
    }

    // MARK: Attachments

    /// Copies a user-selected file into the draft folder with app-level encryption.
    /// The composer never writes plaintext into the mail cache.
    func addDraftAttachment(source: URL, draftID: UUID, mimeType: String,
                            inline: Bool) -> GmailDraftAttachment? {
        guard !isStorageBlocked else { error = storageMessage; return nil }
        guard let data = try? Data(contentsOf: source) else { return nil }
        let folder = KanbanPaths.ensureSupportDirectory()
            .appendingPathComponent("Gmail", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent(draftID.uuidString, isDirectory: true)
        let filename = source.lastPathComponent
        let destination = folder.appendingPathComponent(
            "\(UUID().uuidString)-\(GmailFileName.safe(filename))")
        do {
            try store.crypto.writeFile(data, to: destination)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
        return GmailDraftAttachment(
            filename: filename, mimeType: mimeType, localPath: destination.path,
            isInline: inline,
            contentID: inline ? "\(UUID().uuidString)@meet.local" : nil)
    }

    func download(_ attachment: GmailAttachment) async {
        guard !isStorageBlocked else { error = storageMessage; return }
        error = nil
        do {
            let encrypted = try await service.downloadAttachment(attachment)
            let revealed = try store.crypto.temporaryCopy(
                of: encrypted, filename: attachment.filename)
            NSWorkspace.shared.activateFileViewerSelecting([revealed])
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func inlineImages(for message: GmailMessage) async -> [String: Data] {
        await service.inlineImages(for: message)
    }

    // MARK: Meeting bridge

    func relatedThreads(for meeting: Meeting, limit: Int = 5) -> [GmailThreadSummary] {
        GmailMeetingBridge.relatedThreads(for: meeting, source: store, limit: limit)
    }

    func relatedThreads(for scheduled: ScheduledMeeting, limit: Int = 5) -> [GmailThreadSummary] {
        GmailMeetingBridge.relatedThreads(for: scheduled, source: store, limit: limit)
    }

    func followUpDraft(for meeting: Meeting, account: GmailAccount) -> GmailDraft {
        GmailMeetingBridge.followUpDraft(for: meeting, source: store, account: account)
    }

    func composeFollowUp(for meeting: Meeting) {
        guard !isStorageBlocked else { error = storageMessage; return }
        guard !store.accounts.isEmpty else {
            showingConnectSheet = true
            return
        }
        let related = relatedThreads(for: meeting, limit: 1).first
        let account = related.flatMap { store.account($0.accountID) }
            ?? selectedAccount ?? store.accounts.first!
        composerMode = .new
        composerDraft = followUpDraft(for: meeting, account: account)
        showingComposer = true
    }

    func composeFollowUp(for scheduled: ScheduledMeeting) {
        guard !isStorageBlocked else { error = storageMessage; return }
        guard !store.accounts.isEmpty else {
            showingConnectSheet = true
            return
        }
        let account = selectedAccount ?? store.accounts.first!
        let recipients = GmailMeetingBridge.addresses(for: scheduled.participants,
                                                      source: store,
                                                      accountID: account.id)
        let subject = "Agenda: \(scheduled.title)"
        var lines = ["Hi,", ""]
        if !scheduled.notes.isEmpty { lines.append(scheduled.notes); lines.append("") }
        lines.append("Looking forward to \(scheduled.title) at \(CalendarFormat.dateTime(scheduled.startsAt)).")
        lines.append("")
        lines.append(account.displayName.isEmpty ? account.email : account.displayName)
        let body = lines.joined(separator: "\n")
        composerMode = .new
        composerDraft = GmailDraft(accountID: account.id, to: recipients,
                                   subject: subject, bodyText: body,
                                   bodyHTML: body.components(separatedBy: "\n")
                                    .map { "<p>\($0)</p>" }.joined())
        showingComposer = true
    }

    // MARK: Meeting navigation

    func openThread(accountID: UUID, threadID: String) {
        guard !isStorageBlocked else { error = storageMessage; return }
        selectedAccountID = accountID
        selectedThreadID = threadID
        thread = store.thread(accountID: accountID, threadID: threadID)
        reload(reset: true)
    }

    func flash(_ message: String) {
        statusMessage = message
    }
}
