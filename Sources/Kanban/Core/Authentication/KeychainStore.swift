import Foundation

/// Credentials live in the login keychain, never in UserDefaults and never in source.
///
/// API token and Gemini key are one JSON item on purpose. The login keychain's ACL
/// is evaluated per item, so two items meant a rebuilt ad-hoc-signed binary could
/// show two password dialogs at startup. One bundle means one unlock covers both.
enum KeychainStore {

    private static let service: String = {
        #if DEBUG
        if let process = ProcessInfo.processInfo.environment["KANBAN_KEYCHAIN_SERVICE"],
           !process.isEmpty {
            return process
        }
        #endif
        return "com.kanban.app.credentials"
    }()

    private static let bundleAccount = "credentials"
    private static let legacyAPIAccount = "api-token"
    private static let legacyGeminiAccount = "gemini-key"

    enum Key: String, CaseIterable {
        case apiToken = "api-token"
        case geminiKey = "gemini-key"
    }

    private struct Bundle: Codable, Equatable {
        var apiToken: String?
        var geminiKey: String?

        var isEmpty: Bool {
            (apiToken ?? "").isEmpty && (geminiKey ?? "").isEmpty
        }
    }

    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        guard !value.isEmpty else { return remove(key) }
        var bundle = loadBundle()
        switch key {
        case .apiToken: bundle.apiToken = value
        case .geminiKey: bundle.geminiKey = value
        }
        return write(bundle)
    }

    static func get(_ key: Key) -> String? {
        let bundle = loadBundle()
        switch key {
        case .apiToken: return bundle.apiToken
        case .geminiKey: return bundle.geminiKey
        }
    }

    static func getAsync(_ key: Key) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: get(key))
            }
        }
    }

    @discardableResult
    static func remove(_ key: Key) -> Bool {
        var bundle = loadBundle()
        switch key {
        case .apiToken: bundle.apiToken = nil
        case .geminiKey: bundle.geminiKey = nil
        }
        if bundle.isEmpty {
            return KeychainAccess.shared.remove(service: service, account: bundleAccount)
        }
        return write(bundle)
    }

    static func has(_ key: Key) -> Bool {
        (get(key)?.isEmpty == false)
    }

    // MARK: Bundle

    private static func loadBundle() -> Bundle {
        if let data = KeychainAccess.shared.data(service: service, account: bundleAccount),
           let bundle = try? JSONDecoder().decode(Bundle.self, from: data) {
            return bundle
        }
        return migrateLegacyIfNeeded()
    }

    /// One-time upgrade from the old two-item layout. The new bundle is written
    /// before the legacy items are left behind; reads continue to work if the write
    /// fails or the keychain is locked.
    private static func migrateLegacyIfNeeded() -> Bundle {
        var bundle = Bundle()
        if let data = KeychainAccess.shared.data(service: service, account: legacyAPIAccount) {
            bundle.apiToken = String(data: data, encoding: .utf8)
        }
        if let data = KeychainAccess.shared.data(service: service, account: legacyGeminiAccount) {
            bundle.geminiKey = String(data: data, encoding: .utf8)
        }
        guard !bundle.isEmpty else { return bundle }
        if write(bundle) {
            KeychainAccess.shared.remove(service: service, account: legacyAPIAccount)
            KeychainAccess.shared.remove(service: service, account: legacyGeminiAccount)
        }
        return bundle
    }

    private static func write(_ bundle: Bundle) -> Bool {
        guard !bundle.isEmpty else {
            return KeychainAccess.shared.remove(service: service, account: bundleAccount)
        }
        guard let data = try? JSONEncoder().encode(bundle) else { return false }
        return KeychainAccess.shared.set(data, service: service, account: bundleAccount)
    }
}
