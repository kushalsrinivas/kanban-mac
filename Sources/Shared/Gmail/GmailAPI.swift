import Foundation

// MARK: - DTOs

public struct GmailProfile: Decodable, Sendable {
    public var emailAddress: String
    public var messagesTotal: Int?
    public var threadsTotal: Int?
    public var historyId: String?
}

public struct GmailHeaderDTO: Decodable, Sendable {
    public var name: String
    public var value: String
}

public struct GmailBodyDTO: Decodable, Sendable {
    public var attachmentId: String?
    public var size: Int?
    public var data: String?
}

public struct GmailPayloadDTO: Decodable, Sendable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeaderDTO]?
    public var body: GmailBodyDTO?
    public var parts: [GmailPayloadDTO]?
}

public struct GmailMessageDTO: Decodable, Sendable {
    public var id: String
    public var threadId: String?
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: String?
    public var internalDate: String?
    public var sizeEstimate: Int?
    public var payload: GmailPayloadDTO?
}

public struct GmailMessageRef: Codable, Sendable {
    public var id: String
    public var threadId: String?
}

public struct GmailMessageListPage: Codable, Sendable {
    public var messages: [GmailMessageRef]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?
}

public struct GmailThreadDTO: Decodable, Sendable {
    public var id: String
    public var historyId: String?
    public var messages: [GmailMessageDTO]?
}

public struct GmailLabelDTO: Decodable, Sendable {
    public var id: String
    public var name: String?
    public var type: String?
    public var messagesTotal: Int?
    public var messagesUnread: Int?
    public var color: GmailLabelColorDTO?
}

public struct GmailLabelColorDTO: Decodable, Sendable {
    public var textColor: String?
    public var backgroundColor: String?
}

public struct GmailDraftDTO: Decodable, Sendable {
    public var id: String
    public var message: GmailMessageDTO?
}

public struct GmailServerDraft: Sendable {
    public var id: String
    public var message: GmailMessage

    public init(id: String, message: GmailMessage) {
        self.id = id
        self.message = message
    }
}

public struct GmailHistoryPage: Sendable {
    public var messageIDs: [String]
    public var deletedMessageIDs: [String]
    public var historyID: String?
    public var nextPageToken: String?

    public init(messageIDs: [String], deletedMessageIDs: [String],
                historyID: String?, nextPageToken: String?) {
        self.messageIDs = messageIDs
        self.deletedMessageIDs = deletedMessageIDs
        self.historyID = historyID
        self.nextPageToken = nextPageToken
    }
}

// MARK: - Errors

public enum GmailAPIError: LocalizedError, Equatable {
    case notConnected
    case unauthorized(String)
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval)
    case notFound(String)
    case historyExpired
    case invalidRequest(String)
    case server(Int, String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Connect a Gmail account first."
        case .unauthorized(let detail): return detail.isEmpty ? "Gmail rejected the sign-in." : detail
        case .forbidden(let detail): return detail.isEmpty ? "Gmail refused this action." : detail
        case .rateLimited(let delay): return "Gmail is rate limiting this account. Retrying in \(Int(delay))s."
        case .notFound(let detail): return detail.isEmpty ? "That message no longer exists in Gmail." : detail
        case .historyExpired: return "Gmail's change history expired; a full resync is needed."
        case .invalidRequest(let detail): return detail
        case .server(let status, let detail): return "Gmail returned \(status). \(detail)"
        case .transport(let detail): return detail
        }
    }

    public var isTransient: Bool {
        switch self {
        case .rateLimited, .transport: return true
        case .server(let status, _) where (500...599).contains(status): return true
        default: return false
        }
    }

    public var needsReauthentication: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

// MARK: - API protocol

/// The sync engine and the service only ever see this protocol. Tests replace it
/// with a fake, so no suite can reach Google.
public protocol GmailAPIProtocol: AnyObject, Sendable {
    func profile() async throws -> GmailProfile
    func labels() async throws -> [GmailLabel]
    func listMessages(pageToken: String?, maxResults: Int) async throws -> GmailMessageListPage
    func getMessage(id: String) async throws -> GmailMessage
    func getThread(id: String) async throws -> GmailThread
    func getAttachment(messageID: String, attachmentID: String) async throws -> Data
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    func untrashThread(id: String) async throws
    func deleteThread(id: String) async throws
    func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage
    func listDrafts() async throws -> [GmailServerDraft]
    func createDraft(raw: String, threadID: String?) async throws -> GmailServerDraft
    func updateDraft(id: String, raw: String, threadID: String?) async throws -> GmailServerDraft
    func deleteDraft(id: String) async throws
    func sendDraft(id: String) async throws -> GmailMessage
    func send(raw: String, threadID: String?) async throws -> GmailMessage
}

