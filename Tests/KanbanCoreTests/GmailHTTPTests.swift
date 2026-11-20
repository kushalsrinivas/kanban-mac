import XCTest

/// Exercises the real URLSession-based Gmail client and OAuth token endpoint with a
/// local URLProtocol. No test touches Google.
final class GmailHTTPTests: XCTestCase {

    private final class StubURLProtocol: URLProtocol {
        typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)
        private static let lock = NSLock()
        private static var handler: Handler?

        static func set(_ handler: @escaping Handler) {
            lock.lock(); self.handler = handler; lock.unlock()
        }

        static func reset() {
            lock.lock(); handler = nil; lock.unlock()
        }

        private static func current() -> Handler? {
            lock.lock(); defer { lock.unlock() }; return handler
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.current() else {
                client?.urlProtocol(self, didFailWithError: GmailAPIError.transport("no stub"))
                return
            }
            do {
                let (status, headers, data) = try handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        static func body(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private final class MemoryTokenStore: GmailTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [UUID: GmailTokens] = [:]
        private var clientID = ""
        private var secret = ""

        func save(_ tokens: GmailTokens, for accountID: UUID) {
            lock.lock(); self.tokens[accountID] = tokens; lock.unlock()
        }
        func load(for accountID: UUID) -> GmailTokens? {
            lock.lock(); defer { lock.unlock() }; return tokens[accountID]
        }
        func delete(for accountID: UUID) {
            lock.lock(); tokens[accountID] = nil; lock.unlock()
        }
        func saveClientID(_ clientID: String) {
            lock.lock(); self.clientID = clientID; lock.unlock()
        }
        func loadClientID() -> String? {
            lock.lock(); defer { lock.unlock() }; return clientID
        }
        func saveClientSecret(_ secret: String) {
            lock.lock(); self.secret = secret; lock.unlock()
        }
        func loadClientSecret() -> String? {
            lock.lock(); defer { lock.unlock() }; return secret
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private var session: URLSession!
    private let accountID = UUID()

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session.invalidateAndCancel()
        super.tearDown()
    }

    private func reply(_ status: Int, _ json: String,
                       headers: [String: String] = ["Content-Type": "application/json"]) {
        StubURLProtocol.set { _ in (status, headers, Data(json.utf8)) }
    }

    private func client(token: @escaping @Sendable () async throws -> String = { "access" },
                        refresh: @escaping @Sendable () async throws -> String = { "refreshed" })
        -> GmailAPIClient {
        GmailAPIClient(accountID: accountID, accessToken: token,
                       forceRefresh: refresh, session: session)
    }

    // MARK: Gmail API client

    func testProfileSendsBearerAndDecodes() async throws {
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.path, "/gmail/v1/users/me/profile")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"emailAddress":"me@example.com","messagesTotal":3,"historyId":"99"}"#.utf8))
        }
        let profile = try await client().profile()
        XCTAssertEqual(profile.emailAddress, "me@example.com")
        XCTAssertEqual(profile.historyId, "99")
    }

    func test401RefreshesOnceAndRetries() async throws {
        let refreshes = Counter()
        StubURLProtocol.set { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale" {
                return (401, ["Content-Type": "application/json"],
                        Data(#"{"error":{"message":"Invalid Credentials"}}"#.utf8))
            }
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"emailAddress":"me@example.com","historyId":"1"}"#.utf8))
        }
        let profile = try await client(
            token: { refreshes.read() == 0 ? "stale" : "fresh" },
            refresh: { refreshes.increment(); return "fresh" }
        ).profile()
        XCTAssertEqual(profile.emailAddress, "me@example.com")
        XCTAssertEqual(refreshes.read(), 1)
    }

