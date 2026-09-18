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
            case .unconfigured: return "LOCAL"
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

    private let store: LocalStore
    private let client: APIClient
    private var flushTask: Task<Void, Never>?

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
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true, url.host != nil else {
            await client.configure(nil)
            connection = .unconfigured
            return
        }
        await client.configure(.init(baseURL: url, token: token, timeout: timeout))
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
        connection = await client.health() ? .online : .offline("no response")
        if connection.isOnline { scheduleFlush() }
    }

    // MARK: Outbound

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.flushOutbox()
            self?.flushTask = nil
        }
    }

    /// Replays queued mutations in order. Stops at the first transient failure so
    /// ordering is preserved; permanent rejections are dropped with the reason kept.
    func flushOutbox() async {
        guard await client.isConfigured else { return }
        let pending = store.pendingOperations()
        guard !pending.isEmpty else {
            pendingCount = 0
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
            pendingCount = store.pendingOperationCount
        }

        for entry in pending {
            do {
                _ = try await client.replay(method: entry.method, path: entry.path, body: entry.body)
                store.removeOutboxEntry(entry.id)
                connection = .online
            } catch let error as APIError {
                store.recordOutboxFailure(entry.id, error: error.localizedDescription)
                if error.isTransient {
                    connection = .offline(error.localizedDescription)
                    lastError = error.localizedDescription
                    return   // keep order; try again when the connection returns
                }
                // Permanently rejected (400/404/409): drop it rather than blocking the
                // queue forever. The next inbound pull reconciles the difference.
                store.removeOutboxEntry(entry.id)
                lastError = "Dropped \(entry.kind): \(error.localizedDescription)"
            } catch {
                store.recordOutboxFailure(entry.id, error: "\(error)")
                return
            }
        }
        lastSyncedAt = Date()
    }

    // MARK: Inbound

    /// Pulls server state. Local rows with queued mutations are preserved.
    @discardableResult
    func pull() async -> Bool {
        guard await client.isConfigured else { return false }
        isSyncing = true
        defer { isSyncing = false }

        do {
            // Push first so the server has our edits before we overwrite the cache.
            await flushOutbox()
            guard pendingCount == 0 else { return false }

            let remoteTasks = try await client.listTasks()
            store.replaceTasks(with: remoteTasks.compactMap { $0.toTask() })

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