// MARK: - Client

public final class GmailAPIClient: GmailAPIProtocol, @unchecked Sendable {
    private let accountID: UUID
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String
    private let forceRefresh: @Sendable () async throws -> String
    private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    private let decoder = JSONDecoder()

    public init(accountID: UUID,
                accessToken: @escaping @Sendable () async throws -> String,
                forceRefresh: @escaping @Sendable () async throws -> String,
                session: URLSession? = nil) {
        self.accountID = accountID
        self.accessToken = accessToken
        self.forceRefresh = forceRefresh
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Reads

    public func profile() async throws -> GmailProfile {
        try await get("profile")
    }

    public func labels() async throws -> [GmailLabel] {
        struct Envelope: Decodable { var labels: [GmailLabelDTO]? }
        let envelope: Envelope = try await get("labels")
        return (envelope.labels ?? []).map {
            GmailLabel(id: $0.id,
                       name: $0.name ?? $0.id.capitalized,
                       type: $0.type ?? "user",
                       unreadCount: $0.messagesUnread ?? 0,
                       totalCount: $0.messagesTotal ?? 0,
                       colorText: $0.color?.textColor,
                       colorBackground: $0.color?.backgroundColor)
        }
    }

    public func listMessages(pageToken: String?, maxResults: Int) async throws -> GmailMessageListPage {
        var query = ["maxResults": String(maxResults), "includeSpamTrash": "true"]
        if let pageToken, !pageToken.isEmpty { query["pageToken"] = pageToken }
        let data = try await request(path: "messages", query: query)
        return try decode(GmailMessageListPage.self, from: data,
                          context: "message list")
    }

    public func getMessage(id: String) async throws -> GmailMessage {
        let data = try await request(path: "messages/\(escaped(id))",
                                     query: ["format": "full"])
        let dto = try decode(GmailMessageDTO.self, from: data, context: "message")
        return GmailMime.message(from: dto, accountID: accountID)
    }

    public func getThread(id: String) async throws -> GmailThread {
        let data = try await request(path: "threads/\(escaped(id))",
                                     query: ["format": "full"])
        let dto = try decode(GmailThreadDTO.self, from: data, context: "thread")
        let messages = (dto.messages ?? []).map {
            GmailMime.message(from: $0, accountID: accountID)
        }
        return GmailThread(
            summary: GmailThreadFactory.summary(accountID: accountID, threadID: dto.id,
                                                messages: messages),
            messages: messages)
    }

    public func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
        struct Body: Decodable { var data: String?; var size: Int? }
        let data = try await request(
            path: "messages/\(escaped(messageID))/attachments/\(escaped(attachmentID))")
        let body = try decode(Body.self, from: data, context: "attachment")
        guard let encoded = body.data, let decoded = Data(base64URL: encoded) else {
            throw GmailAPIError.invalidRequest("The attachment came back empty.")
        }
        return decoded
    }

