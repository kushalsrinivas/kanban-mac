import CryptoKit
import Foundation

/// Where downloaded GGUF models live, and how they get there.
///
/// Port of Handy's model manager acquisition path: a pinned Hugging Face
/// revision, a mirror as fallback, and a SHA-256 check before the file is
/// trusted. A model that fails the hash is deleted rather than loaded.
enum ModelStorage {
    static var directory: URL {
        KanbanPaths.supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    static func directory(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    static func path(for entry: ModelCatalog.Entry, file: ModelCatalog.File) -> URL {
        directory(for: entry.id).appendingPathComponent(file.filename)
    }

    /// Whether this exact quant is on disk at its catalogued size.
    static func isInstalled(_ entry: ModelCatalog.Entry, file: ModelCatalog.File) -> Bool {
        let url = path(for: entry, file: file)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return false }
        return Int64(size) == file.size
    }

    /// Any installed quant, preferring the catalog default.
    static func installedFile(for entry: ModelCatalog.Entry) -> ModelCatalog.File? {
        if let preferred = entry.defaultFile, isInstalled(entry, file: preferred) {
            return preferred
        }
        return entry.files.values.first { isInstalled(entry, file: $0) }
    }

    static func installedURL(for entry: ModelCatalog.Entry) -> URL? {
        guard let file = installedFile(for: entry) else { return nil }
        return path(for: entry, file: file)
    }

    static func delete(_ entry: ModelCatalog.Entry) {
        try? FileManager.default.removeItem(at: directory(for: entry.id))
    }

    /// Hugging Face first, then Handy's static mirror of the same pinned bytes.
    static func downloadURLs(for entry: ModelCatalog.Entry, file: ModelCatalog.File) -> [URL] {
        [
            "https://huggingface.co/\(entry.repository)/resolve/\(entry.revision)/\(file.filename)",
            "https://blob.handy.computer/\(entry.repository)/\(entry.revision)/\(file.filename)",
        ].compactMap(URL.init(string:))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads one catalogued quant with progress, resumable across a mirror
/// fallback only by starting over: a meeting app downloads a model rarely, and
/// a partial file is never trusted.
@MainActor
@Observable
final class ModelDownloader {

    struct Progress: Equatable {
        var received: Int64 = 0
        var total: Int64 = 0
        var fraction: Double = 0
    }

    /// Keyed by "<model id>/<filename>".
    private(set) var active: [String: Progress] = [:]
    private(set) var lastError: String?

    static func key(_ entry: ModelCatalog.Entry, _ file: ModelCatalog.File) -> String {
        "\(entry.id)/\(file.filename)"
    }

    func isDownloading(_ entry: ModelCatalog.Entry, _ file: ModelCatalog.File) -> Bool {
        active[Self.key(entry, file)] != nil
    }

    /// Downloads, verifies and installs `file`. Returns the installed URL.
    /// Calling again while the same file is in flight joins nothing: the caller
    /// gets the existing task's failure or completion through the store.
    func download(_ entry: ModelCatalog.Entry, file: ModelCatalog.File) async throws -> URL {
        let key = Self.key(entry, file)
        if ModelStorage.isInstalled(entry, file: file) {
            return ModelStorage.path(for: entry, file: file)
        }
        if active[key] != nil {
            throw TranscriptionError.download("That model is already downloading.")
        }
        lastError = nil
        active[key] = Progress(total: file.size)
        defer { active[key] = nil }

        let destination = ModelStorage.path(for: entry, file: file)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        var lastFailure: Error = TranscriptionError.download("No download source answered.")
        for url in ModelStorage.downloadURLs(for: entry, file: file) {
            do {
                try await Self.fetch(url, to: temporary) { [weak self] received, total in
                    guard let self else { return }
                    var progress = self.active[key] ?? Progress(total: file.size)
                    progress.received = received
                    progress.total = total > 0 ? total : file.size
                    progress.fraction = progress.total > 0
                        ? Double(received) / Double(progress.total) : 0
                    self.active[key] = progress
                }
                break
            } catch {
                lastFailure = error
            }
        }
        guard FileManager.default.fileExists(atPath: temporary.path) else {
            lastError = lastFailure.localizedDescription
            throw lastFailure
        }

        let digest = try await Task.detached(priority: .utility) {
            try ModelStorage.sha256(of: temporary)
        }.value
        guard digest == file.sha256.lowercased() else {
            lastError = "The downloaded model failed its integrity check."
            throw TranscriptionError.verify("The downloaded model failed its integrity check.")
        }

        try FileManager.default.createDirectory(
            at: ModelStorage.directory(for: entry.id), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// One HTTP download. `URLSession`'s async download reports progress through
    /// a task delegate while the call itself stays cancellable.
    private static func fetch(_ url: URL,
                              to destination: URL,
                              progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
        let observer = DownloadObserver { received, total in
            Task { @MainActor in progress(received, total) }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60 * 30
        let (temporary, response) = try await URLSession.shared.download(
            for: request, delegate: observer)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TranscriptionError.download("The model server returned \(code).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: temporary, to: destination)
    }
}

/// Progress only: completion stays with `URLSession.download(for:delegate:)`.
private final class DownloadObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
}
