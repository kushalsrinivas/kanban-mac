import XCTest

/// Streaming is a transport + a tolerant JSON scanner. These tests prove the reply
/// becomes visible progressively and that cancelling the reader freezes the partial
/// text instead of letting more fragments through.
final class AgentStreamingTests: XCTestCase {

    private actor Collector {
        private(set) var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }

    func testReplyStreamsIncrementallyAndDecodesNormally() throws {
        var parser = AgentStreamParser()
        let chunks = ["{\"reply\":\"Hel", "lo wor", "ld", "\",\"actions\":[]}"]
        var updates: [String] = []
        for chunk in chunks {
            if let text = parser.ingest(chunk) { updates.append(text) }
        }

        XCTAssertEqual(updates, ["Hel", "Hello wor", "Hello world"])
        let reply = try JSONDecoder().decode(LocalAgentReply.self,
                                             from: Data(parser.rawJSON.utf8))
        XCTAssertEqual(reply.reply, "Hello world")
    }

    func testEscapesAndUnicodeSurviveFragmentBoundaries() {
        let json = #"{"thought":"plan","reply":"Say \"hi\"\nCaf\u00e9","actions":[]}"#
        var parser = AgentStreamParser()
        var updates: [String] = []
        for character in json {
            if let text = parser.ingest(String(character)) { updates.append(text) }
        }
        XCTAssertEqual(updates.last, "Say \"hi\"\nCafé")
        XCTAssertEqual(parser.reply, "Say \"hi\"\nCafé")
    }

    func testGeminiSSEChunkFeedsTheParser() throws {
        let sse = #"{"candidates":[{"content":{"parts":[{"text":"{\"reply\":\"Hel"}]}}]}"#
        let fragment = try XCTUnwrap(GeminiClient.text(fromSSEData: sse))
        var parser = AgentStreamParser()
        XCTAssertEqual(parser.ingest(fragment), "Hel")
    }

    func testTextBeforeReplyIsNotPublished() {
        var parser = AgentStreamParser()
        XCTAssertNil(parser.ingest("{\"thought\":\""))
        XCTAssertNil(parser.ingest("I will reply after checking"))
        XCTAssertEqual(parser.ingest("\",\"reply\":\"Done\""), "Done")
    }

    func testReaderPublishesAndReturnsTheCompleteObject() async throws {
        let json = "{\"reply\":\"Streamed answer\",\"actions\":[]}"
        let fragments = AsyncThrowingStream<String, Error> { continuation in
            for character in json { continuation.yield(String(character)) }
            continuation.finish()
        }
        let collector = Collector()
        let result = try await AgentStreamReader.read(fragments) { text in
            await collector.add(text)
        }
        XCTAssertEqual(result.reply, "Streamed answer")
        let updates = await collector.values
        XCTAssertEqual(updates.last, "Streamed answer")
        XCTAssertGreaterThan(updates.count, 1, "must publish more than the final string")
    }

    func testCancellationStopsPartialReply() async throws {
        let fragments = AsyncThrowingStream<String, Error> { continuation in
            let producer = Task {
                for chunk in ["{\"reply\":\"one ", "two ", "three ", "four\"}"] {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }

        let collector = Collector()
        let reader = Task {
            try await AgentStreamReader.read(fragments) { text in
                await collector.add(text)
            }
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        reader.cancel()
        do {
            _ = try await reader.value
            XCTFail("a cancelled stream must throw CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let frozen = await collector.values
        XCTAssertEqual(frozen, ["one "], "the partial answer must be kept and nothing after it")
        try await Task.sleep(nanoseconds: 300_000_000)
        let later = await collector.values
        XCTAssertEqual(later, frozen, "no fragment may arrive after cancellation")
        XCTAssertFalse(later.joined().contains("four"))
    }
}
