import Foundation

/// One streamed reply, plus the raw JSON it came from.
public struct AgentStreamResult: Sendable, Equatable {
    public var reply: String
    public var rawJSON: String

    public init(reply: String, rawJSON: String) {
        self.reply = reply
        self.rawJSON = rawJSON
    }
}

/// Extracts the `reply` field from a JSON object while it is still arriving.
///
/// The model is asked for `{"reply": "...", "actions": [...]}`. JSON fragments can
/// split an escape sequence or a surrogate pair, so this never decodes a partial
/// string with `JSONDecoder`; it walks the quote and emits the longest complete
/// prefix it can prove. The full object is decoded normally once the stream ends.
public struct AgentStreamParser: Sendable {
    private var buffer = ""
    private var published = ""
    public private(set) var reply = ""

    public var rawJSON: String { buffer }

    public init() {}

    /// Returns the full partial reply when it changed, so the UI can set the text
    /// rather than appending deltas that could duplicate after an escape completes.
    @discardableResult
    public mutating func ingest(_ fragment: String) -> String? {
        buffer += fragment
        guard let partial = Self.stringField("reply", in: buffer) else { return nil }
        reply = partial
        guard partial != published else { return nil }
        published = partial
        return partial
    }

    // MARK: JSON string scanning

    static func stringField(_ key: String, in raw: String) -> String? {
        let token = "\"\(key)\""
        guard let keyRange = raw.range(of: token) else { return nil }
        guard let colon = raw[keyRange.upperBound...].firstIndex(of: ":") else { return nil }
        var index = raw.index(after: colon)
        while index < raw.endIndex, raw[index].isWhitespace {
            index = raw.index(after: index)
        }
        guard index < raw.endIndex, raw[index] == "\"" else { return nil }
        index = raw.index(after: index)
        return scanString(from: index, in: raw)
    }

    private static func scanString(from start: String.Index, in raw: String) -> String {
        var result = ""
        var index = start
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\"" { return result }
            guard character == "\\" else {
                result.append(character)
                index = raw.index(after: index)
                continue
            }

            let escapeIndex = raw.index(after: index)
            guard escapeIndex < raw.endIndex else { return result }
            let escape = raw[escapeIndex]
            switch escape {
            case "\"": result.append("\""); index = raw.index(after: escapeIndex)
            case "\\": result.append("\\"); index = raw.index(after: escapeIndex)
            case "/": result.append("/"); index = raw.index(after: escapeIndex)
            case "n": result.append("\n"); index = raw.index(after: escapeIndex)
            case "t": result.append("\t"); index = raw.index(after: escapeIndex)
            case "r": result.append("\r"); index = raw.index(after: escapeIndex)
            case "b": result.append("\u{08}"); index = raw.index(after: escapeIndex)
            case "f": result.append("\u{0C}"); index = raw.index(after: escapeIndex)
            case "u":
                guard let decoded = scanUnicode(from: escapeIndex, in: raw) else { return result }
                result.unicodeScalars.append(decoded.scalar)
                index = decoded.end
            default:
                // An unknown escape or an incomplete one: keep what is proven and
                // wait for the next fragment.
                return result
            }
        }
        return result
    }

    private static func scanUnicode(
        from escapeIndex: String.Index, in raw: String
    ) -> (scalar: Unicode.Scalar, end: String.Index)? {
        let highStart = raw.index(after: escapeIndex)
        guard let highEnd = raw.index(highStart, offsetBy: 4, limitedBy: raw.endIndex),
              let high = UInt32(raw[highStart..<highEnd], radix: 16) else { return nil }

        // A high surrogate is only usable with the low surrogate that follows.
        if (0xD800...0xDBFF).contains(high) {
            guard highEnd < raw.endIndex, raw[highEnd] == "\\" else { return nil }
            let lowMarker = raw.index(after: highEnd)
            guard lowMarker < raw.endIndex, raw[lowMarker] == "u" else { return nil }
            let lowStart = raw.index(after: lowMarker)
            guard let lowEnd = raw.index(lowStart, offsetBy: 4, limitedBy: raw.endIndex),
                  let low = UInt32(raw[lowStart..<lowEnd], radix: 16),
                  (0xDC00...0xDFFF).contains(low) else { return nil }
            let value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { return nil }
            return (scalar, lowEnd)
        }

        guard let scalar = Unicode.Scalar(high) else { return nil }
        return (scalar, highEnd)
    }
}

/// Consumes raw model fragments, publishes the partial reply, and stops immediately
/// on task cancellation. The transport can be Gemini SSE or any other fragment feed.
public enum AgentStreamReader {
    public static func read(
        _ fragments: AsyncThrowingStream<String, Error>,
        onText: @Sendable (String) async -> Void
    ) async throws -> AgentStreamResult {
        var parser = AgentStreamParser()
        for try await fragment in fragments {
            if Task.isCancelled { throw CancellationError() }
            if let text = parser.ingest(fragment) {
                await onText(text)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        return AgentStreamResult(reply: parser.reply, rawJSON: parser.rawJSON)
    }
}
