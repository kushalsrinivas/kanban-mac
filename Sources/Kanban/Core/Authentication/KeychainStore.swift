import Foundation
import Security

/// Credentials live in the login keychain, never in UserDefaults and never in source.
///
/// One generic-password item per key, scoped to this app's service identifier.
enum KeychainStore {

    private static let service: String = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["KANBAN_KEYCHAIN_SERVICE"],
           !override.isEmpty {
            return override
        }
        #endif
        return "com.kanban.app.credentials"
    }()

    enum Key: String, CaseIterable {
        case apiToken = "api-token"
    }

    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        let account = key.rawValue
        guard !value.isEmpty else { return remove(key) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Available without an unlocked screen so the menu bar works after login,
            // but never synced to iCloud or included in backups.
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

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func remove(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ key: Key) -> Bool {
        (get(key)?.isEmpty == false)
    }
}
