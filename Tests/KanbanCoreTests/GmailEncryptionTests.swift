import XCTest

@MainActor
final class GmailEncryptionTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!
    private var crypto: GmailCrypto!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmail-encryption-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("test.sqlite3")
        crypto = GmailCrypto(key: Data(repeating: 0x42, count: 32))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testDraftFieldsAreEncryptedAtRest() throws {
        let store = GmailStore(url: databaseURL, crypto: crypto)
        let account = store.upsertAccount(GmailAccount(email: "me@example.com"))
        let draft = GmailDraft(
            accountID: account.id,
            to: [GmailAddress(name: "Priya", email: "priya@client.com")],
            subject: "Confidential pricing",
            bodyText: "The secret discount is forty percent.",
            bodyHTML: "<p>The secret discount is forty percent.</p>",
            attachments: [GmailDraftAttachment(
                filename: "secret.pdf", mimeType: "application/pdf",
                localPath: "/tmp/secret.pdf")])
        store.saveDraft(draft)

        let raw = try SQLiteDatabase(path: databaseURL.path)
        var subject = "", body = "", html = "", recipients = "", attachments = ""
        try raw.query("""
            SELECT subject, body_text, body_html, to_json, attachments_json
            FROM gmail_drafts LIMIT 1;
            """) { row in
            subject = row.string(0); body = row.string(1)
            html = row.string(2); recipients = row.string(3)
            attachments = row.string(4)
        }
        XCTAssertTrue(subject.hasPrefix("enc:v1:"))
        XCTAssertTrue(body.hasPrefix("enc:v1:"))
        XCTAssertTrue(html.hasPrefix("enc:v1:"))
        XCTAssertTrue(recipients.hasPrefix("enc:v1:"))
        XCTAssertTrue(attachments.hasPrefix("enc:v1:"))
        XCTAssertFalse(attachments.contains("secret.pdf"))
        XCTAssertFalse(body.contains("secret discount"))
        XCTAssertFalse(html.contains("secret discount"))
        XCTAssertFalse(subject.contains("Confidential"))
        XCTAssertFalse(recipients.contains("priya@client.com"))

        let loaded = store.drafts(accountID: account.id).first
        XCTAssertEqual(loaded?.subject, "Confidential pricing")
        XCTAssertEqual(loaded?.bodyText, "The secret discount is forty percent.")
        XCTAssertEqual(loaded?.bodyHTML, "<p>The secret discount is forty percent.</p>")
        XCTAssertEqual(loaded?.to.first?.email, "priya@client.com")
        XCTAssertEqual(loaded?.attachments.first?.filename, "secret.pdf")
    }

    func testLegacyPlaintextDraftIsMigrated() throws {
        let store = GmailStore(url: databaseURL, crypto: crypto)
        let account = store.upsertAccount(GmailAccount(email: "me@example.com"))
        let raw = try SQLiteDatabase(path: databaseURL.path)
        try raw.run("""
            INSERT INTO gmail_drafts
                (id, account_id, to_json, cc_json, bcc_json, subject, body_text,
                 body_html, attachments_json, references_json, created, updated, status)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.text(UUID().uuidString), .text(account.id.uuidString),
                  .text("[]"), .text("[]"), .text("[]"), .text("Legacy subject"),
                  .text("Legacy body"), .text("<p>Legacy body</p>"), .text("[]"),
                  .text("[]"), .double(Date().timeIntervalSince1970),
                  .double(Date().timeIntervalSince1970), .text("local")])

        store.migrateEncryptionIfNeeded()

        var subject = "", body = ""
        try raw.query("SELECT subject, body_text FROM gmail_drafts LIMIT 1;") { row in
            subject = row.string(0); body = row.string(1)
        }
        XCTAssertTrue(subject.hasPrefix("enc:v1:"))
        XCTAssertTrue(body.hasPrefix("enc:v1:"))
        XCTAssertEqual(store.drafts(accountID: account.id).first?.bodyText, "Legacy body")
    }

    func testAttachmentFilesAreEncryptedAndReadable() throws {
        let source = directory.appendingPathComponent("plain.txt")
        let payload = Data("attachment secret".utf8)
        try payload.write(to: source)
        let encrypted = directory.appendingPathComponent("stored.bin")
        try crypto.writeFile(payload, to: encrypted)

        XCTAssertTrue(crypto.isEncryptedFile(encrypted))
        XCTAssertFalse(try Data(contentsOf: encrypted).contains(payload))
        XCTAssertEqual(try crypto.readFile(encrypted), payload)

        try payload.write(to: source)
        try crypto.encryptFileInPlace(source)
        XCTAssertTrue(crypto.isEncryptedFile(source))
        XCTAssertEqual(try crypto.readFile(source), payload)
    }

    func testFileVaultOutputParser() {
        XCTAssertEqual(SystemFileVault.parse("FileVault is On."), .on)
        XCTAssertEqual(SystemFileVault.parse("FileVault is Off."), .off)
        XCTAssertEqual(SystemFileVault.parse("garbage"), .unknown)
    }

    func testFileVaultPolicyRequiresEncryptionForAccounts() {
        XCTAssertFalse(GmailStoragePolicy.canReadMail(state: .off, hasAccounts: true))
        XCTAssertFalse(GmailStoragePolicy.canReadMail(state: .unknown, hasAccounts: true))
        XCTAssertTrue(GmailStoragePolicy.canReadMail(state: .on, hasAccounts: true))
        XCTAssertTrue(GmailStoragePolicy.canReadMail(state: .off, hasAccounts: false))
    }

    func testMissingKeyRefusesToWriteDrafts() throws {
        let noKey = GmailCrypto(provider: { nil })
        let store = GmailStore(url: databaseURL, crypto: noKey)
        let account = store.upsertAccount(GmailAccount(email: "me@example.com"))
        store.saveDraft(GmailDraft(accountID: account.id,
                                   subject: "No key", bodyText: "Should not persist"))
        XCTAssertNotNil(store.encryptionError)
        XCTAssertTrue(store.drafts(accountID: account.id).isEmpty)
    }

    func testSecurityLockHidesMailAndWrites() {
        let store = GmailStore(url: databaseURL, crypto: crypto)
        let account = store.upsertAccount(GmailAccount(email: "me@example.com"))
        store.cacheMessage(GmailMessage(
            id: "m1", threadID: "t1", accountID: account.id,
            labelIDs: ["INBOX"], from: GmailAddress(email: "p@x.com"),
            subject: "Visible", bodyText: "Body"))
        XCTAssertEqual(store.threads(accountID: account.id,
                                     query: GmailQuery(mailbox: .inbox),
                                     limit: 10, offset: 0).count, 1)

        store.isSecurityLocked = true
        XCTAssertTrue(store.threads(accountID: account.id,
                                    query: GmailQuery(mailbox: .inbox),
                                    limit: 10, offset: 0).isEmpty)
        XCTAssertNil(store.thread(accountID: account.id, threadID: "t1"))
        store.saveDraft(GmailDraft(accountID: account.id, subject: "Hidden"))
        XCTAssertTrue(store.drafts(accountID: account.id).isEmpty)
    }
}
