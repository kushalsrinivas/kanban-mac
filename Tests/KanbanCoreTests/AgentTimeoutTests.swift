import XCTest

final class AgentTimeoutTests: XCTestCase {

    func testFastOperationReturnsTheValue() async throws {
        let value = try await AgentTimeout.run(seconds: 1) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSlowOperationThrowsAndDoesNotWaitForIt() async {
        let started = Date()
        do {
            _ = try await AgentTimeout.run(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return 1
            }
            XCTFail("expected a timeout")
        } catch let error as AgentTimeoutError {
            XCTAssertEqual(error, .timedOut(seconds: 0.05))
        } catch {
            XCTFail("expected AgentTimeoutError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6)
    }
}
