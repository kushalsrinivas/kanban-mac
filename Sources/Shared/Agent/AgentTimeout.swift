import Foundation

public enum AgentTimeoutError: LocalizedError, Equatable {
    case timedOut(seconds: Double)

    public var errorDescription: String? {
        "The request took too long, so nothing was changed. Try again."
    }
}

/// A bounded async operation. Cancels the child when the deadline wins, so a slow
/// model or server cannot leave the console spinning forever.
public enum AgentTimeout {
    public static func run<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw AgentTimeoutError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AgentTimeoutError.timedOut(seconds: seconds)
            }
            return result
        }
    }
}
