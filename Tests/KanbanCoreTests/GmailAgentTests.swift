import XCTest

@MainActor
final class GmailAgentTests: XCTestCase {

    private var local: LocalStore!
    private var store: GmailStore!
    private var account: GmailAccount!
    private var engine: AgentEngine!

    override func setUp() {
        super.setUp()
        local = LocalStore(ephemeral: true)
        store = GmailStore(ephemeral: true)
        account = store.upsertAccount(GmailAccount(email: "me@example.com",
                                                   displayName: "Me"))
        engine = AgentEngine(store: local, gmail: store)
        seedMail()
    }

    private func message(_ id: String, thread: String, from: String,
                         subject: String, body: String,
                         labels: [String] = ["INBOX", "UNREAD"],
                         date: Date = Date()) -> GmailMessage {
        GmailMessage(id: id, threadID: thread, accountID: account.id,
                     labelIDs: labels, internalDate: date,
                     from: GmailAddress(raw: from),
                     to: [GmailAddress(email: "me@example.com")],
                     subject: subject, snippet: body, bodyText: body,
                     bodyHTML: "<p>\(body)</p>",
                     rfcMessageID: "<\(id)@example.com>")
    }

    private func seedMail() {
        store.cacheMessage(message("m1", thread: "t1",
                                   from: "Priya Sharma <priya@client.com>",
                                   subject: "Pricing proposal",
                                   body: "We discussed the pricing proposal for Q1. Can you confirm the discount?"))
        store.cacheMessage(message("m2", thread: "t2",
                                   from: "Priya Sharma <priya@client.com>",
                                   subject: "Re: Onboarding",
                                   body: "I will send the revised onboarding plan by Friday.",
                                   date: Date().addingTimeInterval(-3600)))
        store.cacheMessage(message("m3", thread: "t3",
                                   from: "Newsletter <noreply@news.example>",
                                   subject: "Weekly digest",
                                   body: "Ten tips for productivity.",
                                   labels: ["INBOX"]))
        store.cacheMessage(message("m4", thread: "t4",
                                   from: "Sam <sam@other.com>",
                                   subject: "Contract signature",
                                   body: "The contract is due tomorrow. Is it blocked?",
                                   labels: ["INBOX", "UNREAD", "STARRED"]))
    }

    // MARK: Planner

    func testPlannerRoutesMailPhrases() {
        let context = AgentContext()
        func plan(_ text: String) -> AgentIntent {
            AgentPlanner.plan(text, context: context)
        }

        if case .emailUnread = plan("summarize my unread emails") {} else {
            XCTFail("unread summary")
        }
        if case .emailAttention = plan("which emails need my attention?") {} else {
            XCTFail("attention")
        }
        if case .emailSearch(let query) = plan("find the email where we discussed pricing") {
            XCTAssertEqual(query.text, "pricing")
        } else { XCTFail("search") }
        if case .emailConversation(let person) = plan("find the latest conversation with Priya") {
            XCTAssertEqual(person.lowercased(), "priya")
        } else { XCTFail("conversation") }
        if case .emailCommitments = plan("what did this client promise?") {} else {
            XCTFail("commitments")
        }
        if case .openMail = plan("open my inbox") {} else {
            XCTFail("open mail")
        }
        if case .emailCompose(let to, let subject, _) = plan("draft an email to Priya about pricing") {
            XCTAssertEqual(to?.lowercased(), "priya")
            XCTAssertEqual(subject, "Pricing")
        } else { XCTFail("compose") }
        if case .emailArchive = plan("archive this email") {} else {
            XCTFail("archive")
        }
        if case .emailLabel(_, let labels, let add) = plan("label this email as Work") {
            XCTAssertEqual(labels.map { $0.lowercased() }, ["work"])
            XCTAssertTrue(add)
        } else { XCTFail("label") }
    }

    func testTaskAndMeetingCommandsAreNotHijackedByEmailFocus() {
        var context = AgentContext()
        context.focus(email: AgentContext.EmailRef(accountID: account.id, threadID: "t1"))
        if case .deleteTask = AgentPlanner.plan("delete this task", context: context) {} else {
            XCTFail("task delete must stay a task delete")
        }
        if case .summary = AgentPlanner.plan("summarize this meeting", context: context) {} else {
            XCTFail("meeting summary must stay a meeting summary")
        }
    }

    func testTaskCreationWithEmailWordIsNotHijacked() {
        let intent = AgentPlanner.plan("create a task to email Sarah about the contract",
                                       context: AgentContext())
        if case .createTask = intent {} else { XCTFail("expected task creation, got \(intent)") }
    }

