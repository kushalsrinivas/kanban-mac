import AppKit
import Foundation
import Network

/// Google's desktop OAuth flow: a loopback listener on 127.0.0.1, a one-time code,
/// PKCE, and a refresh token stored in the Keychain by `GmailLiveAPIFactory`.
@MainActor
final class GmailAuthController {

    struct Authorization: Sendable {
        var tokens: GmailTokens
        var email: String
        var name: String
    }

    func authorize(config: GmailOAuthConfig,
                   loginHint: String? = nil) async throws -> Authorization {
        guard config.isValid else { throw GmailOAuthError.invalidConfig }
        let server = GmailLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }

        let verifier = GmailPKCE.verifier()
        let challenge = GmailPKCE.challenge(for: verifier)
        let state = GmailPKCE.state()
        let redirect = GmailOAuthConfig.redirectURI(port: port)
        guard let url = GmailOAuth.authorizationURL(
            config: config, redirectURI: redirect, state: state, challenge: challenge,
            loginHint: loginHint) else {
            throw GmailOAuthError.invalidConfig
        }
        guard NSWorkspace.shared.open(url) else {
            throw GmailOAuthError.callback("Could not open a browser for Gmail sign-in.")
        }

        let callback = try await server.wait(timeout: 300)
        if let error = callback["error"] {
            let description = callback["error_description"] ?? error
            throw GmailOAuthError.callback(description)
        }
        guard callback["state"] == state else {
            throw GmailOAuthError.callback("The sign-in response did not match this request.")
        }
        guard let code = callback["code"], !code.isEmpty else {
            throw GmailOAuthError.callback("Google did not return an authorization code.")
        }
        let tokens = try await GmailOAuth.exchange(
            code: code, verifier: verifier, redirectURI: redirect, config: config)
        let profile = try await profile(accessToken: tokens.accessToken)
        return Authorization(tokens: tokens,
                             email: profile.email.isEmpty
                                ? "unknown@\(config.trimmedClientID)"
                                : profile.email,
                             name: profile.name)
    }

    /// Best-effort revocation. Local data deletion happens regardless of Google's
    /// answer; the token is removed from the Keychain by the caller.
    func revoke(_ tokens: GmailTokens?) async {
        guard let tokens else { return }
        await GmailOAuth.revoke(tokens.refreshToken ?? tokens.accessToken)
    }

    private func profile(accessToken: String) async throws -> (email: String, name: String) {
        var request = URLRequest(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw GmailOAuthError.exchange("Signed in, but Gmail profile could not be read.")
        }
        struct Profile: Decodable {
            var emailAddress: String?
            var messagesTotal: Int?
        }
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        let email = profile.emailAddress ?? ""
        return (email, email.components(separatedBy: "@").first ?? "")
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

// MARK: - Loopback listener

/// A one-request HTTP listener. It is bound to 127.0.0.1 only, uses a random port,
/// and shuts down as soon as the authorization response arrives.
final class GmailLoopbackServer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.kanban.gmail.oauth")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var resumed = false
    private var result: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = OnceFlag()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard ready.claim() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: GmailOAuthError.callback(
                            "Could not start the local sign-in listener."))
                    }
                case .failed(let error):
                    guard ready.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            if resumed {
                lock.unlock()
                continuation.resume(throwing: GmailOAuthError.cancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.finish(.failure(GmailOAuthError.callback(
                    "Gmail sign-in timed out. Try again.")))
            }
        }
    }

    func stop() {
        finish(.failure(GmailOAuthError.cancelled))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        if continuation == nil { self.result = result }
        lock.unlock()
        task?.cancel()
        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                self.respond(connection, head: head)
                return
            }
            if error != nil || isComplete || buffer.count > 64_000 {
                connection.cancel()
                self.finish(.failure(GmailOAuthError.callback(
                    "The local sign-in listener received an invalid request.")))
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        guard let firstLine = head.components(separatedBy: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let path = parts[1]
        guard path != "/favicon.ico" else {
            send(connection, status: "404 Not Found", body: "")
            return
        }
        let components = URLComponents(string: "http://127.0.0.1\(path)")
        let items = components?.queryItems ?? []
        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value ?? "" }
        if query["code"] == nil && query["error"] == nil {
            send(connection, status: "400 Bad Request",
                 body: "<p>This is the Gmail sign-in page. Return to Meet and try again.</p>")
            return
        }
        let body = """
            <!doctype html><html><head><meta charset="utf-8"><title>Meet</title>
            <style>body{font-family:-apple-system,system-ui,sans-serif;background:#f1f3eb;
            color:#15170f;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
            .card{border:1px solid #7c8271;padding:28px 32px;border-radius:16px;background:#e9ece2}
            h1{font-size:18px;margin:0 0 8px}p{margin:0;color:#555b4e}</style></head>
            <body><div class="card"><h1>Gmail connected</h1>
            <p>You can close this window and return to Meet.</p></div></body></html>
            """
        send(connection, status: "200 OK", body: body)
        finish(.success(query))
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
