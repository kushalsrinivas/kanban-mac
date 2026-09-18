import Foundation

/// Server-sent events, used only for meeting job progress.
///
/// One short-lived stream per meeting being processed, opened when processing starts
/// and closed the moment the job reaches a terminal state. There is no always-on
/// socket: when nothing is processing, the app holds no connections at all.
/// If the stream cannot be opened, `JobMonitor` falls back to slow polling.
struct SSEClient {

    struct Event {
        var name: String?
        var data: String
    }

    enum Failure: Error {
        case notConfigured
        case http(Int)
        case transport(String)
    }

    let url: URL
    let token: String

    /// Async sequence of events. Ends when the server closes the stream.
    func events() -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                if !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                // No timeout: an SSE stream is meant to stay open for the job's lifetime.
                request.timeoutInterval = 3600

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 3600
                config.urlCache = nil
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: Failure.http(http.statusCode))
                        return
                    }

                    var name: String?
                    var payload = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            // Blank line terminates an event.
                            if !payload.isEmpty {
                                continuation.yield(Event(name: name, data: payload))
                            }
                            name = nil
                            payload = ""
                        } else if line.hasPrefix(":") {
                            continue   // comment / keep-alive
                        } else if line.hasPrefix("event:") {
                            name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            payload += payload.isEmpty ? chunk : "\n\(chunk)"
                        }
                    }
                    if !payload.isEmpty { continuation.yield(Event(name: name, data: payload)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Failure.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes each event's payload as JSON, skipping anything unparseable.
    func decoded<T: Decodable>(_ type: T.Type) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events() {
                        guard let data = event.data.data(using: .utf8),
                              let value = try? JSONDecoder().decode(T.self, from: data) else { continue }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