    // MARK: Reads

    func testUnreadSummaryArtifact() {
        var context = AgentContext()
        let turn = engine.run("summarize my unread emails", context: &context)
        XCTAssertEqual(turn.artifacts.first?.kind, .emailList)
        guard case .emailList(let list)? = turn.artifacts.first?.payload else {
            return XCTFail("expected email list")
        }
        XCTAssertFalse(list.cards.isEmpty)
        XCTAssertTrue(turn.reply.contains("unread"))
        XCTAssertEqual(context.lastFocus, .email)
        XCTAssertFalse(context.emailRefs.isEmpty)
    }

    func testSearchReturnsClickableThreadCard() {
        var context = AgentContext()
        let turn = engine.run("find the email where we discussed pricing", context: &context)
        XCTAssertEqual(turn.artifacts.first?.kind, .emailList)
        guard case .emailList(let list)? = turn.artifacts.first?.payload else {
            return XCTFail("expected email list")
        }
        XCTAssertEqual(list.cards.first?.thread.displaySubject, "Pricing proposal")
        XCTAssertEqual(list.cards.first?.accountEmail, "me@example.com")
        XCTAssertEqual(list.cards.first?.accountID, account.id)
    }

    func testConversationAndCommitments() {
        var context = AgentContext()
        let conversation = engine.run("find the latest conversation with Priya", context: &context)
        guard case .emailList(let list)? = conversation.artifacts.first?.payload else {
            return XCTFail("expected conversation list")
        }
        XCTAssertEqual(list.cards.count, 2)

        let commitments = engine.run("what did this client promise?", context: &context)
        XCTAssertEqual(commitments.artifacts.first?.kind, .emailCommitments)
        guard case .emailCommitments(let items)? = commitments.artifacts.first?.payload else {
            return XCTFail("expected commitments")
        }
        XCTAssertTrue(items.commitments.contains { $0.quote.contains("I will send") }, "\(items.commitments)")
    }

    func testAttentionRanking() {
        var context = AgentContext()
        let turn = engine.run("which emails need my attention?", context: &context)
        guard case .emailList(let list)? = turn.artifacts.first?.payload else {
            return XCTFail("expected attention list")
        }
        XCTAssertFalse(list.cards.isEmpty)
        XCTAssertTrue(list.cards.contains { $0.reason?.contains("starred") == true })
        XCTAssertFalse(list.cards.contains { $0.thread.subject == "Weekly digest" })
    }

    func testOpenThreadNavigatesToMail() {
        var context = AgentContext()
        context.record(emails: [AgentContext.EmailRef(accountID: account.id, threadID: "t1")])
        let turn = engine.run("open the first email", context: &context)
        guard case .mail(let accountID, let threadID)? = turn.navigation else {
            return XCTFail("expected mail navigation")
        }
        XCTAssertEqual(accountID, account.id)
        XCTAssertEqual(threadID, "t1")
    }

    func testEmailSummaryAndLabelSuggestions() {
        var context = AgentContext()
        let ref = AgentContext.EmailRef(accountID: account.id, threadID: "t1")
        context.focus(email: ref)
        let summary = engine.run("summarize this email", context: &context)
        XCTAssertEqual(summary.artifacts.first?.kind, .emailThread)
        XCTAssertTrue(summary.reply.contains("Summary"))

        store.replaceLabels([
            GmailLabel(id: "Label_1", name: "Pricing", type: "user"),
            GmailLabel(id: "Label_2", name: "Legal", type: "user")
        ], accountID: account.id)
        let labels = engine.run("suggest labels for this email", context: &context)
        XCTAssertTrue(labels.reply.contains("Pricing"), labels.reply)
        XCTAssertTrue(labels.reply.contains("Finance"), labels.reply)
    }

    func testAgentRefusesEmailWhileStorageIsLocked() {
        store.isSecurityLocked = true
        var context = AgentContext()
        let turn = engine.run("summarize my unread emails", context: &context)
        XCTAssertTrue(turn.artifacts.isEmpty)
        XCTAssertTrue(turn.reply.lowercased().contains("locked"))
        XCTAssertTrue(context.emailRefs.isEmpty)
        store.isSecurityLocked = false
    }

    // MARK: Writes

