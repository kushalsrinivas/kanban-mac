import Foundation
import Observation

/// Moves work between the local cache and the VPS.
///
/// Two directions, both on demand — there is no background timer and no polling loop:
///   outbound  flush the outbox (queued mutations) whenever something lands in it
///             or the connection comes back
///   inbound   pull tasks and meetings when the app activates or the user refreshes
@Observable
@MainActor
final class SyncEngine {

    enum Connection: Equatable {
        case unconfigured
        case checking
        case online
        case offline(String)

        var label: String {
            switch self {
            case .unconfigured: return "LOCAL ONLY"
            case .checking: return "CHECKING"
            case .online: return "CONNECTED"
            case .offline: return "OFFLINE"
            }
        }

        var isOnline: Bool { self == .online }
    }

    private(set) var connection: Connection = .unconfigured
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    /// Mutations still waiting to reach the VPS.
    private(set) var pendingCount = 0
    /// True when a pull found an empty server and refused to wipe a non-empty cache.
    private(set) var heldEmptyPull = false

    private let store: LocalStore
    private let client: APIClient
    private var drainTask: Task<Void, Never>?
    /// A pull and an outbox-triggered flush can overlap; replaying the same entry
    /// twice would duplicate creates.
    private var flushInFlight = false

    init(store: LocalStore, client: APIClient) {
        self.store = store
        self.client = client
        self.pendingCount = store.pendingOperationCount
        store.onOutboxChange = { [weak self] in
            guard let self else { return }
            self.pendingCount = self.store.pendingOperationCount
            self.scheduleFlush()
        }
    }

    // MARK: Configuration

