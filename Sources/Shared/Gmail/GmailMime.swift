import Foundation

// MARK: - Outgoing mail

public struct GmailOutgoingAttachment: Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var isInline: Bool
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data,
                isInline: Bool = false, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.isInline = isInline
        self.contentID = contentID
    }
}

public struct GmailOutgoingMessage: Sendable {
    public var from: GmailAddress
    public var to: [GmailAddress]
    public var cc: [GmailAddress]
    public var bcc: [GmailAddress]
    public var subject: String
    public var text: String
    public var html: String?
    public var attachments: [GmailOutgoingAttachment]
    public var inReplyTo: String?
    public var references: [String]
    public var threadID: String?
    public var date: Date

    public init(from: GmailAddress, to: [GmailAddress], cc: [GmailAddress] = [],
                bcc: [GmailAddress] = [], subject: String, text: String,
                html: String? = nil, attachments: [GmailOutgoingAttachment] = [],
                inReplyTo: String? = nil, references: [String] = [],
                threadID: String? = nil, date: Date = Date()) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.threadID = threadID
        self.date = date
    }
}

// MARK: - MIME

public enum GmailMime {

    // MARK: Parsing

    public static func message(from dto: GmailMessageDTO, accountID: UUID,
                               attachments existing: [GmailAttachment] = []) -> GmailMessage {
        let headers = headerMap(dto.payload?.headers ?? [])
        var text = ""
        var html: String?
        var attachments: [GmailAttachment] = []
        if let payload = dto.payload {
            walk(payload, accountID: accountID, messageID: dto.id,
                 text: &text, html: &html, attachments: &attachments)
        }
        // Keep a previously downloaded file path when the same attachment is
        // re-parsed during a sync.
        let paths = Dictionary(uniqueKeysWithValues: existing.compactMap { item in
            item.localPath.map { (item.id, $0) }
        })
        for index in attachments.indices {
            attachments[index].localPath = paths[attachments[index].id]
        }
        let labels = dto.labelIds ?? []
        let date = dto.internalDate.flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let subject = headers["subject"] ?? ""
        var bodyText = text
        if bodyText.isEmpty, let html, !html.isEmpty {
            bodyText = plainText(fromHTML: html)
        }
        if bodyText.isEmpty { bodyText = dto.snippet ?? "" }
        return GmailMessage(
            id: dto.id, threadID: dto.threadId ?? dto.id, accountID: accountID,
            labelIDs: labels, historyID: dto.historyId, internalDate: date,
            from: GmailAddress.parseList(headers["from"] ?? "").first
                ?? GmailAddress(email: ""),
            to: GmailAddress.parseList(headers["to"] ?? ""),
            cc: GmailAddress.parseList(headers["cc"] ?? ""),
            bcc: GmailAddress.parseList(headers["bcc"] ?? ""),
            replyTo: GmailAddress.parseList(headers["reply-to"] ?? ""),
            subject: subject, snippet: dto.snippet ?? "",
            bodyText: bodyText, bodyHTML: html,
            attachments: attachments,
            sizeEstimate: dto.sizeEstimate ?? 0,
            isDraft: labels.contains("DRAFT"),
            rfcMessageID: headers["message-id"],
            references: references(from: headers["references"]))
    }

    private static func walk(_ part: GmailPayloadDTO, accountID: UUID, messageID: String,
                             text: inout String, html: inout String?,
                             attachments: inout [GmailAttachment]) {
        let mime = (part.mimeType ?? "").lowercased()
        let filename = part.filename ?? ""
        let data = part.body?.data.flatMap { Data(base64URL: $0) }

        if mime.hasPrefix("multipart/"), let children = part.parts {
            for child in children {
                walk(child, accountID: accountID, messageID: messageID,
                     text: &text, html: &html, attachments: &attachments)
            }
            return
        }

        if mime == "text/plain" && filename.isEmpty && part.body?.attachmentId == nil {
            if let data, let value = String(data: data, encoding: .utf8) {
                text += (text.isEmpty ? "" : "\n\n") + value
            }
            return
        }
        if mime == "text/html" && filename.isEmpty && part.body?.attachmentId == nil {
            if let data, let value = String(data: data, encoding: .utf8) {
                html = (html ?? "") + value
            }
            return
        }

        if filename.isEmpty && part.body?.attachmentId == nil { return }
        let contentID = headerValue(part.headers, "content-id")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let disposition = headerValue(part.headers, "content-disposition") ?? ""
        let inline = disposition.lowercased().hasPrefix("inline")
            || (contentID != nil && mime.hasPrefix("image/"))
        attachments.append(GmailAttachment(
            id: part.body?.attachmentId ?? part.partId ?? UUID().uuidString,
            messageID: messageID, accountID: accountID,
            filename: filename.isEmpty ? "attachment" : filename,
            mimeType: part.mimeType ?? "application/octet-stream",
            size: part.body?.size ?? 0, contentID: contentID,
            isInline: inline))
    }

