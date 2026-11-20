import XCTest

final class GmailOAuthTests: XCTestCase {

    func testLoopbackServerAcceptsOneCallback() async throws {
        let server = GmailLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(port, 0)

        let url = URL(string: "http://127.0.0.1:\(port)/?code=abc123&state=xyz")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await server.wait(timeout: 5)
        XCTAssertEqual(callback["code"], "abc123")
        XCTAssertEqual(callback["state"], "xyz")
    }

    func testLoopbackServerRejectsWrongPathWithoutFinishing() async throws {
        let server = GmailLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }

        let wrong = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        _ = try? await URLSession.shared.data(from: wrong)

        let right = URL(string: "http://127.0.0.1:\(port)/?error=access_denied")!
        _ = try? await URLSession.shared.data(from: right)
        let callback = try await server.wait(timeout: 5)
        XCTAssertEqual(callback["error"], "access_denied")
    }

    func testOAuthConfigRejectsEmptyClientID() {
        XCTAssertFalse(GmailOAuthConfig(clientID: "").isValid)
        XCTAssertTrue(GmailOAuthConfig(
            clientID: "123-abc.apps.googleusercontent.com").isValid)
    }
}
