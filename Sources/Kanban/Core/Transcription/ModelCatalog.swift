import Foundation

/// Handy's bundled model catalog (`catalog.json`, schema 2): every GGUF model
/// transcribe.cpp publishes, with pinned revisions and per-quant hashes.
///
/// The file is the same verbatim catalog Handy ships, so model ids, revisions,
/// hashes and sizes match the upstream engine exactly.
struct ModelCatalog: Decodable, Sendable {

    struct File: Decodable, Sendable {
        let filename: String
        let size: Int64
        let sha256: String
    }

    struct Capabilities: Decodable, Sendable {
        let streaming: Bool
        let translate: Bool
        let languageDetection: Bool
        let timestamps: Bool
    }

    struct Entry: Decodable, Sendable, Identifiable {
        let id: String
        let name: String
        let description: String
        let repository: String
        /// Commit the files and hashes are pinned to.
        let revision: String
        let family: String
        let languages: [String]
        let capabilities: Capabilities
        /// Key of the default file in `files`.
        let quant: String
        /// `asr`, `langid`, `vad` or `diarize`.
        let role: String
        let files: [String: File]

        var defaultFile: File? { files[quant] ?? files.sorted { $0.key < $1.key }.first?.value }

        /// Quant keys in the order Handy offers them: the default first, then
        /// larger files before smaller ones.
        var quantKeys: [String] {
            files.keys.sorted { a, b in
                if a == b { return false }
                if a == quant { return true }
                if b == quant { return false }
                return (files[a]?.size ?? 0) > (files[b]?.size ?? 0)
            }
        }

        func file(quant key: String?) -> File? {
            if let key, let file = files[key] { return file }
            return defaultFile
        }
    }

    let schema: Int
    let languageDetector: String?
    let models: [Entry]

    /// The ASR family this app ships: whisper is the one Handy defaults to, keeps
    /// accuracy on long audio (so a meeting is one run, not chunks), and detects
    /// its own language.
    var whisperModels: [Entry] {
        models.filter { $0.role == "asr" && $0.family == "whisper" }
    }

    func entry(_ id: String) -> Entry? {
        models.first { $0.id == id }
    }

    var vadEntry: Entry? {
        models.first { $0.role == "vad" }
    }

    static func decode(_ data: Data) throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: data)
    }

    static func bundled() throws -> ModelCatalog {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            throw TranscriptionError.engine("the bundled model catalog is missing")
        }
        return try decode(Data(contentsOf: url))
    }
}
