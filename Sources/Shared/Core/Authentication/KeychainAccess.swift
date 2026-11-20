import Foundation
import LocalAuthentication
import Security

/// The raw Keychain seam. Tests inject a counting fake; production uses Security.
public protocol KeychainBackend: Sendable {
    func read(service: String, account: String, context: LAContext?) -> Data?
    func write(service: String, account: String, data: Data) -> Bool
    func delete(service: String, account: String) -> Bool
}

/// One serialized, session-cached entry point for every Keychain read in the app.
///
/// Why this exists: credentials were read independently by AppSettings, the Gmail
/// token manager, GmailCrypto and MailModel. Each `SecItemCopyMatching` can put an
/// authentication dialog on screen, so two components reading the same item could
/// produce two dialogs. Reads here are serialized and the successful value is kept
/// for the process lifetime; writes and deletes update the cache atomically.
public final class KeychainAccess: @unchecked Sendable {
    public static let shared = KeychainAccess(backend: SystemKeychainBackend())

    private let backend: KeychainBackend
    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    /// A missing item is retried after a short pause, not on every render. This is
    /// deliberately short: unlocking the login keychain should start working again
    /// without relaunching the app.
    private var missUntil: [String: Date] = [:]
    private let missLifetime: TimeInterval

    public init(backend: KeychainBackend, missLifetime: TimeInterval = 3) {
        self.backend = backend
        self.missLifetime = missLifetime
    }

    public func data(service: String, account: String) -> Data? {
        let key = cacheKey(service, account)
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] { return cached }
        if let until = missUntil[key], until > Date() { return nil }

        let value = backend.read(service: service, account: account,
                                 context: nil)
        if let value {
            cache[key] = value
            missUntil[key] = nil
        } else {
            missUntil[key] = Date().addingTimeInterval(missLifetime)
        }
        return value
    }

    @discardableResult
    public func set(_ data: Data, service: String, account: String) -> Bool {
        let key = cacheKey(service, account)
        lock.lock()
        defer { lock.unlock() }
        let ok = backend.write(service: service, account: account, data: data)
        if ok {
            cache[key] = data
            missUntil[key] = nil
        }
        return ok
    }

    @discardableResult
    public func remove(service: String, account: String) -> Bool {
        let key = cacheKey(service, account)
        lock.lock()
        defer { lock.unlock() }
        let ok = backend.delete(service: service, account: account)
        if ok {
            cache[key] = nil
            missUntil[key] = Date().addingTimeInterval(missLifetime)
        }
        return ok
    }

    /// Use after an external rotation or a failed authentication, so the next read
    /// is real rather than the session cache.
    public func invalidate(service: String, account: String) {
        let key = cacheKey(service, account)
        lock.lock()
        cache[key] = nil
        missUntil[key] = nil
        lock.unlock()
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        missUntil.removeAll()
        lock.unlock()
    }

    private func cacheKey(_ service: String, _ account: String) -> String {
        service + "\u{0}" + account
    }
}

/// Security.framework implementation. The same LAContext is reused for every read,
/// so the system can carry one authenticated session instead of creating a fresh
/// context for each item.
public final class SystemKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var context: LAContext?

    public init() {}

    private func authenticationContext() -> LAContext? {
        lock.lock()
        defer { lock.unlock() }
        if let context { return context }
        let created = LAContext()
        created.localizedReason = "Unlock your Work Console credentials"
        context = created
        return created
    }

    private func invalidateContext() {
        lock.lock()
        context?.invalidate()
        context = nil
        lock.unlock()
    }

    public func read(service: String, account: String, context: LAContext?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let auth = context ?? authenticationContext() {
            query[kSecUseAuthenticationContext as String] = auth
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            // Do not hammer the user with another dialog; the next deliberate read
            // gets a fresh context.
            invalidateContext()
            return nil
        default:
            return nil
        }
    }

    public func write(service: String, account: String, data: Data) -> Bool {
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
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    public func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
