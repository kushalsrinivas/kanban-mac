import Foundation
import Observation

/// The Mac side of the agent: a console that sends text and renders what comes back.
///
/// All reasoning, tool execution and validation happen on the VPS. This type never
/// interprets an instruction, never touches the task store on the agent's behalf, and
/// never executes an operation without the user pressing EXECUTE.
@Observable
@MainActor
final class AgentSession {

    struct Message: Identifiable, Equatable {
        enum Kind: Equatable { case user, agent, applied, failure, system }
        var id = UUID()
        var kind: Kind
        var text: String
        var at: Date = Date()
    }

    private(set) var messages: [Message] = []
    private(set) var isBusy = false
    /// Operations the agent proposed, waiting on the user.
    private(set) var pending: [AgentAction] = []
    private(set) var lastError: String?

    private let store: LocalStore
    private let client: APIClient
    private let settings: AppSettings
    private let sync: SyncEngine

    /// Raised when the server reports that task data changed, so the app can re-pull.
    var onTasksChanged: (() -> Void)?

    init(store: LocalStore, client: APIClient, settings: AppSettings, sync: SyncEngine) {
        self.store = store
        self.client = client
        self.settings = settings
        self.sync = sync
    }

    var isAvailable: Bool { settings.backendIsConfigured && sync.connection.isOnline }

    var statusLabel: String {
        if isBusy { return "WORKING" }
        if !settings.backendIsConfigured { return "NOT CONFIGURED" }
        return sync.connection.label
    }

    func clear() {
        messages.removeAll()
        pending.removeAll()
        lastError = nil
    }

    // MARK: Conversation

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        messages.append(Message(kind: .user, text: trimmed))

        guard settings.backendIsConfigured else {
            messages.append(Message(kind: .system, text:
                "The agent runs on your VPS. Set the server URL in Settings to use it. Tasks and recording keep working without it."))
            return
        }

        isBusy = true
        defer { isBusy = false }

        let request = AgentRequest(
            message: trimmed,
            history: messages.suffix(12).compactMap { message in
                switch message.kind {
                case .user: return AgentRequest.Turn(role: "user", content: message.text)
                case .agent: return AgentRequest.Turn(role: "assistant", content: message.text)
                default: return nil
                }
            },
            context: TaskService(store: store).summary(),
            clientVersion: AppInfo.version)

        do {
            let response = try await client.agentChat(request)
            await handle(response)
        } catch let error as APIError {
            lastError = error.localizedDescription
            messages.append(Message(kind: .failure, text: error.localizedDescription))
            if error.isTransient { await sync.refreshConnection() }
        } catch {
            lastError = "\(error)"
            messages.append(Message(kind: .failure, text: "\(error)"))
        }
    }

    /// The user pressed EXECUTE on a proposed operation.
    func execute(_ action: AgentAction) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        pending.removeAll { $0.id == action.id }
        do {
            let response = try await client.executeAgentAction(action.id)
            messages.append(Message(kind: .applied, text: action.summary))
            await handle(response, suppressPendingReset: true)
        } catch let error as APIError {
            messages.append(Message(kind: .failure, text: "\(action.summary): \(error.localizedDescription)"))
        } catch {
            messages.append(Message(kind: .failure, text: "\(action.summary): \(error)"))
        }
    }

    func executeAll() async {
        for action in pending { await execute(action) }
    }

    func dismiss(_ action: AgentAction) {
        pending.removeAll { $0.id == action.id }
        messages.append(Message(kind: .system, text: "Dismissed: \(action.summary)"))
    }

    func dismissAll() {
        guard !pending.isEmpty else { return }
        pending.removeAll()
        messages.append(Message(kind: .system, text: "Nothing was changed."))
    }

    // MARK: Response handling

    private func handle(_ response: AgentResponse, suppressPendingReset: Bool = false) async {
        if let reply = response.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            messages.append(Message(kind: .agent, text: reply))
        }
        for applied in response.appliedActions ?? [] {
            messages.append(Message(kind: .applied, text: applied.summary))
        }
        if !suppressPendingReset {
            pending = response.pendingActions ?? []
        } else if let more = response.pendingActions {
            pending.append(contentsOf: more)
        }

        if response.tasksChanged == true || !(response.appliedActions ?? []).isEmpty {
            await sync.pull()
            onTasksChanged?()
        }
    }
}
