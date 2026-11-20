import XCTest

@MainActor
final class GmailCoreTests: XCTestCase {

    private var store: GmailStore!
    private var account: GmailAccount!
    private var other: GmailAccount!

    override func setUp() {
        super.setUp()
        store = GmailStore(ephemeral: true)
        account = store.upsertAccount(GmailAccount(email: "me@example.com",
                                                   displayName: "Me"))
        other = store.upsertAccount(GmailAccount(email: "other@example.com",
                                                  displayName: "Other"))
    }

    private func message(id: String, thread: String? = nil, from: String = "Priya <priya@client.com>",
                         to: String = "me@example.com", subject: String = "Pricing",
                         body: String = "We discussed pricing and the proposal.",
                         date: Date = Date(), labels: [String] = ["INBOX", "UNREAD"],
                         accountID: UUID? = nil) -> GmailMessage {
        GmailMessage(id: id, threadID: thread ?? "thread-\(id)", accountID: accountID ?? account.id,
                     labelIDs: labels, historyID: "1",
                     internalDate: date,
                     from: GmailAddress(raw: from),
                     to: [GmailAddress(raw: to)],
                     subject: subject, snippet: body, bodyText: body,
                     bodyHTML: "<p>\(body)</p>", attachments: [],
                     sizeEstimate: 100, isDraft: labels.contains("DRAFT"),
                     rfcMessageID: "<\(id)@example.com>", references: [])
    }

    // MARK: Accounts and isolation