    func testHistoryNotFoundBecomesHistoryExpired() async {
        reply(404, #"{"error":{"message":"Requested entity was not found"}}"#)
        do {
            _ = try await client().history(startHistoryID: "1", pageToken: nil)
            XCTFail("expected historyExpired")
        } catch {
            XCTAssertEqual(error as? GmailAPIError, .historyExpired)
        }
    }

    func testEmptyMessageListDecodes() async throws {
        reply(200, "{}")
        let page = try await client().listMessages(pageToken: nil, maxResults: 10)
        XCTAssertNil(page.messages)
        XCTAssertNil(page.nextPageToken)
    }

    func testSendIncludesThreadIDAndFetchesMissingPayload() async throws {
        StubURLProtocol.set { request in
            if request.url?.path == "/gmail/v1/users/me/messages/send" {
                let body = StubURLProtocol.body(of: request).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
                XCTAssertEqual(body?["threadId"] as? String, "t1")
                XCTAssertNotNil(body?["raw"] as? String)
                return (200, ["Content-Type": "application/json"],
                        Data(#"{"id":"sent1","threadId":"t1","labelIds":["SENT"]}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/gmail/v1/users/me/messages/sent1")
            XCTAssertTrue(request.url?.query?.contains("format=full") == true)
            return (200, ["Content-Type": "application/json"], Data("""
                {"id":"sent1","threadId":"t1","labelIds":["SENT"],"snippet":"Hello",
                 "payload":{"mimeType":"text/plain",
                   "headers":[{"name":"Subject","value":"Hello"}],
                   "body":{"data":"SGVsbG8"}}}
                """.utf8))
        }
        let sent = try await client().send(raw: "raw message", threadID: "t1")
        XCTAssertEqual(sent.id, "sent1")
        XCTAssertEqual(sent.subject, "Hello")
        XCTAssertEqual(sent.bodyText, "Hello")
    }

    func testRateLimitRetriesAfterRetryAfter() async throws {
        let attempts = Counter()
        StubURLProtocol.set { _ in
            attempts.increment()
            if attempts.read() == 1 {
                return (429, ["Content-Type": "application/json",
                              "Retry-After": "1"],
                        Data(#"{"error":{"message":"Rate limit exceeded"}}"#.utf8))
            }
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"emailAddress":"me@example.com","historyId":"1"}"#.utf8))
        }
        let started = Date()
        let profile = try await client().profile()
        XCTAssertEqual(profile.emailAddress, "me@example.com")
        XCTAssertEqual(attempts.read(), 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
    }

    func testAttachmentDecodesBase64URL() async throws {
        let payload = Data("attachment body".utf8)
        reply(200, #"{"data":"\#(payload.base64URLEncodedString())","size":15}"#)
        let data = try await client().getAttachment(messageID: "m1", attachmentID: "a1")
        XCTAssertEqual(data, payload)
    }

    // MARK: OAuth token endpoint

    func testOAuthRefreshSendsFormAndPreservesRefreshToken() async throws {
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
            let body = String(data: StubURLProtocol.body(of: request) ?? Data(),
                              encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("client_id=123-abc.apps.googleusercontent.com"))
            XCTAssertTrue(body.contains("refresh_token=old-refresh"))
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}"#.utf8))
        }
        let config = GmailOAuthConfig(
            clientID: "123-abc.apps.googleusercontent.com", clientSecret: "secret")
        let tokens = try await GmailOAuth.refresh("old-refresh", config: config,
                                                  session: session)
        XCTAssertEqual(tokens.accessToken, "new-access")
        XCTAssertEqual(tokens.refreshToken, "old-refresh")
        XCTAssertTrue(tokens.expiresAt > Date())
    }

    func testOAuthExchangeIncludesPKCEVerifier() async throws {
        StubURLProtocol.set { request in
            let body = String(data: StubURLProtocol.body(of: request) ?? Data(),
                              encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("code_verifier=verifier"))
            XCTAssertTrue(body.contains("code=auth-code"))
            XCTAssertTrue(body.contains("redirect_uri=http"))
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":60}"#.utf8))
        }
        let tokens = try await GmailOAuth.exchange(
            code: "auth-code", verifier: "verifier",
            redirectURI: "http://127.0.0.1:49152",
            config: GmailOAuthConfig(clientID: "123-abc.apps.googleusercontent.com"),
            session: session)
        XCTAssertEqual(tokens.accessToken, "access")
        XCTAssertEqual(tokens.refreshToken, "refresh")
    }

    func testOAuthRevokePostsToken() async {
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/revoke")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = String(data: StubURLProtocol.body(of: request) ?? Data(),
                              encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("token=refresh-token"))
            return (200, [:], Data())
        }
        await GmailOAuth.revoke("refresh-token", session: session)
    }

    func testOAuthErrorBodySurfaces() async {
        reply(400, #"{"error":"invalid_grant","error_description":"Token expired"}"#)
        do {
            _ = try await GmailOAuth.refresh(
                "bad", config: GmailOAuthConfig(clientID: "123-abc.apps.googleusercontent.com"),
                session: session)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Token expired"))
        }
    }

    // MARK: Token manager

    func testTokenManagerRefreshesExpiredTokenAndPersists() async throws {
        let store = MemoryTokenStore()
        store.save(GmailTokens(accessToken: "old",
                               refreshToken: "refresh",
                               expiresAt: Date().addingTimeInterval(-60)),
                   for: accountID)
        let refreshes = Counter()
        let manager = GmailTokenManager(
            accountID: accountID, store: store,
            config: { GmailOAuthConfig(clientID: "123-abc.apps.googleusercontent.com") },
            refresh: { token, _ in
                refreshes.increment()
                XCTAssertEqual(token, "refresh")
                return GmailTokens(accessToken: "new", refreshToken: "refresh",
                                   expiresAt: Date().addingTimeInterval(3600))
            })

        let first = try await manager.accessToken()
        XCTAssertEqual(first, "new")
        XCTAssertEqual(refreshes.read(), 1)
        XCTAssertEqual(store.load(for: accountID)?.accessToken, "new")

        let second = try await manager.accessToken()
        XCTAssertEqual(second, "new")
        XCTAssertEqual(refreshes.read(), 1)
    }

    func testTokenManagerUsesValidAccessTokenWithoutRefresh() async throws {
        let store = MemoryTokenStore()
        store.save(GmailTokens(accessToken: "valid", refreshToken: "refresh",
                               expiresAt: Date().addingTimeInterval(3600)),
                   for: accountID)
        let refreshes = Counter()
        let manager = GmailTokenManager(
            accountID: accountID, store: store,
            config: { GmailOAuthConfig(clientID: "123-abc.apps.googleusercontent.com") },
            refresh: { _, _ in refreshes.increment(); return GmailTokens(
                accessToken: "unused", refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600)) })
        let token = try await manager.accessToken()
        XCTAssertEqual(token, "valid")
        XCTAssertEqual(refreshes.read(), 0)
    }

    func testTokenManagerRequiresRefreshToken() async {
        let store = MemoryTokenStore()
        let manager = GmailTokenManager(
            accountID: accountID, store: store,
            config: { GmailOAuthConfig(clientID: "123-abc.apps.googleusercontent.com") })
        do {
            _ = try await manager.accessToken()
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? GmailAPIError, .notConnected)
        }
    }
}
