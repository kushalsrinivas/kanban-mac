import CryptoKit
import Foundation
import Security

// MARK: - PKCE

/// RFC 7636 verifier/challenge generation. The verifier never leaves this Mac
/// except in the token exchange that redeems the one-time code.
public enum GmailPKCE {
    public static let unreserved = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    public static func verifier(length: Int = 64) -> String {
        let count = min(128, max(43, length))
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return String(bytes.map { unreserved[Int($0) % unreserved.count] })
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    public static func state() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

// MARK: - Tokens

public struct GmailTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    public var tokenType: String?

    public init(accessToken: String, refreshToken: String? = nil,
                expiresAt: Date, scope: String? = nil, tokenType: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    public var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

public protocol GmailTokenStore: Sendable {
    func save(_ tokens: GmailTokens, for accountID: UUID)
    func load(for accountID: UUID) -> GmailTokens?
    func delete(for accountID: UUID)
    func saveClientID(_ clientID: String)
    func loadClientID() -> String?
    func saveClientSecret(_ secret: String)
    func loadClientSecret() -> String?
}

// MARK: - Keychain implementation

/// Generic-password items in the login keychain, one per account. Access tokens and
/// refresh tokens live together so a disconnect removes both atomically. The OAuth
/// client secret is a separate item and is never written to UserDefaults.
public struct GmailKeychain: GmailTokenStore {
    private let service: String

    public init(service: String = "com.kanban.app.gmail") {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["KANBAN_KEYCHAIN_SERVICE"],
           !override.isEmpty {
            self.service = override + ".gmail"
            return
        }
        #endif
        self.service = service
    }

    private func account(_ id: UUID) -> String { "tokens-\(id.uuidString)" }

    public func save(_ tokens: GmailTokens, for accountID: UUID) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        write(data, account: account(accountID))
    }

    public func load(for accountID: UUID) -> GmailTokens? {
        guard let data = read(account: account(accountID)) else { return nil }
        return try? JSONDecoder().decode(GmailTokens.self, from: data)
    }

    public func delete(for accountID: UUID) {
        remove(account: account(accountID))
    }

    public func saveClientID(_ clientID: String) {
        write(Data(clientID.utf8), account: "client-id")
    }

    public func loadClientID() -> String? {
        read(account: "client-id").flatMap { String(data: $0, encoding: .utf8) }
    }

    public func saveClientSecret(_ secret: String) {
        write(Data(secret.utf8), account: "client-secret")
    }

    public func loadClientSecret() -> String? {
        read(account: "client-secret").flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 256-bit AES-GCM key for local drafts and attachments. Created once per login
    /// keychain, never synced to iCloud and never written to disk in plaintext.
    public func loadOrCreateEncryptionKey() -> Data? {
        if let existing = read(account: "encryption-key"), existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let data = Data(bytes)
        write(data, account: "encryption-key")
        guard let stored = read(account: "encryption-key"), stored == data else {
            return nil
        }
        return data
    }

    private func write(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            _ = SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - OAuth

public struct GmailOAuthConfig: Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Google desktop clients accept a loopback redirect. A custom scheme would
    /// require registering it; loopback works with any unused port.
    public static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send"
    ]

    public var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        let id = trimmedClientID
        return id.contains(".apps.googleusercontent.com") || id.count > 20
    }
}

public enum GmailOAuthError: LocalizedError {
    case invalidConfig
    case cancelled
    case callback(String)
    case exchange(String)
    case refresh(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Add a Google OAuth desktop client ID in Settings → Gmail."
        case .cancelled:
            return "Gmail sign-in was cancelled."
        case .callback(let detail):
            return detail
        case .exchange(let detail):
            return "Google did not accept the sign-in: \(detail)"
        case .refresh(let detail):
            return "Gmail sign-in expired. Reconnect this account. \(detail)"
        }
    }
}

public enum GmailOAuth {
    public static func authorizationURL(config: GmailOAuthConfig,
                                        redirectURI: String,
                                        state: String,
                                        challenge: String,
                                        loginHint: String? = nil) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.trimmedClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GmailOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state)
        ]
        if let loginHint, !loginHint.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        return components?.url
    }

    public static func exchange(code: String, verifier: String, redirectURI: String,
                                config: GmailOAuthConfig,
                                session: URLSession = .shared) async throws -> GmailTokens {
        var fields = [
            "client_id": config.trimmedClientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        if let secret = config.clientSecret, !secret.isEmpty {
            fields["client_secret"] = secret
        }
        return try await tokenRequest(fields, error: { GmailOAuthError.exchange($0) },
                                      session: session)
    }

    public static func refresh(_ refreshToken: String,
                               config: GmailOAuthConfig,
                               session: URLSession = .shared) async throws -> GmailTokens {
        var fields = [
            "client_id": config.trimmedClientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let secret = config.clientSecret, !secret.isEmpty {
            fields["client_secret"] = secret
        }
        var tokens = try await tokenRequest(fields, error: { GmailOAuthError.refresh($0) },
                                            session: session)
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    public static func revoke(_ token: String, session: URLSession = .shared) async {
        guard let url = URL(string: "https://oauth2.googleapis.com/revoke") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["token": token])
        _ = try? await session.data(for: request)
    }


    private static func tokenRequest(_ fields: [String: String],
                                     error: (String) -> GmailOAuthError,
                                     session: URLSession) async throws -> GmailTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw error("Google returned an unexpected response.")
        }
        struct Envelope: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var scope: String?
            var token_type: String?
            var error: String?
            var error_description: String?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard (200..<300).contains(http.statusCode), let access = envelope.access_token else {
            let detail = [envelope.error, envelope.error_description]
                .compactMap { $0 }.joined(separator: ": ")
            throw error(detail)
        }
        return GmailTokens(
            accessToken: access,
            refreshToken: envelope.refresh_token,
            expiresAt: Date().addingTimeInterval((envelope.expires_in ?? 3600) - 60),
            scope: envelope.scope,
            tokenType: envelope.token_type)
    }

    private static func errorWith(_ error: GmailOAuthError, _ detail: String) -> GmailOAuthError {
        switch error {
        case .exchange: return .exchange(detail)
        case .refresh: return .refresh(detail)
        default: return error
        }
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

// MARK: - Token manager

/// Refreshes once, caches in memory, and never hands a token to the UI.
public actor GmailTokenManager {
    private let accountID: UUID
    private let store: GmailTokenStore
    private let config: @Sendable () -> GmailOAuthConfig
    private let refresh: @Sendable (String, GmailOAuthConfig) async throws -> GmailTokens
    private var cached: GmailTokens?

    public init(accountID: UUID, store: GmailTokenStore,
                config: @escaping @Sendable () -> GmailOAuthConfig,
                refresh: @escaping @Sendable (String, GmailOAuthConfig) async throws -> GmailTokens
                    = { token, config in
                        try await GmailOAuth.refresh(token, config: config)
                    }) {
        self.accountID = accountID
        self.store = store
        self.config = config
        self.refresh = refresh
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh {
            if let cached, !cached.isExpired { return cached.accessToken }
            if let stored = store.load(for: accountID), !stored.isExpired {
                cached = stored
                return stored.accessToken
            }
        }
        guard let stored = cached ?? store.load(for: accountID),
              let refresh = stored.refreshToken, !refresh.isEmpty else {
            throw GmailAPIError.notConnected
        }
        let config = self.config()
        guard config.isValid else { throw GmailOAuthError.invalidConfig }
        let refreshed = try await self.refresh(refresh, config)
        var merged = refreshed
        if merged.refreshToken == nil { merged.refreshToken = refresh }
        cached = merged
        store.save(merged, for: accountID)
        return merged.accessToken
    }

    public func hasRefreshToken() -> Bool {
        if let stored = cached ?? store.load(for: accountID) {
            return !(stored.refreshToken ?? "").isEmpty
        }
        return false
    }

    public func save(_ tokens: GmailTokens) {
        cached = tokens
        store.save(tokens, for: accountID)
    }

    public func delete() {
        cached = nil
        store.delete(for: accountID)
    }
}