    public static func references(from raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .filter { !$0.isEmpty }
    }

    private static func headerMap(_ headers: [GmailHeaderDTO]) -> [String: String] {
        var out: [String: String] = [:]
        for header in headers {
            out[header.name.lowercased()] = decodeHeader(header.value)
        }
        return out
    }

    /// Gmail normally decodes headers, but archived mail still contains RFC 2047
    /// encoded words. Decode the common UTF-8 B/Q forms rather than showing them raw.
    public static func decodeHeader(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        guard let expression = try? NSRegularExpression(
            pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=") else { return raw }
        let source = raw as NSString
        let matches = expression.matches(in: raw, range: NSRange(location: 0, length: source.length))
        var result = raw
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let whole = Range(match.range(at: 0), in: result),
                  let encoding = Range(match.range(at: 2), in: result),
                  let payload = Range(match.range(at: 3), in: result) else { continue }
            let kind = result[encoding].lowercased()
            let text = String(result[payload])
            let decoded: String?
            if kind == "b" {
                decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
                    .flatMap { String(data: $0, encoding: .utf8) }
            } else {
                let unescaped = text.replacingOccurrences(of: "_", with: " ")
                let bytes = unescapeQuotedPrintable(unescaped)
                decoded = String(data: bytes, encoding: .utf8)
            }
            if let decoded { result.replaceSubrange(whole, with: decoded) }
        }
        return result
    }

