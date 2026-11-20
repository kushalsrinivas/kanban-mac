import CryptoKit
import Foundation
import Security

public enum GmailCryptoError: LocalizedError {
    case keyUnavailable
    case sealFailed
    case openFailed

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "The mail encryption key is not in the Keychain."
        case .sealFailed: return "Could not encrypt local mail data."
        case .openFailed: return "Could not decrypt local mail data."
        }
    }
}

/// App-level encryption for the parts of the mail cache that outlive SQLite:
/// drafts and attachment files. The key is a random 256-bit Keychain item that
/// never leaves this Mac; AES-GCM authenticates every value.
///
/// The key is loaded lazily. AppModel can create this object before a window
/// exists without triggering a Keychain prompt; the first draft/attachment access
/// is what touches the Keychain.
public final class GmailCrypto: @unchecked Sendable {
    private static let fileMagic = Data("MEETGCM1".utf8)
    private static let stringPrefix = "enc:v1:"
    private let provider: @Sendable () -> Data?
    private let lock = NSLock()
    private var cached: SymmetricKey?

    public init(key: Data) {
        self.provider = { key }
    }

    public init(provider: @escaping @Sendable () -> Data?) {
        self.provider = provider
    }

    public static func ephemeral() -> GmailCrypto {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return GmailCrypto(key: Data(bytes))
    }

    /// Production key. A missing/blocked Keychain is a hard failure rather than a
    /// silent fallback to plaintext.
    public static func live() -> GmailCrypto {
        GmailCrypto(provider: { GmailKeychain().loadOrCreateEncryptionKey() })
    }

    public var isAvailable: Bool {
        (try? key()) != nil
    }

    private func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let data = provider(), data.count == 32 else {
            throw GmailCryptoError.keyUnavailable
        }
        let value = SymmetricKey(data: data)
        cached = value
        return value
    }

    // MARK: Strings

    public func sealString(_ value: String) -> String? {
        guard let key = try? key(),
              let sealed = try? AES.GCM.seal(Data(value.utf8), using: key).combined else {
            return nil
        }
        return Self.stringPrefix + sealed.base64EncodedString()
    }

    /// Plaintext (legacy) values are returned unchanged. A value that carries the
    /// encryption prefix but cannot be opened is treated as unreadable, never
    /// displayed as ciphertext.
    public func openString(_ value: String) -> String? {
        guard value.hasPrefix(Self.stringPrefix) else { return value }
        guard let key = try? key() else { return nil }
        let encoded = String(value.dropFirst(Self.stringPrefix.count))
        guard let data = Data(base64Encoded: encoded),
              let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        else { return nil }
        return String(data: opened, encoding: .utf8)
    }

    public func isEncryptedString(_ value: String) -> Bool {
        value.hasPrefix(Self.stringPrefix)
    }

    // MARK: Files

    public func seal(_ data: Data) throws -> Data {
        let key = try key()
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else {
            throw GmailCryptoError.sealFailed
        }
        return Self.fileMagic + sealed
    }

    public func open(_ data: Data) throws -> Data {
        guard data.starts(with: Self.fileMagic) else { return data }
        let key = try key()
        let combined = data.dropFirst(Self.fileMagic.count)
        guard let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: Data(combined)),
                                             using: key) else {
            throw GmailCryptoError.openFailed
        }
        return opened
    }

    public func isEncryptedFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = try? handle.read(upToCount: Self.fileMagic.count)
        return head == Self.fileMagic
    }

    public func readFile(_ url: URL) throws -> Data {
        try open(try Data(contentsOf: url))
    }

    public func writeFile(_ data: Data, to url: URL) throws {
        let sealed = try seal(data)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    /// Idempotent upgrade for files written before app-level encryption existed.
    public func encryptFileInPlace(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              !isEncryptedFile(url) else { return }
        let data = try Data(contentsOf: url)
        try writeFile(data, to: url)
    }

    /// One-time pass over the Gmail support folder. Safe to call on every launch.
    @discardableResult
    public func encryptFiles(under directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !isEncryptedFile(url) else { continue }
            if (try? encryptFileInPlace(url)) != nil { count += 1 }
        }
        return count
    }

    /// Decrypts to a short-lived file only when the user asks to reveal an
    /// attachment. The file lives outside the mail cache and is not reused.
    public func temporaryCopy(of encrypted: URL, filename: String) throws -> URL {
        let data = try readFile(encrypted)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetMailReveal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("\(UUID().uuidString)-\(GmailFileName.safe(filename))")
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        return url
    }
}