    func testDraftReplyIsProposedNotSent() {
        var context = AgentContext()
        let ref = AgentContext.EmailRef(accountID: account.id, threadID: "t1",
                                        messageID: "m1")
        context.focus(email: ref)
        let turn = engine.run("draft a reply", context: &context)
        XCTAssertEqual(turn.operations.count, 1)
        XCTAssertEqual(turn.operations.first?.kind, .createEmailDraft)
        XCTAssertEqual(turn.artifacts.first?.kind, .emailDraft)
        XCTAssertEqual(turn.operations.first?.emailDraft?.to.first?.email, "priya@client.com")
        XCTAssertFalse(turn.operations.contains { $0.kind.rawValue.contains("send") })
    }

    func testArchiveAndLabelProposals() {
        var context = AgentContext()
        context.record(emails: [AgentContext.EmailRef(accountID: account.id, threadID: "t1")])
        let archive = engine.run("archive this email", context: &context)
        XCTAssertEqual(archive.operations.first?.kind, .archiveEmail)
        XCTAssertEqual(archive.operations.first?.emailThreadIDs, ["t1"])

        let label = engine.run("label this email as Work", context: &context)
        // No Work label exists in this cache, so the engine explains rather than
        // inventing one.
        XCTAssertTrue(label.operations.isEmpty)
        XCTAssertTrue(label.reply.contains("No label"))
    }

    func testExecutorUsesOnlyTheMailActionProtocol() throws {
        final class Recorder: GmailActionExecutor {
            var drafts: [GmailDraft] = []
            var archived: [[String]] = []
            var labels: [([String], [String])] = []
            func emailSetLabels(accountID: UUID, threadIDs: [String],
                                add: [String], remove: [String]) throws {
                labels.append((add, remove))
            }
            func emailArchive(accountID: UUID, threadIDs: [String]) throws {
                archived.append(threadIDs)
            }
            func emailTrash(accountID: UUID, threadIDs: [String]) throws {}
            func emailCreateDraft(_ draft: GmailDraft) throws { drafts.append(draft) }
        }
        let recorder = Recorder()
        var draft = GmailDraft(accountID: account.id, to: [GmailAddress(email: "p@x.com")],
                               subject: "Hello", bodyText: "Body")
        draft = store.saveDraft(draft)
        try AgentExecutor.apply(.createDraft(draft, accountEmail: account.email),
                                store: local, syncEnabled: false, gmail: recorder)
        XCTAssertEqual(recorder.drafts.count, 1)

        let archive = AgentOperation.archiveEmail(
            [store.summary(accountID: account.id, threadID: "t1")!],
            accountEmail: account.email)!
        try AgentExecutor.apply(archive, store: local, syncEnabled: false, gmail: recorder)
        XCTAssertEqual(recorder.archived, [["t1"]])
    }

    // MARK: Meeting bridge

    func testMeetingRelatedMailAndFollowUpDraft() throws {
        let meeting = Meeting(
            title: "Pricing review", startedAt: Date().addingTimeInterval(-3600),
            duration: 1800, status: .completed,
            summary: "We reviewed the pricing proposal.",
            decisions: ["Keep the Q1 discount"],
            participants: ["Priya Sharma"],
            actionItems: [ActionItem(meetingID: UUID(), title: "Send the final quote",
                                     assignee: "Priya", confidence: 0.9,
                                     state: .suggested, position: 0)],
            transcript: [])
        local.upsertMeeting(meeting)

        let related = GmailMeetingBridge.relatedThreads(for: meeting, source: store)
        XCTAssertEqual(related.first?.displaySubject, "Pricing proposal")

        let draft = GmailMeetingBridge.followUpDraft(for: meeting, source: store,
                                                      account: account)
        XCTAssertTrue(draft.subject.contains("Pricing review"))
        XCTAssertTrue(draft.bodyText.contains("We reviewed the pricing proposal."))
        XCTAssertTrue(draft.bodyText.contains("Send the final quote"))
        XCTAssertTrue(draft.to.contains { $0.email == "priya@client.com" })
    }

    func testRelatedEmailSectionUsesAccountScope() {
        let second = store.upsertAccount(GmailAccount(email: "second@example.com"))
        store.cacheMessage(GmailMessage(
            id: "x1", threadID: "x1t", accountID: second.id,
            labelIDs: ["INBOX"], internalDate: Date(),
            from: GmailAddress(raw: "Priya <priya@client.com>"),
            subject: "Second account", snippet: "Only in second", bodyText: "Only in second"))
        let scoped = store.relatedThreads(participants: ["Priya"], accountID: account.id,
                                          since: nil, limit: 5)
        XCTAssertFalse(scoped.contains { $0.subject == "Second account" })
    }
}
