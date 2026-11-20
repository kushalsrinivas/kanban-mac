import Foundation

public enum FileVaultState: String, Sendable, Equatable {
    case on, off, unknown
}

public protocol FileVaultChecking: Sendable {
    func state() -> FileVaultState
}

/// macOS has no public FileVault API; `fdesetup status` is the supported command
/// and works without root for the current user.
public struct SystemFileVault: FileVaultChecking {
    public init() {}

    public func state() -> FileVaultState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["status"]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unknown
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Self.parse(String(data: data, encoding: .utf8) ?? "")
    }

    public static func parse(_ output: String) -> FileVaultState {
        let value = output.lowercased()
        if value.contains("filevault is on") { return .on }
        if value.contains("filevault is off") { return .off }
        return .unknown
    }
}

/// Deterministic provider for tests and the screenshot harness. Production always
/// uses `SystemFileVault`.
public struct StaticFileVault: FileVaultChecking {
    public let value: FileVaultState
    public init(_ value: FileVaultState) { self.value = value }
    public func state() -> FileVaultState { value }
}

public enum GmailStoragePolicy {
    /// Message bodies live in SQLite, which cannot be field-encrypted without
    /// destroying the local search index. The policy is therefore: mail may only be
    /// unlocked when the disk itself is encrypted. Drafts and attachment files are
    /// additionally AES-GCM encrypted with a Keychain key regardless.
    public static func canReadMail(state: FileVaultState, hasAccounts: Bool) -> Bool {
        !hasAccounts || state == .on
    }

    public static func explanation(_ state: FileVaultState) -> String {
        switch state {
        case .on:
            return "FileVault is on. The SQLite mail cache is disk-encrypted, and drafts and attachments are also app-encrypted."
        case .off:
            return "FileVault is off. Mail is locked so the SQLite message cache is never exposed on an unencrypted disk. Turn FileVault on in System Settings → Privacy & Security, then press RECHECK."
        case .unknown:
            return "Meet could not verify FileVault. Mail stays locked until the check succeeds. Open System Settings → Privacy & Security → FileVault and press RECHECK."
        }
    }
}
