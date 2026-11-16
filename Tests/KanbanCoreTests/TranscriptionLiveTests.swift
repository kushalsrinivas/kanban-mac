import XCTest

/// The real engine, against a real GGUF model and a real audio file. Skipped
/// unless the model paths are provided, so normal test runs stay offline:
///
///     KANBAN_TEST_MODEL=…/whisper-tiny-Q5_K_M.gguf \
///     KANBAN_TEST_VAD=…/silero-vad-v6.2-F32.gguf \
///     KANBAN_TEST_AUDIO=…/speech.aiff \
///     xcodebuild test -only-testing:KanbanTests/TranscriptionLiveTests
final class TranscriptionLiveTests: XCTestCase {

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func catalog() throws -> ModelCatalog {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "catalog", withExtension: "json"))
        return try ModelCatalog.decode(Data(contentsOf: url))
    }

    private func required(_ name: String) throws -> URL {
        guard let value = environment[name], !value.isEmpty else {
            throw XCTSkip("Set \(name) to run the live engine tests.")
        }
        return URL(fileURLWithPath: value)
    }

    func testTranscribesGeneratedSpeech() async throws {
        let modelURL = try required("KANBAN_TEST_MODEL")
        let audioURL = try required("KANBAN_TEST_AUDIO")
        let entry = try XCTUnwrap(catalog().entry("whisper-tiny"))

        let pcm = try AudioPCM.decode(url: audioURL)
        XCTAssertEqual(AudioPCM.sampleRate, 16_000)

        let engine = TranscriptionEngine()
        let result = try await engine.transcribe(
            pcm: pcm,
            entry: entry,
            modelURL: modelURL,
            vadModelURL: nil)
        await engine.unload()

        print("LIVE TRANSCRIPT [\(result.language ?? "-")]: \(result.text)")
        XCTAssertFalse(result.text.isEmpty)
        // Whisper-tiny is the smallest model in the catalog: it hears "kanban"
        // as "can-man", but the sentence must still be recognisably there.
        XCTAssertTrue(result.text.lowercased().contains("transcription"),
                      "the transcript should contain the spoken word")
        XCTAssertEqual(result.language, "en")
        XCTAssertFalse(result.segments.isEmpty)
        XCTAssertGreaterThan(result.realTimeFactor, 0)
        XCTAssertGreaterThan(result.audioSeconds, 3)
    }

    func testTranscribesAProvidedRecording() async throws {
        let modelURL = try required("KANBAN_TEST_MODEL")
        let recording = try required("KANBAN_TEST_RECORDING")
        let entry = try XCTUnwrap(catalog().entry("whisper-tiny"))

        let pcm = try AudioPCM.decode(url: recording)
        let engine = TranscriptionEngine()
        let result = try await engine.transcribe(
            pcm: pcm, entry: entry, modelURL: modelURL, vadModelURL: nil)
        await engine.unload()

        print("RECORDING TRANSCRIPT [\(result.language ?? "-")] \(result.audioSeconds)s: \(result.text)")
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertFalse(result.segments.isEmpty)
    }

    @MainActor
    func testDownloadsAndVerifiesAModel() async throws {
        guard environment["KANBAN_TEST_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set KANBAN_TEST_DOWNLOAD=1 to exercise the model downloader.")
        }
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-download-\(UUID().uuidString)", isDirectory: true)
        setenv("KANBAN_SUPPORT_DIR", support.path, 1)
        defer {
            unsetenv("KANBAN_SUPPORT_DIR")
            try? FileManager.default.removeItem(at: support)
        }

        let vad = try XCTUnwrap(catalog().vadEntry)
        let file = try XCTUnwrap(vad.defaultFile)
        let downloader = ModelDownloader()
        let installed = try await downloader.download(vad, file: file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(try ModelStorage.sha256(of: installed), file.sha256,
                       "the bytes on disk must match the catalogued hash")
        XCTAssertTrue(ModelStorage.isInstalled(vad, file: file))
    }

    func testSileroScoresSpeechFrames() throws {
        let vadURL = try required("KANBAN_TEST_VAD")
        let audioURL = try required("KANBAN_TEST_AUDIO")
        let pcm = try AudioPCM.decode(url: audioURL)
        let scorer = try SileroScorer(path: vadURL)
        XCTAssertEqual(scorer.frameSamples, 512, "Silero v6 scores 32 ms frames")

        let whole = pcm.count / scorer.frameSamples * scorer.frameSamples
        let probs = try scorer.score(Array(pcm.prefix(whole)))
        XCTAssertEqual(probs.count, whole / scorer.frameSamples)
        XCTAssertTrue(probs.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(probs.contains { $0 > 0.5 }, "speech should score as speech")
    }
}
