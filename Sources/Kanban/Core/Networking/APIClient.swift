import Foundation

/// The single door to the VPS. Everything the Mac needs from the backend goes through
/// here: tasks, meetings, jobs, agent. The app never talks to Postgres, object storage
/// or a model server directly.
///
/// Deliberately stateless and cheap: an ephemeral URLSession, no cache, no persistent
/// connections, no background activity. Requests happen when the user does something.
actor APIClient {

    struct Configuration: Equatable, Sendable {
        var baseURL: URL
        var token: String
        var timeout: TimeInterval

        init(baseURL: URL, token: String, timeout: TimeInterval) {
            self.baseURL = Self.normalized(baseURL)
            self.token = token
            self.timeout = timeout
        }

        /// Versioned base, e.g. https://host/api/v1
        var apiRoot: URL {
            URL(string: baseURL.absoluteString + "/api/v1") ?? baseURL
        }

        /// A pasted URL often already ends in /api/v1; appending it again would make
        /// every route 404. Trailing slashes are dropped too.
        private static func normalized(_ url: URL) -> URL {
            var string = url.absoluteString
            while string.hasSuffix("/") { string.removeLast() }
            if string.lowercased().hasSuffix("/api/v1") { string.removeLast(7) }
            while string.hasSuffix("/") { string.removeLast() }
            return URL(string: string) ?? url
        }
    }

    private var configuration: Configuration?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func configure(_ configuration: Configuration?) {
        self.configuration = configuration
    }

    var isConfigured: Bool { configuration != nil }

    /// Exposed so the SSE client can build a job-events URL with the same credentials.
    var currentConfiguration: Configuration? { configuration }

    // MARK: Health

    func health() async -> HealthDTO? {
        guard configuration != nil else { return nil }
        do {
            return try await send(.get, "/health", timeout: 6)
        } catch {
            return nil
        }
    }

    struct HealthDTO: Codable {
        var status: String
        var database: Bool?
        var auth: Bool?
    }

    // MARK: Tasks

    func listTasks(includeArchived: Bool = false) async throws -> [TaskDTO] {
        try await send(.get, "/tasks?includeArchived=\(includeArchived)")
    }

    func summary() async throws -> SummaryDTO {
        try await send(.get, "/summary")
    }

    // MARK: Meetings

    func listMeetings(limit: Int = 100) async throws -> [MeetingDTO] {
        try await send(.get, "/meetings?limit=\(limit)")
    }

    func getMeeting(_ id: String) async throws -> MeetingDTO {
        try await send(.get, "/meetings/\(id)")
    }

    func createMeeting(_ body: CreateMeetingBody) async throws -> MeetingDTO {
        try await send(.post, "/meetings", body: body)
    }

    func deleteMeeting(_ id: String) async throws {
        try await sendVoid(.delete, "/meetings/\(id)")
    }

    func processMeeting(_ id: String) async throws -> JobDTO {
        try await send(.post, "/meetings/\(id)/process", body: EmptyBody())
    }

    func transcript(_ id: String) async throws -> TranscriptDTO {
        try await send(.get, "/meetings/\(id)/transcript")
    }

    func actionItems(_ id: String) async throws -> [ActionItemDTO] {
        try await send(.get, "/meetings/\(id)/action-items")
    }

    /// Uploads the recording. Progress is reported on the main actor as a 0...1 fraction.
    func uploadAudio(meetingID: String, fileURL: URL,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let configuration else { throw APIError.unsupported("no VPS configured") }
        let url = configuration.apiRoot.appendingPathComponent("meetings/\(meetingID)/audio")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600   // a long meeting on a slow uplink
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")

        let delegate = UploadProgressDelegate(onProgress: progress)
        // A dedicated session so the delegate does not outlive the upload.
        let uploadSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { uploadSession.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await uploadSession.upload(for: request, fromFile: fileURL)
            try Self.validate(response, data: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.offline(error.localizedDescription)
        }
    }

    // MARK: Jobs

    func job(_ id: String) async throws -> JobDTO {
        try await send(.get, "/jobs/\(id)")
    }

    // MARK: Agent

    func agentChat(_ body: AgentRequest) async throws -> AgentResponse {
        try await send(.post, "/agent/chat", body: body, timeout: 90)
    }

    func executeAgentAction(_ id: String) async throws -> AgentResponse {
        try await send(.post, "/agent/actions/\(id)/execute", body: EmptyBody())
    }

    // MARK: Raw (used by the outbox replay)

    /// Replays a queued mutation verbatim. Returns the response body for reconciliation.
    func replay(method: String, path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.timeoutInterval = configuration?.timeout ?? 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = configuration?.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        return data
    }

    // MARK: Transport

    private enum Method: String { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }
    private struct EmptyBody: Encodable {}

    /// One builder for every route, so replay and typed requests cannot drift.
    private func url(for path: String) throws -> URL {
        guard let configuration else { throw APIError.unsupported("no VPS configured") }
        // Path may carry a query string, so build by string rather than appendingPathComponent.
        guard let url = URL(string: configuration.apiRoot.absoluteString + path) else {
            // Local, not a server rejection: never let the outbox treat this as a
            // droppable 400.
            throw APIError.unsupported("bad path \(path)")
        }
        return url
    }

    private func request(_ method: Method, _ path: String, timeout: TimeInterval?) throws -> URLRequest {
        guard let configuration else { throw APIError.unsupported("no VPS configured") }
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout ?? configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ method: Method, _ path: String,
                                           timeout: TimeInterval? = nil) async throws -> Response {
        let (data, response) = try await perform(request(method, path, timeout: timeout))
        try Self.validate(response, data: data)
        return try Self.decode(Response.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: Method, _ path: String, body: Body, timeout: TimeInterval? = nil
    ) async throws -> Response {
        var request = try request(method, path, timeout: timeout)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        return try Self.decode(Response.self, from: data)
    }

    private func sendVoid(_ method: Method, _ path: String) async throws {
        let (data, response) = try await perform(request(method, path, timeout: nil))
        try Self.validate(response, data: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.offline(error.localizedDescription)
        } catch {
            throw APIError.offline(error.localizedDescription)
        }
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(0, "no HTTP response")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let detail = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.detail
            ?? String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 401, 403: throw APIError.unauthorized
        case 404: throw APIError.notFound(detail)
        case 400, 422: throw APIError.badRequest(detail)
        default: throw APIError.server(http.statusCode, detail)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T { return empty }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.server(200, "unreadable response: \(error.localizedDescription)")
        }
    }

    struct EmptyResponse: Decodable {}
}

/// Reports upload progress without retaining anything on the main actor.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
