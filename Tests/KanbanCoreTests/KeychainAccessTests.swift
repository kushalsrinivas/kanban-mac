import LocalAuthentication
import XCTest

/// The centralized Keychain manager: one backend read per item per session, serialized
/// concurrent requests, and cache invalidation on write/delete.
final class KeychainAccessTests: XCTestCase {

    private final class FakeBackend: KeychainBackend, @unchecked Sendable {
        var store: [String: Data] = [:]
        var reads = 0
        var writes = 0
        var deletes = 0
        var readDelay: TimeInterval = 0

        func read(service: String, account: String, context: LAContext?) -> Data? {
            reads += 1
            if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
            return store[service + "|" + account]
        }

        func write(service: String, account: String, data: Data) -> Bool {
            writes += 1
            store[service + "|" + account] = data
            return true
        }

        func delete(service: String, account: String) -> Bool {
            deletes += 1
            store[service + "|" + account] = nil
            return true
        }
    }

    func testRepeatedReadsUseTheSessionCache() {
        let backend = FakeBackend()
        backend.store["test|token"] = Data("secret".utf8)
        let access = KeychainAccess(backend: backend, missLifetime: 10)

        XCTAssertEqual(access.data(service: "test", account: "token")
            .flatMap { String(data: $0, encoding: .utf8) }, "secret")
        XCTAssertEqual(access.data(service: "test", account: "token")
            .flatMap { String(data: $0, encoding: .utf8) }, "secret")
        XCTAssertEqual(backend.reads, 1)
    }

    func testConcurrentReadsDoNotCreateConcurrentKeychainCalls() {
        let backend = FakeBackend()
        backend.store["test|token"] = Data("secret".utf8)
        backend.readDelay = 0.01
        let access = KeychainAccess(backend: backend, missLifetime: 10)

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            _ = access.data(service: "test", account: "token")
        }
        XCTAssertEqual(backend.reads, 1,
                       "a keychain prompt must not be opened once per concurrent caller")
    }

    func testWritesAndDeletesUpdateTheCache() {
        let backend = FakeBackend()
        let access = KeychainAccess(backend: backend, missLifetime: 0.01)

        XCTAssertTrue(access.set(Data("one".utf8), service: "test", account: "token"))
        XCTAssertEqual(access.data(service: "test", account: "token")
            .flatMap { String(data: $0, encoding: .utf8) }, "one")
        XCTAssertEqual(backend.reads, 0, "a fresh write should not need a read")

        XCTAssertTrue(access.remove(service: "test", account: "token"))
        XCTAssertNil(access.data(service: "test", account: "token"))
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertNil(access.data(service: "test", account: "token"))
        XCTAssertEqual(backend.deletes, 1)
    }

    func testInvalidationForcesAFreshRead() {
        let backend = FakeBackend()
        backend.store["test|token"] = Data("old".utf8)
        let access = KeychainAccess(backend: backend, missLifetime: 10)

        _ = access.data(service: "test", account: "token")
        backend.store["test|token"] = Data("rotated".utf8)
        access.invalidate(service: "test", account: "token")

        XCTAssertEqual(access.data(service: "test", account: "token")
            .flatMap { String(data: $0, encoding: .utf8) }, "rotated")
        XCTAssertEqual(backend.reads, 2)
    }

    func testMissingItemIsNotHammeredOnEveryRender() {
        let backend = FakeBackend()
        let access = KeychainAccess(backend: backend, missLifetime: 10)

        XCTAssertNil(access.data(service: "test", account: "missing"))
        XCTAssertNil(access.data(service: "test", account: "missing"))
        XCTAssertEqual(backend.reads, 1)
    }
}
