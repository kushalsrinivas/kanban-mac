import XCTest

/// The speech model catalog and the engine's decision rules. The catalog is the
/// same file Handy ships, so these tests also catch a bad copy: ids, revisions
/// and hashes have to survive decoding.
final class TranscriptionEngineTests: XCTestCase {

    private func catalogData() throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "catalog", withExtension: "json"),
                                "catalog.json must be a test resource")
        return try Data(contentsOf: url)
    }

    func testBundledCatalogDecodesHandysModelIds() throws {
        let catalog = try ModelCatalog.decode(catalogData())
        XCTAssertEqual(catalog.schema, 2)
        XCTAssertEqual(catalog.languageDetector, "lang-id-voxlingua107-ecapa")

        let small = try XCTUnwrap(catalog.entry("whisper-small"))
        XCTAssertEqual(small.family, "whisper")
        XCTAssertEqual(small.role, "asr")
        XCTAssertEqual(small.quant, "Q8_0")
        XCTAssertEqual(small.revision, "c0214bd34be9296695486f838e0142f900803159")
        XCTAssertEqual(small.languages.count, 99)
        XCTAssertTrue(small.capabilities.languageDetection)

        let defaultFile = try XCTUnwrap(small.defaultFile)
        XCTAssertEqual(defaultFile.filename, "whisper-small-Q8_0.gguf")
        XCTAssertEqual(defaultFile.size, 269_751_136)
        XCTAssertEqual(defaultFile.sha256,
                       "9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860")
    }

    func testCatalogOffersEveryWhisperModelAndItsQuants() throws {
        let catalog = try ModelCatalog.decode(catalogData())
        XCTAssertGreaterThanOrEqual(catalog.whisperModels.count, 12)
        XCTAssertNil(catalog.whisperModels.first { $0.role != "asr" })

        let tiny = try XCTUnwrap(catalog.entry("whisper-tiny"))
        XCTAssertEqual(Set(tiny.quantKeys), ["F32", "F16", "Q8_0", "Q6_K", "Q5_K_M", "Q4_K_M"])
        XCTAssertEqual(tiny.quantKeys.first, "Q8_0", "the default quant comes first")
        XCTAssertEqual(tiny.file(quant: "Q4_K_M")?.size, 43_621_792)
        XCTAssertEqual(tiny.file(quant: "nope")?.filename, "whisper-tiny-Q8_0.gguf",
                       "an unknown quant falls back to the default")
    }

    func testVADModelIsInTheCatalog() throws {
        let catalog = try ModelCatalog.decode(catalogData())
        let vad = try XCTUnwrap(catalog.vadEntry)
        XCTAssertEqual(vad.id, "silero-vad-v6.2")
        XCTAssertEqual(vad.defaultFile?.filename, "silero-vad-v6.2-F32.gguf")
        XCTAssertEqual(vad.defaultFile?.size, 1_241_056)
    }

    func testDownloadURLsPinTheRevisionAndTheMirror() throws {
        let catalog = try ModelCatalog.decode(catalogData())
        let entry = try XCTUnwrap(catalog.entry("whisper-tiny"))
        let file = try XCTUnwrap(entry.defaultFile)
        let urls = ModelStorage.downloadURLs(for: entry, file: file)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].absoluteString,
                       "https://huggingface.co/handy-computer/whisper-tiny-gguf/resolve/"
                       + "\(entry.revision)/whisper-tiny-Q8_0.gguf")
        XCTAssertEqual(urls[1].absoluteString,
                       "https://blob.handy.computer/handy-computer/whisper-tiny-gguf/"
                       + "\(entry.revision)/whisper-tiny-Q8_0.gguf")
    }

    func testWhisperTakesTheWholeClipAndOtherFamiliesAreChunked() {
        let whisper = TranscriptionEngine.ModelTraits(streaming: false, longForm: true)
        XCTAssertEqual(TranscriptionEngine.batchDecode(traits: whisper, longFormChunking: true),
                       .whole)
        XCTAssertEqual(TranscriptionEngine.batchDecode(traits: whisper, longFormChunking: false),
                       .whole)

        let shortWindow = TranscriptionEngine.ModelTraits(streaming: false, longForm: false)
        XCTAssertEqual(TranscriptionEngine.batchDecode(traits: shortWindow, longFormChunking: true),
                       .chunked)
        XCTAssertEqual(TranscriptionEngine.batchDecode(traits: shortWindow, longFormChunking: false),
                       .whole, "chunking off means one run")

        let streaming = TranscriptionEngine.ModelTraits(streaming: true, longForm: false)
        XCTAssertEqual(TranscriptionEngine.batchDecode(traits: streaming, longFormChunking: true),
                       .whole)
    }

    func testLanguageAgreementNeedsEveryChunkToAgree() {
        XCTAssertEqual(TranscriptionEngine.agreement(["en", "en", "en"]), "en")
        XCTAssertNil(TranscriptionEngine.agreement(["en", "fr"]))
        XCTAssertNil(TranscriptionEngine.agreement(["en", nil]))
        XCTAssertNil(TranscriptionEngine.agreement([nil]))
        XCTAssertNil(TranscriptionEngine.agreement(["auto"]))
        XCTAssertNil(TranscriptionEngine.agreement([]))
    }

    func testVocabularyEchoIsDropped() {
        XCTAssertTrue(TranscriptionEngine.echoesVocabulary(
            "Kubernetes, gRPC, Postgres", vocabulary: ["Kubernetes", "gRPC", "Postgres"]))
        XCTAssertFalse(TranscriptionEngine.echoesVocabulary(
            "Kubernetes, gRPC", vocabulary: ["Kubernetes", "gRPC"]),
            "two terms are not enough evidence to call the text a list")
        XCTAssertFalse(TranscriptionEngine.echoesVocabulary(
            "We shipped gRPC today.", vocabulary: ["Kubernetes", "gRPC"]))
        XCTAssertFalse(TranscriptionEngine.echoesVocabulary("anything", vocabulary: []))
    }

    func testSHA256MatchesTheCataloguedHash() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        // SHA-256 of "abc".
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try ModelStorage.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testResolveUsesTheSelectedModelOrAnyInstalledOne() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-resolve-\(UUID().uuidString)", isDirectory: true)
        setenv("KANBAN_SUPPORT_DIR", support.path, 1)
        defer {
            unsetenv("KANBAN_SUPPORT_DIR")
            try? FileManager.default.removeItem(at: support)
        }

        let catalog = try ModelCatalog.decode(catalogData())
        let tiny = try XCTUnwrap(catalog.entry("whisper-tiny"))
        let file = try XCTUnwrap(tiny.defaultFile)
        XCTAssertNil(ModelStorage.resolve(in: catalog, preferred: "whisper-small"))
        XCTAssertFalse(ModelStorage.hasAnyInstalledModel)

        // A file at the catalogued size is what "installed" means.
        try FileManager.default.createDirectory(
            at: ModelStorage.directory(for: tiny.id), withIntermediateDirectories: true)
        let url = ModelStorage.path(for: tiny, file: file)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(file.size))
        try handle.close()

        XCTAssertTrue(ModelStorage.hasAnyInstalledModel)
        XCTAssertEqual(ModelStorage.resolve(in: catalog, preferred: "whisper-small")?.entry.id,
                       "whisper-tiny", "a missing selection falls back to what is on disk")
        XCTAssertEqual(ModelStorage.resolve(in: catalog, preferred: "whisper-tiny")?.entry.id,
                       "whisper-tiny")
    }

    func testSpeechModelPathUsesTheModelIDAndFilename() throws {
        let catalog = try ModelCatalog.decode(catalogData())
        let entry = try XCTUnwrap(catalog.entry("whisper-tiny"))
        let file = try XCTUnwrap(entry.defaultFile)
        let url = ModelStorage.path(for: entry, file: file)
        XCTAssertEqual(url.lastPathComponent, "whisper-tiny-Q8_0.gguf")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "whisper-tiny")
    }
}