    public func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
        var query = ["startHistoryId": startHistoryID, "maxResults": "500"]
        if let pageToken, !pageToken.isEmpty { query["pageToken"] = pageToken }
        let data: Data
        do {
            data = try await request(path: "history", query: query)
        } catch let error as GmailAPIError {
            if case .notFound = error { throw GmailAPIError.historyExpired }
            throw error
        }
        struct HistoryMessage: Decodable { var id: String?; var threadId: String? }
        struct Wrapper: Decodable { var message: HistoryMessage? }
        struct HistoryItem: Decodable {
            var id: String?
            var messages: [HistoryMessage]?
            var messagesAdded: [Wrapper]?
            var messagesDeleted: [Wrapper]?
            var labelsAdded: [Wrapper]?
            var labelsRemoved: [Wrapper]?
        }
        struct Envelope: Decodable {
            var history: [HistoryItem]?
            var nextPageToken: String?
            var historyId: String?
        }
        let envelope = try decode(Envelope.self, from: data, context: "history")
        var ids = Set<String>()
        var deleted = Set<String>()
        for item in envelope.history ?? [] {
            for ref in item.messages ?? [] { if let id = ref.id { ids.insert(id) } }
            for wrapper in (item.messagesAdded ?? []) + (item.labelsAdded ?? [])
                + (item.labelsRemoved ?? []) {
                if let id = wrapper.message?.id { ids.insert(id) }
            }
            for wrapper in item.messagesDeleted ?? [] {
                if let id = wrapper.message?.id { deleted.insert(id) }
            }
        }
        return GmailHistoryPage(messageIDs: Array(ids), deletedMessageIDs: Array(deleted),
                                historyID: envelope.historyId,
                                nextPageToken: envelope.nextPageToken)
    }

    // MARK: Mutations

    public func modifyThread(id: String, add: [String], remove: [String]) async throws {
        let body = try JSONEncoder().encode(["addLabelIds": add, "removeLabelIds": remove])
        _ = try await request(path: "threads/\(escaped(id))/modify", method: "POST", body: body)
    }

    public func trashThread(id: String) async throws {
        _ = try await request(path: "threads/\(escaped(id))/trash", method: "POST")
    }

    public func untrashThread(id: String) async throws {
        _ = try await request(path: "threads/\(escaped(id))/untrash", method: "POST")
    }

    public func deleteThread(id: String) async throws {
        _ = try await request(path: "threads/\(escaped(id))", method: "DELETE")
    }

    public func listDrafts() async throws -> [GmailServerDraft] {
        struct Envelope: Decodable { var drafts: [GmailDraftDTO]? }
        let data = try await request(path: "drafts", query: ["maxResults": "100"])
        let envelope = try decode(Envelope.self, from: data, context: "drafts")
        var out: [GmailServerDraft] = []
        for draft in envelope.drafts ?? [] {
            guard let messageDTO = draft.message else { continue }
            let message: GmailMessage
            if messageDTO.payload == nil {
                // drafts.list can return only ids; fetch the body before showing or
                // editing the draft.
                message = try await getMessage(id: messageDTO.id)
            } else {
                message = GmailMime.message(from: messageDTO, accountID: accountID)
            }
            out.append(GmailServerDraft(id: draft.id, message: message))
        }
        return out
    }

    public func createDraft(raw: String, threadID: String?) async throws -> GmailServerDraft {
        var payload: [String: Any] = ["message": ["raw": Data(raw.utf8).base64URLEncodedString()]]
        if let threadID {
            payload["message"] = ["raw": Data(raw.utf8).base64URLEncodedString(),
                                  "threadId": threadID]
        }
        let data = try await request(path: "drafts", method: "POST",
                                     body: try JSONSerialization.data(withJSONObject: payload))
        let dto = try decode(GmailDraftDTO.self, from: data, context: "draft")
        guard let dtoMessage = dto.message else {
            throw GmailAPIError.invalidRequest("Draft had no message.")
        }
        let message = dtoMessage.payload == nil
            ? try await getMessage(id: dtoMessage.id)
            : GmailMime.message(from: dtoMessage, accountID: accountID)
        return GmailServerDraft(id: dto.id, message: message)
    }

    public func updateDraft(id: String, raw: String,
                            threadID: String?) async throws -> GmailServerDraft {
        var bodyObject: [String: Any] = ["raw": Data(raw.utf8).base64URLEncodedString()]
        if let threadID { bodyObject["threadId"] = threadID }
        let data = try await request(
            path: "drafts/\(escaped(id))", method: "PUT",
            body: try JSONSerialization.data(withJSONObject: ["message": bodyObject]))
        let dto = try decode(GmailDraftDTO.self, from: data, context: "draft")
        guard let dtoMessage = dto.message else {
            throw GmailAPIError.invalidRequest("Draft had no message.")
        }
        let fetched = dtoMessage.payload == nil
            ? try await getMessage(id: dtoMessage.id)
            : GmailMime.message(from: dtoMessage, accountID: accountID)
        return GmailServerDraft(id: dto.id, message: fetched)
    }

    public func deleteDraft(id: String) async throws {
        _ = try await request(path: "drafts/\(escaped(id))", method: "DELETE")
    }

    public func sendDraft(id: String) async throws -> GmailMessage {
        let data = try await request(path: "drafts/\(escaped(id))/send", method: "POST")
        let dto = try decode(GmailMessageDTO.self, from: data, context: "sent message")
        if dto.payload == nil { return try await getMessage(id: dto.id) }
        return GmailMime.message(from: dto, accountID: accountID)
    }

    public func send(raw: String, threadID: String?) async throws -> GmailMessage {
        var payload: [String: Any] = ["raw": Data(raw.utf8).base64URLEncodedString()]
        if let threadID, !threadID.isEmpty { payload["threadId"] = threadID }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "messages/send", method: "POST", body: body)
        let dto = try decode(GmailMessageDTO.self, from: data, context: "sent message")
        if dto.payload == nil { return try await getMessage(id: dto.id) }
        return GmailMime.message(from: dto, accountID: accountID)
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request(path: path)
        return try decode(T.self, from: data, context: path)
    }

    private func request(path: String, query: [String: String] = [:],
                         method: String = "GET", body: Data? = nil) async throws -> Data {
        var attempts = 0
        var changedToken = false
        while true {
            attempts += 1
            var components = URLComponents(
                url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty {
                components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            guard let url = components.url else {
                throw GmailAPIError.invalidRequest("Bad Gmail URL.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(try await accessToken())",
                             forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw GmailAPIError.transport("Gmail returned an unexpected response.")
                }
                if (200..<300).contains(http.statusCode) { return data }
                let detail = errorDetail(data)
                switch http.statusCode {
                case 401 where !changedToken:
                    changedToken = true
                    _ = try await forceRefresh()
                    continue
                case 401:
                    throw GmailAPIError.unauthorized(detail)
                case 403:
                    if detail.lowercased().contains("rate") || detail.lowercased().contains("quota") {
                        let delay = retryDelay(http, attempt: attempts)
                        if attempts < 4 {
                            try await sleep(delay)
                            continue
                        }
                        throw GmailAPIError.rateLimited(retryAfter: delay)
                    }
                    throw GmailAPIError.forbidden(detail)
                case 404:
                    throw GmailAPIError.notFound(detail)
                case 429:
                    let delay = retryDelay(http, attempt: attempts)
                    if attempts < 4 {
                        try await sleep(delay)
                        continue
                    }
                    throw GmailAPIError.rateLimited(retryAfter: delay)
                case 400, 422:
                    throw GmailAPIError.invalidRequest(detail.isEmpty
                        ? "Gmail rejected the request." : detail)
                case 500...599:
                    if attempts < 4 {
                        try await sleep(Double(attempts) * 0.7)
                        continue
                    }
                    throw GmailAPIError.server(http.statusCode, detail)
                default:
                    throw GmailAPIError.server(http.statusCode, detail)
                }
            } catch let error as GmailAPIError {
                throw error
            } catch let error as URLError {
                let message = error.localizedDescription
                if attempts < 4 {
                    try await sleep(Double(attempts) * 0.7)
                    continue
                }
                throw GmailAPIError.transport(message)
            }
        }
    }

    private func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let raw = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(raw) {
            return min(60, max(1, seconds))
        }
        return min(30, pow(2, Double(attempt)))
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                      context: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GmailAPIError.transport("Could not read the Gmail \(context) response.")
        }
    }

    private func errorDetail(_ data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { var message: String?; var status: String? }
            var error: Inner?
        }
        if let envelope = try? decoder.decode(Envelope.self, from: data),
           let message = envelope.error?.message {
            return message
        }
        return ""
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

// MARK: - Thread summary

public enum GmailThreadFactory {
    public static func summary(accountID: UUID, threadID: String,
                               messages: [GmailMessage]) -> GmailThreadSummary {
        guard let latest = messages.max(by: { $0.internalDate < $1.internalDate }) else {
            return GmailThreadSummary(id: threadID, accountID: accountID)
        }
        var labels = Set<String>()
        var participants: [GmailAddress] = []
        var seen = Set<String>()
        for message in messages.sorted(by: { $0.internalDate > $1.internalDate }) {
            labels.formUnion(message.labelIDs)
            for address in [message.from] + message.to + message.cc
            where !address.email.isEmpty && seen.insert(address.email.lowercased()).inserted {
                participants.append(address)
            }
        }
        return GmailThreadSummary(
            id: threadID, accountID: accountID, subject: latest.subject,
            snippet: latest.snippet, lastDate: latest.internalDate,
            messageCount: messages.count,
            unreadCount: messages.filter(\.isUnread).count,
            starred: messages.contains(where: \.isStarred),
            hasAttachments: messages.contains(where: \.hasAttachments),
            labelIDs: Array(labels).sorted(), participants: participants)
    }
}
