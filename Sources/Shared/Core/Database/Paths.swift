import Foundation

public enum KanbanPaths {
    public static let folderName = "Kanban"

    /// ~/Library/Application Support/Kanban — readable by the app and the widget extension
    /// without an App Group (and therefore without a provisioning profile).
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    public static var databaseURL: URL { supportDirectory.appendingPathComponent("tasks.sqlite3") }

    /// Tiny denormalised file the widget reads. Avoids opening SQLite in the extension.
    public static var snapshotURL: URL { supportDirectory.appendingPathComponent("snapshot.json") }

    /// Temporary recordings live here until they are uploaded. They are transport
    /// artefacts, not a media library — unless the user turns on "keep originals".
    public static var recordingsDirectory: URL {
        supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    public static func recordingURL(filename: String) -> URL {
        recordingsDirectory.appendingPathComponent(filename)
    }

    @discardableResult
    public static func ensureRecordingsDirectory() -> URL {
        let dir = recordingsDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Total bytes held by temporary recordings, shown in Settings.
    public static func recordingsByteCount() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    @discardableResult
    public static func ensureSupportDirectory() -> URL {
        let dir = supportDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