    func testAccountsPersistAndAreIsolated() {
        store.cacheMessage(message(id: "a1", subject: "Only mine"))
        store.cacheMessage(message(id: "b1", subject: "Only other", accountID: other.id))

        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .inbox),
                                     limit: 10, offset: 0).count, 1)
        XCTAssertEqual(store.threads(accountID: other.id,
                                     query: GmailQuery(mailbox: .inbox),
                                     limit: 10, offset: 0).count, 1)
        XCTAssertEqual(store.threads(accountID: nil,
                                     query: GmailQuery(mailbox: .inbox),
                                     limit: 10, offset: 0).count, 2)

        store.removeAccount(account.id)
        XCTAssertNil(store.account(account.id))
        XCTAssertEqual(store.threads(accountID: other.id,
                                     query: GmailQuery(mailbox: .inbox),
                                     limit: 10, offset: 0).count, 1)
    }

    func testUnreadCountsAndMailboxFilters() {
        store.cacheMessage(message(id: "a1", subject: "One"))
        store.cacheMessage(message(id: "a2", subject: "Two", labels: ["INBOX"]))
        store.cacheMessage(message(id: "a3", subject: "Sent", labels: ["SENT"]))
        store.cacheMessage(message(id: "a4", subject: "Spam", labels: ["SPAM"]))
        store.cacheMessage(message(id: "a5", subject: "Archived", labels: []))

        let counts = store.counts(accountID: account.id)
        XCTAssertEqual(counts.inboxTotal, 2)
        XCTAssertEqual(counts.inboxUnread, 1)
        XCTAssertEqual(counts.spam, 1)
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.drafts, 0)

        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .inbox), limit: 20, offset: 0).count, 2)
        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .sent), limit: 20, offset: 0).count, 1)
        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .archive), limit: 20, offset: 0).count, 1)
    }

    // MARK: Threading and labels

    func testThreadingCombinesMessagesAndFlags() {
        let base = Date().addingTimeInterval(-3600)
        store.cacheMessage(message(id: "m1", thread: "t1", subject: "Re: Pricing",
                                   body: "First", date: base))
        store.cacheMessage(message(id: "m2", thread: "t1", subject: "Re: Pricing",
                                   body: "Second", date: Date(), labels: ["INBOX", "STARRED"]))
        let thread = store.thread(accountID: account.id, threadID: "t1")
        XCTAssertEqual(thread?.messages.count, 2)
        XCTAssertEqual(thread?.summary.messageCount, 2)
        XCTAssertEqual(thread?.summary.unreadCount, 1)
        XCTAssertTrue(thread?.summary.starred == true)
        XCTAssertEqual(thread?.summary.displaySubject, "Pricing")
        XCTAssertEqual(thread?.orderedMessages.last?.bodyText, "Second")
    }

    func testApplyLabelsMovesThreadOutOfInbox() {
        store.cacheMessage(message(id: "m1", thread: "t1", subject: "Archive me"))
        store.applyLabels(accountID: account.id, threadIDs: ["t1"], add: [], remove: ["INBOX"])
        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .inbox), limit: 10, offset: 0).count, 0)
        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .archive), limit: 10, offset: 0).count, 1)
    }

    // MARK: Search

    func testFullTextSearchFindsBodyAndHeaders() {
        store.cacheMessage(message(id: "m1", subject: "Quarterly plan",
                                   body: "The pricing discussion moved to Thursday."))
        store.cacheMessage(message(id: "m2", subject: "Lunch",
                                   body: "Nothing about work.", labels: ["INBOX"]))

        let hits = store.searchThreads(GmailQuery.parse("pricing"), accountID: account.id)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.displaySubject, "Quarterly plan")

        let from = store.searchThreads(GmailQuery.parse("from:priya"), accountID: account.id)
        XCTAssertEqual(from.count, 2, "both messages are from Priya")

        let none = store.searchThreads(GmailQuery.parse("is:unread subject:lunch"),
                                       accountID: account.id)
        XCTAssertEqual(none.count, 0, "lunch is read")
    }

    func testQueryOperatorsParse() {
        let query = GmailQuery.parse("from:priya@client.com is:unread has:attachment label:Work in:inbox newer_than:7d pricing")
        XCTAssertEqual(query.from, "priya@client.com")
        XCTAssertEqual(query.unread, true)
        XCTAssertEqual(query.hasAttachment, true)
        XCTAssertEqual(query.label, "Work")
        XCTAssertEqual(query.mailbox, .inbox)
        XCTAssertNotNil(query.newerThan)
        XCTAssertEqual(query.text, "pricing")
    }

    func testSearchPagination() {
        for index in 0..<7 {
            store.cacheMessage(message(id: "m\(index)", subject: "Message \(index)",
                                       date: Date().addingTimeInterval(Double(index))))
        }
        let first = store.threads(accountID: account.id, query: GmailQuery(mailbox: .inbox),
                                  limit: 3, offset: 0)
        let second = store.threads(accountID: account.id, query: GmailQuery(mailbox: .inbox),
                                   limit: 3, offset: 3)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(second.count, 3)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
    }

    // MARK: Drafts and attachments

    func testDraftLifecycle() {
        var draft = GmailDraft(accountID: account.id, to: [GmailAddress(raw: "Priya <p@x.com>")],
                               subject: "Hello", bodyText: "Body")
        store.saveDraft(draft)
        XCTAssertEqual(store.drafts(accountID: account.id).count, 1)
        draft.subject = "Updated"
        store.saveDraft(draft)
        XCTAssertEqual(store.draft(draft.id)?.subject, "Updated")
        store.deleteDraft(draft.id)
        XCTAssertNil(store.draft(draft.id))
    }

    func testAttachmentPathSurvivesMessageRefresh() {
        var value = message(id: "m1", thread: "t1")
        value.attachments = [GmailAttachment(id: "att1", messageID: "m1",
                                             accountID: account.id,
                                             filename: "plan.pdf", mimeType: "application/pdf",
                                             size: 10)]
        store.cacheMessage(value)
        store.setAttachmentPath(accountID: account.id, messageID: "m1", id: "att1",
                                path: "/tmp/plan.pdf")
        // Re-sync the same message without the local path.
        store.cacheMessage(value)
        XCTAssertEqual(store.attachment(accountID: account.id, messageID: "m1",
                                        id: "att1")?.localPath, "/tmp/plan.pdf")
    }

    func testOutboxLifecycle() {
        store.enqueue(accountID: account.id, kind: "modify", threadID: "t1",
                      payload: Data("{}".utf8))
        XCTAssertEqual(store.pendingCount, 1)
        let item = store.pendingOutbox(accountID: account.id).first!
        store.failOutbox(item.id, error: "offline")
        XCTAssertEqual(store.pendingOutbox(accountID: account.id).first?.attempts, 1)
        store.completeOutbox(item.id)
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testAttachmentFilenamesCannotEscapeTheirDirectory() {
        XCTAssertEqual(GmailFileName.safe("../../evil.sh"), "evil.sh")
        XCTAssertEqual(GmailFileName.safe("..\\..\\win.ini"), "win.ini")
        XCTAssertEqual(GmailFileName.safe("a:b.pdf"), "a-b.pdf")
        XCTAssertEqual(GmailFileName.safe(""), "attachment")
    }

    // MARK: Related mail and semantics

    func testRelatedThreadsMatchParticipantName() {
        store.cacheMessage(message(id: "m1", thread: "t1", from: "Priya Sharma <priya@client.com>",
                                   subject: "Onboarding"))
        store.cacheMessage(message(id: "m2", thread: "t2", from: "Sam <sam@other.com>",
                                   subject: "Lunch"))
        let related = store.relatedThreads(participants: ["Priya"], accountID: nil,
                                           since: nil, limit: 5)
        XCTAssertEqual(related.map(\.displaySubject), ["Onboarding"])
    }

    func testCosineSimilarity() {
        XCTAssertEqual(GmailSemanticIndex.cosine([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(GmailSemanticIndex.cosine([1, 0], [0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(GmailSemanticIndex.cosine([], [1]), 0)
    }
}
