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
        case geminiKey = "gemini-key"
    }

    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        guard !value.isEmpty else { return remove(key) }
        return KeychainAccess.shared.set(Data(value.utf8), service: service,
                                         account: key.rawValue)
    }

    static func get(_ key: Key) -> String? {
        KeychainAccess.shared.data(service: service, account: key.rawValue)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func remove(_ key: Key) -> Bool {
        KeychainAccess.shared.remove(service: service, account: key.rawValue)
    }

    static func has(_ key: Key) -> Bool {
        (get(key)?.isEmpty == false)
    }
}
