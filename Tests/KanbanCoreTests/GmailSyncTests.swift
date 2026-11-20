import XCTest

@MainActor
final class GmailSyncTests: XCTestCase {

    private final class FakeAPI: GmailAPIProtocol, @unchecked Sendable {
        var messages: [String: GmailMessage] = [:]
        var listPages: [GmailMessageListPage] = []
        var listCallCount = 0
        var historyPages: [GmailHistoryPage] = []
        var historyError: GmailAPIError?
        var profileResult = GmailProfile(emailAddress: "me@example.com",
                                         messagesTotal: 0, threadsTotal: 0,
                                         historyId: "100")
        var labelsResult: [GmailLabel] = []
        var draftsResult: [GmailServerDraft] = []
        var modified: [(String, [String], [String])] = []
        var trashed: [String] = []
        var untrashed: [String] = []
        var deleted: [String] = []
        var sentRaw: [String] = []
        var sentThreadIDs: [String?] = []
        var sendError: GmailAPIError?
        var attachmentData = Data("attachment".utf8)
        var nextDraftID = "draft-1"
        var createdDrafts: [String] = []
        var deletedDrafts: [String] = []
        var accountID: UUID?

        func profile() async throws -> GmailProfile { profileResult }

        func labels() async throws -> [GmailLabel] { labelsResult }

        func listMessages(pageToken: String?, maxResults: Int) async throws -> GmailMessageListPage {
            defer { listCallCount += 1 }
            if listPages.isEmpty { return GmailMessageListPage(messages: [], nextPageToken: nil,
                                                               resultSizeEstimate: 0) }
            return listPages[min(listCallCount, listPages.count - 1)]
        }

        func getMessage(id: String) async throws -> GmailMessage {
            guard let message = messages[id] else { throw GmailAPIError.notFound("") }
            return message
        }

        func getThread(id: String) async throws -> GmailThread {
            let messages = self.messages.values.filter { $0.threadID == id }
            return GmailThread(summary: GmailThreadFactory.summary(
                accountID: messages.first?.accountID ?? UUID(), threadID: id,
                messages: messages), messages: messages)
        }

        func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
            attachmentData
        }

        func modifyThread(id: String, add: [String], remove: [String]) async throws {
            modified.append((id, add, remove))
        }

        func trashThread(id: String) async throws { trashed.append(id) }
        func untrashThread(id: String) async throws { untrashed.append(id) }
        func deleteThread(id: String) async throws { deleted.append(id) }

