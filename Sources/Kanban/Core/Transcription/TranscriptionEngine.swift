import Foundation
import OSLog
import TranscribeCpp

/// Everything the on-device engine can fail with.
enum TranscriptionError: LocalizedError, Equatable {
    case engine(String)
    case modelMissing(String)
    case download(String)
    case verify(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .engine(let detail): return detail
        case .modelMissing(let name):
            return "The \(name) model is not on this Mac yet. Download it in Settings → Local AI."
        case .download(let detail): return detail
        case .verify(let detail): return detail
        case .cancelled: return "Transcription stopped."
        }
    }

    var isTransient: Bool {
        switch self {
        case .download: return true
        default: return false
        }
    }
}

struct TranscriptionResult: Sendable {
    var text: String
    var language: String?
    var segments: [TranscriptSegment]
    var audioSeconds: Double
    var realTimeFactor: Double
}

/// On-device transcription, ported from Handy's engine layer.
///
/// The inference kernel is the same one Handy uses (`transcribe.cpp` through
/// its official Swift bindings); what this file ports is the control around it:
/// model lifetime, the batch decode policy, long-form chunking when the model
/// needs it, language hints, cancellation, and the real-time factor log.
///
/// Handy's dictation-specific streaming/overlay path is deliberately absent: a
/// meeting is transcribed as a finished clip, which is Handy's
/// `transcribe_recording` batch path.
actor TranscriptionEngine {

    private struct Loaded {
        let id: String
        let model: Model
        let session: Session
    }

    struct ModelTraits {
        var streaming: Bool
        var longForm: Bool
    }

    enum BatchDecode {
        /// Cut at pauses into chunks of about 30 s; 40 s or less is one chunk.
        case chunked
        /// One run. Whisper takes the whole clip and runs its own long-form
        /// windowing inside the library.
        case whole
    }

    /// Handy's `policy::batch_decode`: streaming and long-form models take the
    /// clip in one run; only models that lose accuracy past their window are
    /// chunked.
    nonisolated static func batchDecode(traits: ModelTraits,
                                        longFormChunking: Bool) -> BatchDecode {
        if longFormChunking, !traits.longForm, !traits.streaming {
            return .chunked
        }
        return .whole
    }

    private var loaded: Loaded?
    private var unloadTask: Task<Void, Never>?
    private let cancellation = CancellationBox()
    private let idleTimeout = Duration.seconds(300)
    private let log = Logger(subsystem: "com.kanban.app", category: "transcription")

    /// Stops the run in flight, from any thread, without waiting on the actor
    /// (a blocking decode owns the actor while it runs).
    nonisolated func cancel() {
        cancellation.cancel()
    }

    /// Drops the model now. The next transcription loads it again.
    func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        loaded = nil
    }

    func transcribe(pcm: [Float],
                    entry: ModelCatalog.Entry,
                    modelURL: URL,
                    vadModelURL: URL?,
                    language requested: String? = nil,
                    vocabulary: [String] = [],
                    progress: @escaping @Sendable (Double, String) -> Void = { _, _ in })
        async throws -> TranscriptionResult {

        unloadTask?.cancel()
        unloadTask = nil
        guard !pcm.isEmpty else {
            return TranscriptionResult(text: "", language: nil, segments: [],
                                       audioSeconds: 0, realTimeFactor: 0)
        }

        let loaded = try load(entry: entry, url: modelURL)
        let token = cancellation.begin()
        loaded.session.setCancellationToken(token)
        defer {
            loaded.session.clearCancellationToken()
            cancellation.end()
        }

        let started = Date()
        let capabilities = try loaded.model.capabilities
        let hint = Self.languageHint(requested, capabilities: capabilities)
        let options = RunOptions(
            task: .transcribe,
            timestamps: .auto,
            language: hint,
            vocabulary: loaded.model.supports(.vocabulary) ? vocabulary : [])
        let traits = ModelTraits(
            streaming: capabilities.supportsStreaming,
            longForm: loaded.model.supports(.longForm))
        let audioSeconds = Double(pcm.count) / Double(SpeechChunking.rate)
        log.info("Transcribing \(String(format: "%.1f", audioSeconds))s with \(entry.id, privacy: .public)")

        var transcripts: [Transcript] = []
        /// Start of each transcript's audio, in samples, for segment times.
        var offsets: [Int] = []
        switch Self.batchDecode(traits: traits, longFormChunking: true) {
        case .whole:
            progress(0.05, "Transcribing on this Mac…")
            transcripts = [try run(loaded.session, pcm, options)]
            offsets = [0]

        case .chunked:
            guard let vadModelURL else {
                throw TranscriptionError.modelMissing("voice activity")
            }
            var chunker = Chunker { try SileroScorer(path: vadModelURL) }
            var chunks = chunker.push(pcm)
            chunks += chunker.finish()
            var decoded = 0
            for chunk in chunks {
                if token.isCancelled { throw TranscriptionError.cancelled }
                offsets.append(decoded)
                transcripts.append(try run(loaded.session, chunk, options))
                decoded += chunk.count
                progress(min(0.95, Double(decoded) / Double(pcm.count)),
                         "Transcribing on this Mac…")
            }
        }

        if token.isCancelled { throw TranscriptionError.cancelled }
        progress(0.98, "Finishing the transcript…")

        let language = Self.agreedLanguage(transcripts) ?? hint
        let joined = transcripts.count == 1
            ? transcripts[0].text
            : SpeechChunking.joinTranscripts(transcripts.map(\.text))
        let cleaned = TranscriptText.postProcess(joined, language: language)
        let text = Self.echoesVocabulary(cleaned, vocabulary: vocabulary) ? "" : cleaned

        let segments = self.segments(transcripts: transcripts, offsets: offsets)
        let elapsed = max(Date().timeIntervalSince(started), 0.000_001)
        let realTimeFactor = audioSeconds / elapsed
        log.info("Transcribed \(String(format: "%.1f", audioSeconds))s in \(String(format: "%.2f", elapsed))s (\(String(format: "%.1f", realTimeFactor))x)")

        scheduleUnload()
        return TranscriptionResult(
            text: text,
            language: language,
            segments: segments,
            audioSeconds: audioSeconds,
            realTimeFactor: realTimeFactor)
    }

    // MARK: Model lifetime

    private func load(entry: ModelCatalog.Entry, url: URL) throws -> Loaded {
        if let loaded, loaded.id == entry.id { return loaded }
        loaded = nil
        do {
            let model = try Model(path: url.path)
            let session = try model.session()
            let loaded = Loaded(id: entry.id, model: model, session: session)
            self.loaded = loaded
            return loaded
        } catch let error as TranscribeError {
            throw TranscriptionError.engine(Self.describe(error))
        } catch {
            throw TranscriptionError.engine(error.localizedDescription)
        }
    }

    /// Unloads after five idle minutes, as Handy keeps its engine warm between
    /// dictations but does not pin the weights forever.
    private func scheduleUnload() {
        unloadTask?.cancel()
        let timeout = idleTimeout
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    // MARK: Runs

    private func run(_ session: Session, _ pcm: [Float], _ options: RunOptions) throws -> Transcript {
        do {
            return try session.run(pcm, options: options)
        } catch let error as TranscribeError {
            if case .aborted = error { throw TranscriptionError.cancelled }
            throw TranscriptionError.engine(Self.describe(error))
        } catch {
            throw TranscriptionError.engine(error.localizedDescription)
        }
    }

    /// Chunk times are relative to their own audio, so shift them back onto the
    /// meeting's timeline.
    private func segments(transcripts: [Transcript], offsets: [Int]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for (index, transcript) in transcripts.enumerated() {
            let offsetMs = Int64(Double(offsets.indices.contains(index) ? offsets[index] : 0)
                * 1000 / Double(SpeechChunking.rate))
            for segment in transcript.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                result.append(TranscriptSegment(
                    start: Double(segment.t0Ms + offsetMs) / 1000,
                    end: Double(segment.t1Ms + offsetMs) / 1000,
                    speaker: nil,
                    text: text))
            }
        }
        return result
    }

    // MARK: Policy helpers

    static func languageHint(_ requested: String?, capabilities: Capabilities) -> String? {
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty, requested != "auto" else { return nil }
        if !capabilities.languages.isEmpty, !capabilities.languages.contains(requested) {
            return nil
        }
        return requested
    }

    /// The language every chunk reported, if they all agree. Chunks that
    /// disagree leave it unknown rather than picking a winner.
    static func agreedLanguage(_ transcripts: [Transcript]) -> String? {
        agreement(transcripts.map(\.language))
    }

    /// The one language all runs reported, if they agree.
    static func agreement(_ languages: [String?]) -> String? {
        guard let first = languages.first ?? nil, !first.isEmpty, first != "auto" else {
            return nil
        }
        return languages.allSatisfy { $0 == first } ? first : nil
    }

    /// A model asked for custom words sometimes returns the words instead of
    /// the speech. Handy's rule: three or more terms found in list order, with
    /// next to nothing else in the text, is the list, not speech.
    static func echoesVocabulary(_ text: String, vocabulary: [String]) -> Bool {
        func words(_ value: String) -> [String] {
            value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
        }
        let said = words(text)
        var at = 0
        var found = 0
        var covered = 0
        for term in vocabulary.map(words) where !term.isEmpty {
            guard said.count >= term.count, at <= said.count - term.count else { continue }
            for offset in at...(said.count - term.count)
            where said[offset..<(offset + term.count)].elementsEqual(term) {
                at = offset + term.count
                found += 1
                covered += term.count
                break
            }
        }
        return found >= 3 && covered * 4 >= said.count * 3
    }

    static func describe(_ error: TranscribeError) -> String {
        switch error {
        case .modelFileNotFound(let detail), .modelLoad(let detail):
            return "The speech model could not be loaded. \(detail)"
        case .outOfMemory(let detail):
            return "There is not enough memory for this model. \(detail)"
        case .invalidArgument(let detail), .notImplemented(let detail),
             .badStructSize(let detail), .unsupported(let detail),
             .unsupportedRole(let detail), .inputTooShort(let detail),
             .inputTooLong(let detail), .versionMismatch(let detail):
            return detail
        case .backend(let detail):
            return "The speech engine could not start. \(detail)"
        case .busy(let detail):
            return detail
        case .aborted(let message, _):
            return message
        case .outputTruncated, .outputRepetition:
            return "The model's output repeated itself and was stopped."
        case .other(_, let message):
            return message
        }
    }
}

/// Thread-safe handle to the cancellation token of the run in flight.
private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: CancellationToken?

    func begin() -> CancellationToken {
        lock.lock()
        defer { lock.unlock() }
        let token = CancellationToken()
        self.token = token
        return token
    }

    func end() {
        lock.lock()
        token = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        token?.cancel()
        lock.unlock()
    }
}