    func configure(baseURL: String, token: String, timeout: TimeInterval) async {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        if let problem = ServerURLPolicy.problem(with: trimmed) {
            await client.configure(nil)
            connection = .unconfigured
            lastError = problem
            return
        }
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            // No server URL: a purely local task manager, not an error.
            await client.configure(nil)
            connection = .unconfigured
            lastError = nil
            return
        }
        await client.configure(.init(baseURL: url, token: token, timeout: timeout))
        lastError = nil
        connection = .checking
        await refreshConnection()
    }

    /// Only called on demand: app activation, settings change, manual retry, or a
    /// failed request. Never on a timer.
    func refreshConnection() async {
        guard await client.isConfigured else {
            connection = .unconfigured
            return
        }
        connection = await healthConnection()
        if connection.isOnline { scheduleFlush() }
    }

    private func healthConnection() async -> Connection {
        guard let health = await client.health() else {
            return .offline("no response")
        }
        // A reachable API with no token is not usable; saying CONNECTED there would
        // send every request into a 503 the user cannot explain.
        if health.auth == false {
            lastError = "The VPS has no API token configured (WC_API_TOKEN)."
            return .offline("server is unauthenticated")
        }
        if health.database == false {
            lastError = "The VPS cannot reach its database."
            return .offline("database unavailable")
        }
        lastError = nil
        return .online
    }

    // MARK: Outbound

    private func scheduleFlush() {
        guard drainTask == nil, !flushInFlight else { return }
        drainTask = Task { [weak self] in
            let held = await self?.flushOutbox() ?? true
            guard let self else { return }
            self.drainTask = nil
            // An entry that landed between the final loop check and here still needs a
            // drain; a held queue must not spin.
            if !held, self.store.pendingOperationCount > 0 { self.scheduleFlush() }
        }
    }

    /// Replays queued mutations in order, looping until the queue is empty. Entries
    /// queued while a request is in flight are picked up by the same drain rather than
    /// waiting for the next activation.
    ///
    /// Stops at the first failure worth retrying. A 400/422 rejection is dropped
    /// because the body itself is bad; auth, routing, conflict and transient failures
    /// hold the queue so a token rotation or a wrong base URL cannot delete edits.
    ///
    /// - Returns: true when the drain stopped with entries still queued.
    @discardableResult
    func flushOutbox() async -> Bool {
        guard await client.isConfigured, !flushInFlight else { return false }
        flushInFlight = true
        defer { flushInFlight = false }

        isSyncing = true
        defer {
            isSyncing = false
            pendingCount = store.pendingOperationCount
        }

        var lastHead: Int64?
        while await client.isConfigured, store.pendingOperationCount > 0, !Task.isCancelled {
            let pending = store.pendingOperations()
            guard let head = pending.first?.id else { break }
            // If the head entry could not be deleted (a failed local write), replaying
            // it again would spin forever.
            if head == lastHead { break }
            lastHead = head
            let sent = await replay(pending)
            if !sent { return true }
        }
        if store.pendingOperationCount == 0 { lastSyncedAt = Date() }
        return store.pendingOperationCount > 0
    }

    /// Sends one snapshot in order. Returns false when the queue was held back.
    private func replay(_ pending: [LocalStore.OutboxEntry]) async -> Bool {
        for entry in pending {
            do {
                _ = try await client.replay(method: entry.method, path: entry.path, body: entry.body)
                store.removeOutboxEntry(entry.id)
                connection = .online
            } catch let error as APIError {
                store.recordOutboxFailure(entry.id, error: error.localizedDescription)
                guard let status = error.statusCode else {
                    // Offline or no client: keep everything and retry later.
                    hold(error, path: entry.path)
                    return false
                }
                guard !OutboxPolicy.holdsQueue(status: status) else {
                    hold(error, path: entry.path)
                    return false
                }
                // Definitively rejected body: drop it rather than block the queue
                // forever. The next inbound pull reconciles the difference.
                store.removeOutboxEntry(entry.id)
                lastError = "Dropped \(entry.kind): \(error.localizedDescription)"
            } catch {
                store.recordOutboxFailure(entry.id, error: "\(error)")
                lastError = "\(error)"
                return false
            }
        }
        return true
    }

    private func hold(_ error: APIError, path: String) {
        if error.isTransient { connection = .offline(error.localizedDescription) }
        switch error {
        case .unauthorized:
            lastError = "Not authorised — check the API key in Settings. Queued changes are kept."
        case .notFound:
            lastError = "The server does not know \(path) — check the server URL. Queued changes are kept."
        default:
            lastError = "\(error.localizedDescription) Queued changes are kept."
        }
    }

    // MARK: Inbound

    /// Pulls server state. Local rows with queued mutations are preserved.
    ///
    /// An empty remote list is ambiguous — a fresh server, or a wrong server — so it
    /// never wipes a non-empty cache unless the caller explicitly confirms it.
    @discardableResult
    func pull(allowEmptyTasks: Bool = false) async -> Bool {
        guard await client.isConfigured else { return false }
        isSyncing = true
        defer { isSyncing = false }

        do {
            // Push first so the server has our edits before we overwrite the cache.
            await flushOutbox()
            guard pendingCount == 0 else { return false }

            // Archived tasks come down too: the cache has to hold them so RESTORE
            // and PURGE work. The board filters them out.
            let remoteTasks = try await client.listTasks(includeArchived: true)
            let incoming = remoteTasks.compactMap { $0.toTask() }
            if incoming.isEmpty, !store.tasks.isEmpty, !allowEmptyTasks {
                heldEmptyPull = true
                lastError = "The server returned no tasks. Kept this Mac's \(store.tasks.count) "
                    + "cached tasks. Use Settings → VPS → REPLACE WITH EMPTY SERVER to accept it."
                return false
            }
            heldEmptyPull = false
            store.replaceTasks(with: incoming)

            let remoteMeetings = try await client.listMeetings()
            for dto in remoteMeetings {
                let existing = UUID(uuidString: dto.id).flatMap { store.meeting($0) }
                    ?? store.meetings.first { $0.remoteID == dto.id }
                if let merged = dto.merged(into: existing) {
                    store.upsertMeeting(merged)
                }
            }

            connection = .online
            lastSyncedAt = Date()
            lastError = nil
            return true
        } catch let error as APIError {
            connection = error.isTransient ? .offline(error.localizedDescription) : connection
            lastError = error.localizedDescription
            return false
        } catch {
            lastError = "\(error)"
            return false
        }
    }
}