        func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
            if let historyError { throw historyError }
            guard !historyPages.isEmpty else {
                return GmailHistoryPage(messageIDs: [], deletedMessageIDs: [],
                                        historyID: startHistoryID, nextPageToken: nil)
            }
            return historyPages.removeFirst()
        }

        func listDrafts() async throws -> [GmailServerDraft] { draftsResult }

        func createDraft(raw: String, threadID: String?) async throws -> GmailServerDraft {
            createdDrafts.append(raw)
            let message = GmailMessage(id: "created-\(createdDrafts.count)",
                                       threadID: threadID ?? "draft-thread",
                                       accountID: accountID ?? messages.values.first?.accountID ?? UUID(),
                                       labelIDs: ["DRAFT"], bodyText: "draft")
            return GmailServerDraft(id: nextDraftID, message: message)
        }

        func updateDraft(id: String, raw: String, threadID: String?) async throws -> GmailServerDraft {
            let message = GmailMessage(id: "updated", threadID: threadID ?? "draft-thread",
                                       accountID: accountID ?? messages.values.first?.accountID ?? UUID(),
                                       labelIDs: ["DRAFT"], bodyText: "draft")
            return GmailServerDraft(id: id, message: message)
        }

        func deleteDraft(id: String) async throws { deletedDrafts.append(id) }

        func sendDraft(id: String) async throws -> GmailMessage {
            try await send(raw: "", threadID: nil)
        }

        func send(raw: String, threadID: String?) async throws -> GmailMessage {
            if let sendError { throw sendError }
            sentRaw.append(raw)
            sentThreadIDs.append(threadID)
            let message = GmailMessage(id: "sent-\(sentRaw.count)", threadID: "sent-thread",
                                       accountID: accountID ?? messages.values.first?.accountID ?? UUID(),
                                       labelIDs: ["SENT"], subject: "Sent", bodyText: "sent")
            messages[message.id] = message
            return message
        }
    }

    private final class FakeFactory: GmailAPIFactory, @unchecked Sendable {
        let api: FakeAPI
        var config = GmailOAuthConfig(clientID: "")
        var saved: [UUID: GmailTokens] = [:]

        init(api: FakeAPI) { self.api = api }

        func makeClient(for account: GmailAccount) async throws -> GmailAPIProtocol { api }
        func save(_ tokens: GmailTokens, for accountID: UUID) async { saved[accountID] = tokens }
        func hasCredentials(for accountID: UUID) async -> Bool { saved[accountID] != nil }
        func forget(_ accountID: UUID) async { saved[accountID] = nil }
        func updateConfig(_ config: GmailOAuthConfig) async { self.config = config }
    }

    private var store: GmailStore!
    private var account: GmailAccount!
    private var api: FakeAPI!
    private var factory: FakeFactory!
    private var engine: GmailSyncEngine!
    private var service: GmailService!

    override func setUp() {
        super.setUp()
        store = GmailStore(ephemeral: true)
        account = store.upsertAccount(GmailAccount(email: "me@example.com"))
        api = FakeAPI()
        factory = FakeFactory(api: api)
        api.accountID = account.id
        engine = GmailSyncEngine(store: store, factory: factory, initialLimit: { 50 })
        service = GmailService(store: store, sync: engine, factory: factory)
    }

    private func message(_ id: String, thread: String = "t1", subject: String = "Pricing",
                         body: String = "Pricing notes", labels: [String] = ["INBOX", "UNREAD"],
                         accountID: UUID? = nil) -> GmailMessage {
        GmailMessage(id: id, threadID: thread, accountID: accountID ?? account.id,
                     labelIDs: labels, internalDate: Date(), from: GmailAddress(raw: "Priya <p@x.com>"),
                     to: [GmailAddress(email: "me@example.com")], subject: subject,
                     snippet: body, bodyText: body, bodyHTML: "<p>\(body)</p>")
    }

    // MARK: Initial sync

    func testInitialSyncStoresMessagesAndHistory() async {
        api.messages = ["m1": message("m1"), "m2": message("m2", thread: "t2", subject: "Lunch")]
        api.listPages = [GmailMessageListPage(messages: [
            GmailMessageRef(id: "m1", threadId: "t1"),
            GmailMessageRef(id: "m2", threadId: "t2")
        ], nextPageToken: nil, resultSizeEstimate: 2)]
        api.labelsResult = [GmailLabel(id: "INBOX", name: "Inbox", type: "system",
                                       unreadCount: 2, totalCount: 2)]
        api.profileResult = GmailProfile(emailAddress: "me@example.com",
                                         messagesTotal: 2, threadsTotal: 2, historyId: "100")

        await engine.sync(account: account)

        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .inbox),
                                     limit: 20, offset: 0).count, 2)
        XCTAssertEqual(store.account(account.id)?.historyID, "100")
        XCTAssertEqual(store.labels(accountID: account.id).count, 1)
        XCTAssertNil(store.account(account.id)?.syncError)
        XCTAssertNil(engine.lastError)
    }

    // MARK: Incremental

    func testIncrementalHistoryAddsAndDeletes() async {
        store.cacheMessage(message("m1"))
        store.setHistory(account.id, historyID: "100", syncedAt: Date())
        api.messages = ["m2": message("m2", thread: "t2", subject: "New message")]
        api.historyPages = [GmailHistoryPage(messageIDs: ["m2"],
                                             deletedMessageIDs: ["m1"],
                                             historyID: "101", nextPageToken: nil)]
        api.draftsResult = []

        await engine.sync(account: store.account(account.id)!)

        XCTAssertNotNil(store.thread(accountID: account.id, threadID: "t2"))
        XCTAssertNil(store.thread(accountID: account.id, threadID: "t1"))
        XCTAssertEqual(store.account(account.id)?.historyID, "101")
    }

    func testExpiredHistoryFallsBackToFullSync() async {
        store.cacheMessage(message("m1"))
        store.setHistory(account.id, historyID: "100", syncedAt: Date())
        api.historyError = .historyExpired
        api.messages = ["m2": message("m2", thread: "t2", subject: "Fresh")]
        api.listPages = [GmailMessageListPage(messages: [
            GmailMessageRef(id: "m2", threadId: "t2")
        ], nextPageToken: nil, resultSizeEstimate: 1)]
        api.profileResult = GmailProfile(emailAddress: "me@example.com",
                                         messagesTotal: 1, threadsTotal: 1, historyId: "200")

        await engine.sync(account: store.account(account.id)!)

        XCTAssertEqual(api.listCallCount, 1, "full sync listed once")
        XCTAssertEqual(store.account(account.id)?.historyID, "200")
        XCTAssertNotNil(store.thread(accountID: account.id, threadID: "t2"))
    }

    func testOfflineSyncKeepsExistingMail() async {
        store.cacheMessage(message("m1"))
        store.setHistory(account.id, historyID: "100", syncedAt: Date())
        api.historyError = .transport("offline")
        api.listPages = []

        await engine.sync(account: store.account(account.id)!)

        XCTAssertNotNil(store.thread(accountID: account.id, threadID: "t1"))
        XCTAssertNotNil(store.account(account.id)?.syncError)
        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .inbox),
                                     limit: 10, offset: 0).count, 1)
    }

    // MARK: Outbox

    func testOutboxModifyReachesGoogleAndClears() async {
        store.cacheMessage(message("m1"))
        let payload = try! JSONEncoder().encode(GmailOutboxPayload(
            addLabels: ["STARRED"], removeLabels: [], raw: nil,
            threadID: "t1", draftID: nil, gmailDraftID: nil))
        store.enqueue(accountID: account.id, kind: "modify", threadID: "t1", payload: payload)
        store.setHistory(account.id, historyID: "100", syncedAt: Date())
        api.historyPages = [GmailHistoryPage(messageIDs: [], deletedMessageIDs: [],
                                             historyID: "100", nextPageToken: nil)]

        await engine.sync(account: store.account(account.id)!)

        XCTAssertEqual(api.modified.count, 1)
        XCTAssertEqual(api.modified.first?.0, "t1")
        XCTAssertEqual(api.modified.first?.1, ["STARRED"])
        XCTAssertEqual(store.pendingCount, 0)
    }

    // MARK: Sending

    func testSendOfflineQueuesThenFlushes() async throws {
        store.cacheMessage(message("m1"))
        var draft = GmailDraft(accountID: account.id, threadID: "t1",
                               to: [GmailAddress(raw: "Priya <p@x.com>")],
                               subject: "Hello", bodyText: "Body")
        draft = store.saveDraft(draft)
        api.sendError = .transport("offline")

        let result = try await service.send(draft, confirmed: true)
        if case .queued = result {} else { XCTFail("expected queued") }
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.draft(draft.id)?.status, .queued)

        api.sendError = nil
        await engine.flushOutbox(accountID: account.id)

        XCTAssertEqual(api.sentRaw.count, 1)
        XCTAssertEqual(api.sentThreadIDs, ["t1"])
        XCTAssertTrue(api.sentRaw[0].contains("Subject: Hello"))
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertNil(store.draft(draft.id))
    }

    func testSendRequiresConfirmation() async {
        let draft = GmailDraft(accountID: account.id,
                               to: [GmailAddress(raw: "p@x.com")],
                               subject: "No", bodyText: "Body")
        do {
            _ = try await service.send(draft, confirmed: false)
            XCTFail("send without confirmation must throw")
        } catch {
            XCTAssertTrue((error as? GmailAPIError)?.errorDescription?.contains("confirmation") == true)
        }
        XCTAssertEqual(api.sentRaw.count, 0)
    }

    func testDraftPushCreatesServerDraftAndKeepsLocalID() async {
        var draft = GmailDraft(accountID: account.id,
                               to: [GmailAddress(raw: "p@x.com")],
                               subject: "Draft", bodyText: "Body")
        draft = store.saveDraft(draft)
        await service.pushDraft(draft)

        XCTAssertEqual(api.createdDrafts.count, 1)
        XCTAssertEqual(store.draft(draft.id)?.gmailDraftID, "draft-1")
        XCTAssertEqual(store.draft(draft.id)?.status, .synced)
    }

    // MARK: Attachments

    func testAttachmentDownloadWritesFileAndUpdatesRow() async throws {
        let directory = NSTemporaryDirectory() + "kanban-gmail-test-\(UUID().uuidString)"
        setenv("KANBAN_SUPPORT_DIR", directory, 1)
        defer {
            unsetenv("KANBAN_SUPPORT_DIR")
            try? FileManager.default.removeItem(atPath: directory)
        }

        let attachment = GmailAttachment(id: "att1", messageID: "m1",
                                         accountID: account.id, filename: "plan.txt",
                                         mimeType: "text/plain", size: 10)
        let url = try await engine.downloadAttachment(accountID: account.id,
                                                      attachment: attachment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.crypto.isEncryptedFile(url))
        XCTAssertFalse(try Data(contentsOf: url).contains(api.attachmentData))
        XCTAssertEqual(try store.crypto.readFile(url), api.attachmentData)
    }
}
