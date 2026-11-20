import XCTest

@MainActor
final class GmailStorageGateTests: XCTestCase {

    private struct FixedFileVault: FileVaultChecking {
        let value: FileVaultState
        func state() -> FileVaultState { value }
    }

    private final class NoopFactory: GmailAPIFactory, @unchecked Sendable {
        func makeClient(for account: GmailAccount) async throws -> GmailAPIProtocol {
            throw GmailAPIError.notConnected
        }
        func save(_ tokens: GmailTokens, for accountID: UUID) async {}
        func hasCredentials(for accountID: UUID) async -> Bool { false }
        func forget(_ accountID: UUID) async {}
        func updateConfig(_ config: GmailOAuthConfig) async {}
    }

    private var support: URL!
    private var store: GmailStore!

    override func setUp() {
        super.setUp()
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmail-gate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        setenv("KANBAN_SUPPORT_DIR", support.path, 1)
        store = GmailStore(ephemeral: true,
                           crypto: GmailCrypto(key: Data(repeating: 0x24, count: 32)))
        _ = store.upsertAccount(GmailAccount(email: "me@example.com"))
    }

    override func tearDown() {
        unsetenv("KANBAN_SUPPORT_DIR")
        try? FileManager.default.removeItem(at: support)
        super.tearDown()
    }

    private func makeModel(state: FileVaultState) -> MailModel {
        let sync = GmailSyncEngine(store: store, factory: NoopFactory())
        let service = GmailService(store: store, sync: sync, factory: NoopFactory())
        return MailModel(store: store, sync: sync, service: service,
                         auth: GmailAuthController(),
                         factory: NoopFactory(),
                         settings: AppSettings.testing(),
                         fileVault: FixedFileVault(value: state))
    }

    func testFileVaultOffLocksMailAndRefusesConnect() async {
        let model = makeModel(state: .off)
        model.refreshStorageSecurity()
        XCTAssertTrue(model.isStorageBlocked)
        XCTAssertTrue(store.isSecurityLocked)
        XCTAssertTrue(store.threads(accountID: nil, query: GmailQuery(mailbox: .inbox),
                                    limit: 10, offset: 0).isEmpty)
        XCTAssertEqual(store.counts(accountID: nil), .zero)

        await model.connect(clientID: "123-abc.apps.googleusercontent.com",
                            clientSecret: "", loginHint: nil)
        XCTAssertTrue(model.error?.lowercased().contains("filevault") == true)
    }

    func testFileVaultOnUnlocksMail() {
        let model = makeModel(state: .on)
        model.refreshStorageSecurity()
        XCTAssertFalse(model.isStorageBlocked)
        XCTAssertFalse(store.isSecurityLocked)
        XCTAssertTrue(model.encryptionReady)
    }

    func testMissingEncryptionKeyBlocksMail() {
        let store = GmailStore(ephemeral: true, crypto: GmailCrypto(provider: { nil }))
        _ = store.upsertAccount(GmailAccount(email: "blocked@example.com"))
        let sync = GmailSyncEngine(store: store, factory: NoopFactory())
        let service = GmailService(store: store, sync: sync, factory: NoopFactory())
        let model = MailModel(store: store, sync: sync, service: service,
                              auth: GmailAuthController(),
                              factory: NoopFactory(),
                              settings: AppSettings.testing(),
                              fileVault: FixedFileVault(value: .on))
        model.refreshStorageSecurity()
        XCTAssertTrue(model.isStorageBlocked)
        XCTAssertTrue(store.isSecurityLocked)
    }
}