    private static func unescapeQuotedPrintable(_ raw: String) -> Data {
        var data = Data()
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "=", let next = raw.index(index, offsetBy: 3, limitedBy: raw.endIndex) {
                let hex = String(raw[raw.index(after: index)..<next])
                if let byte = UInt8(hex, radix: 16) {
                    data.append(byte)
                    index = next
                    continue
                }
            }
            data.append(contentsOf: String(raw[index]).utf8)
            index = raw.index(after: index)
        }
        return data
    }

    private static func headerValue(_ headers: [GmailHeaderDTO]?, _ name: String) -> String? {
        headers?.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    /// A readable fallback for HTML-only mail. It also puts real body text into the
    /// local search index for messages that have no text/plain part.
    public static func plainText(fromHTML raw: String) -> String {
        var value = replace("<(script|style|iframe|object|embed|head)\\b[^>]*>.*?</\\1>",
                            in: raw, with: " ")
        value = replace("<br\\s*/?>", in: value, with: "\n")
        value = replace("</(p|div|li|tr|h[1-6])>", in: value, with: "\n")
        value = replace("<[^>]+>", in: value, with: " ")
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        let lines = value.components(separatedBy: .newlines)
            .map { line in
                line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    // MARK: Building

    public static func build(_ message: GmailOutgoingMessage) -> String {
        var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
        func addBlock(_ block: String) {
            let trimmed = block.hasSuffix("\r\n") ? String(block.dropLast(2)) : block
            lines.append(contentsOf: trimmed.components(separatedBy: "\r\n"))
        }

        add("From: \(address(message.from))")
        if !message.to.isEmpty { add("To: \(addressList(message.to))") }
        if !message.cc.isEmpty { add("Cc: \(addressList(message.cc))") }
        if !message.bcc.isEmpty { add("Bcc: \(addressList(message.bcc))") }
        add("Subject: \(encodeHeader(message.subject))")
        add("Date: \(rfc2822(message.date))")
        add("MIME-Version: 1.0")
        if let inReplyTo = message.inReplyTo {
            add("In-Reply-To: \(headerSafe(inReplyTo))")
        }
        if !message.references.isEmpty {
            add("References: \(message.references.map { "<\(headerSafe($0))>" }.joined(separator: " "))")
        }
        add("Message-ID: <\(UUID().uuidString)@meet.local>")

        let inline = message.attachments.filter(\.isInline)
        let regular = message.attachments.filter { !$0.isInline }
        let boundary = "meet-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        let body: String
        if let html = message.html, !html.isEmpty {
            if inline.isEmpty {
                body = alternativeBody(text: message.text, html: html, boundary: boundary)
            } else {
                let relatedBoundary = boundary + "-rel"
                let related = relatedBody(html: html, inline: inline,
                                          boundary: relatedBoundary)
                body = "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
                    + "--\(boundary)\r\n"
                    + "Content-Type: text/plain; charset=utf-8\r\n"
                    + "Content-Transfer-Encoding: base64\r\n\r\n"
                    + base64Lines(Data(message.text.utf8)) + "\r\n"
                    + "--\(boundary)\r\n"
                    + "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"\r\n\r\n"
                    + related + "\r\n"
                    + "--\(boundary)--\r\n"
            }
        } else {
            body = "Content-Type: text/plain; charset=utf-8\r\n"
                + "Content-Transfer-Encoding: base64\r\n\r\n"
                + base64Lines(Data(message.text.utf8)) + "\r\n"
        }

        if regular.isEmpty {
            addBlock(body)
        } else {
            let mixed = boundary + "-mix"
            add("Content-Type: multipart/mixed; boundary=\"\(mixed)\"")
            add("")
            add("--\(mixed)")
            addBlock(body)
            for attachment in regular {
                add("--\(mixed)")
                add("Content-Type: \(attachment.mimeType); name=\"\(parameterSafe(attachment.filename))\"")
                add("Content-Disposition: attachment; filename=\"\(parameterSafe(attachment.filename))\"")
                add("Content-Transfer-Encoding: base64")
                add("")
                add(base64Lines(attachment.data))
            }
            add("--\(mixed)--")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func alternativeBody(text: String, html: String,
                                        boundary: String) -> String {
        "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
            + "--\(boundary)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n"
            + base64Lines(Data(text.utf8)) + "\r\n"
            + "--\(boundary)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n"
            + base64Lines(Data(html.utf8)) + "\r\n"
            + "--\(boundary)--\r\n"
    }

    private static func relatedBody(html: String, inline: [GmailOutgoingAttachment],
                                    boundary: String) -> String {
        var text = "Content-Type: multipart/related; boundary=\"\(boundary)\"\r\n\r\n"
            + "--\(boundary)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n"
            + base64Lines(Data(html.utf8)) + "\r\n"
        for (index, attachment) in inline.enumerated() {
            let cid = attachment.contentID ?? "inline-\(index)@meet.local"
            text += "--\(boundary)\r\n"
                + "Content-Type: \(attachment.mimeType); name=\"\(parameterSafe(attachment.filename))\"\r\n"
                + "Content-Disposition: inline; filename=\"\(parameterSafe(attachment.filename))\"\r\n"
                + "Content-ID: <\(headerSafe(cid))>\r\n"
                + "Content-Transfer-Encoding: base64\r\n\r\n"
                + base64Lines(attachment.data) + "\r\n"
        }
        return text + "--\(boundary)--\r\n"
    }

    public static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }

    public static func address(_ value: GmailAddress) -> String {
        guard !value.name.isEmpty else { return headerSafe(value.email) }
        let name = encodeHeader(value.name)
        if name.hasPrefix("=?") { return "\(name) <\(headerSafe(value.email))>" }
        return "\"\(parameterSafe(value.name))\" <\(headerSafe(value.email))>"
    }

    public static func addressList(_ values: [GmailAddress]) -> String {
        values.map(address).joined(separator: ", ")
    }

    public static func encodeHeader(_ raw: String) -> String {
        let value = headerSafe(raw)
        guard value.unicodeScalars.contains(where: { !$0.isASCII }) else { return value }
        return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }

    private static func headerSafe(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func parameterSafe(_ raw: String) -> String {
        headerSafe(raw)
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\\", with: "/")
    }

    private static func rfc2822(_ date: Date) -> String {
        rfc2822Formatter.string(from: date)
    }

    private static let rfc2822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    // MARK: Sanitising

    /// Removes the active parts of a message before it reaches a WebView. Remote
    /// images are replaced, not fetched: the reader must never phone home.
    public static func sanitizeHTML(_ raw: String) -> String {
        var html = raw
        let rules: [(String, String)] = [
            ("<(script|style|iframe|object|embed|form|input|button|textarea)\\b[^>]*>.*?</\\1>", ""),
            ("<(script|style|iframe|object|embed|form|input|button|textarea|link|base|meta)\\b[^>]*/?>", ""),
            ("</?(html|head|body)\\b[^>]*>", ""),
            ("<!--.*?-->", ""),
            ("\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", ""),
            ("\\sping\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", ""),
            ("(href|src)\\s*=\\s*(\"|')?\\s*javascript:[^\"'\\s>]*", "$1=\"#\"")
        ]
        for (pattern, replacement) in rules {
            html = replace(pattern, in: html, with: replacement)
        }
        return replaceImages(in: html)
    }

    private static func replaceImages(in html: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: "<img\\b[^>]*>", options: [.caseInsensitive]) else { return html }
        let source = html as NSString
        let matches = expression.matches(in: html, range: NSRange(location: 0, length: source.length))
        var result = html
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let tag = String(result[range])
            let lower = tag.lowercased()
            let src = attribute("src", in: tag) ?? ""
            if src.lowercased().hasPrefix("cid:") || src.lowercased().hasPrefix("data:image/") {
                continue
            }
            if lower.contains("src=\"http") || lower.contains("src='http")
                || src.lowercased().hasPrefix("http") || src.hasPrefix("//") {
                result.replaceSubrange(range, with: "<span class=\"blocked-image\">[remote image blocked]</span>")
            }
        }
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
            options: [.caseInsensitive]) else { return nil }
        let range = NSRange(location: 0, length: (tag as NSString).length)
        guard let match = expression.firstMatch(in: tag, range: range) else { return nil }
        for index in 2..<match.numberOfRanges {
            let value = (tag as NSString).substring(with: match.range(at: index))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func replace(_ pattern: String, in value: String,
                                with template: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return value
        }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.stringByReplacingMatches(
            in: value, range: range, withTemplate: template)
    }

    /// Replaces CID references with downloaded inline data. Undownloaded images
    /// keep the cid scheme, which a blocked WebView simply renders as a gap.
    public static func inline(_ html: String, images: [String: Data]) -> String {
        var value = html
        for (contentID, data) in images {
            let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png"
                : data.starts(with: [0xFF, 0xD8]) ? "image/jpeg"
                : data.starts(with: [0x47, 0x49, 0x46]) ? "image/gif"
                : "application/octet-stream"
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            value = value.replacingOccurrences(of: "cid:\(contentID)", with: dataURL)
            value = value.replacingOccurrences(of: "cid:<\(contentID)>", with: dataURL)
        }
        return value
    }

    /// NSTextView exports inserted images as file URLs. Rewrite each to a CID that
    /// matches the multipart/related part the builder emits.
    public static func inlineFileReferences(_ html: String,
                                            attachments: [GmailDraftAttachment]) -> String {
        var value = html
        for attachment in attachments {
            let contentID = attachment.contentID ?? "\(attachment.id.uuidString)@meet.local"
            let path = attachment.localPath
            let fileURL = URL(fileURLWithPath: path).absoluteString
            for candidate in [fileURL, path, path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path] {
                value = value.replacingOccurrences(of: "src=\"\(candidate)\"",
                                                   with: "src=\"cid:\(contentID)\"")
                value = value.replacingOccurrences(of: "src='\(candidate)'",
                                                   with: "src='cid:\(contentID)'")
            }
        }
        return value
    }
}

// MARK: - Base64 URL

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var value = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters) else {
            return nil
        }
        self = data
    }
}
