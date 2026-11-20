import Foundation

/// Builds an API client for one account, refreshing its token as needed.
public protocol GmailAPIFactory: Sendable {
    func makeClient(for account: GmailAccount) async throws -> GmailAPIProtocol
    func save(_ tokens: GmailTokens, for accountID: UUID) async
    func hasCredentials(for accountID: UUID) async -> Bool
    func forget(_ accountID: UUID) async
    func updateConfig(_ config: GmailOAuthConfig) async
}

public actor GmailLiveAPIFactory: GmailAPIFactory {
    private let store: GmailTokenStore
    private var config: GmailOAuthConfig
    private var managers: [UUID: GmailTokenManager] = [:]

    public init(store: GmailTokenStore = GmailKeychain(),
                config: @escaping @Sendable () -> GmailOAuthConfig) {
        self.store = store
        self.config = config()
    }

    public func makeClient(for account: GmailAccount) async throws -> GmailAPIProtocol {
        let manager = manager(for: account.id)
        _ = try await manager.accessToken()
        return GmailAPIClient(
            accountID: account.id,
            accessToken: { try await manager.accessToken() },
            forceRefresh: { try await manager.accessToken(forceRefresh: true) })
    }

    public func save(_ tokens: GmailTokens, for accountID: UUID) async {
        let manager = manager(for: accountID)
        await manager.save(tokens)
    }

    public func hasCredentials(for accountID: UUID) async -> Bool {
        let manager = manager(for: accountID)
        return await manager.hasRefreshToken()
    }

    public func forget(_ accountID: UUID) async {
        let manager = manager(for: accountID)
        await manager.delete()
        managers[accountID] = nil
    }

    public func updateConfig(_ config: GmailOAuthConfig) async {
        self.config = config
        // Existing managers read the config lazily through this closure.
        managers.removeAll()
    }

    private func manager(for id: UUID) -> GmailTokenManager {
        if let existing = managers[id] { return existing }
        let manager = GmailTokenManager(accountID: id, store: store,
                                        config: { [config] in config })
        managers[id] = manager
        return manager
    }
}
