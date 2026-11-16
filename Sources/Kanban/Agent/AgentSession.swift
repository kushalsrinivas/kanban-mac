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
    /// Locally proposed operations, keyed by the DTO id shown in the UI.
    private var localActions: [String: LocalAgentReply.Action] = [:]

    /// Raised when the server reports that task data changed, so the app can re-pull.
    /// The count is the number of operations applied in that turn.
    var onTasksChanged: ((Int) -> Void)?

    init(store: LocalStore, client: APIClient, settings: AppSettings, sync: SyncEngine) {
        self.store = store
        self.client = client
        self.settings = settings
        self.sync = sync
    }

    var isAvailable: Bool {
        settings.hasGeminiKey || (settings.backendIsConfigured && sync.connection.isOnline)
    }

    var statusLabel: String {
        if isBusy { return "WORKING" }
        if settings.hasGeminiKey { return "LOCAL · READY" }
        if !settings.backendIsConfigured { return "NOT CONFIGURED" }
        return sync.connection.label
    }

    func clear() {
        messages.removeAll()
        pending.removeAll()
        localActions.removeAll()
        lastError = nil
    }

    // MARK: Conversation

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        // Snapshot history BEFORE appending this turn: the request carries the new
        // message separately, and sending it twice confuses the model.
        let prior = Array(messages.suffix(12))
        messages.append(Message(kind: .user, text: trimmed))

        if settings.hasGeminiKey {
            await sendLocal(trimmed, prior: prior)
            return
        }

        guard settings.backendIsConfigured else {
            messages.append(Message(kind: .system, text:
                "Add a Gemini API key in Settings → Local AI to use the agent here, or set a server URL. Tasks and recording work without either."))
            return
        }

        isBusy = true
        defer { isBusy = false }

        let request = AgentRequest(
            message: trimmed,
            history: prior.compactMap { message in
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

    // MARK: Local Gemini agent

    private func sendLocal(_ text: String, prior: [Message]) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let gemini = GeminiClient(apiKey: settings.geminiAPIKey, model: settings.geminiModel)
            let reply = try await gemini.agentTurn(
                message: text,
                history: prior.compactMap { message in
                    switch message.kind {
                    case .user: return (role: "user", content: message.text)
                    case .agent: return (role: "assistant", content: message.text)
                    default: return nil
                    }
                },
                boardContext: boardContext(),
                meetingContext: meetingContext())
            applyLocal(reply)
        } catch let error as LocalAIError {
            lastError = error.localizedDescription
            messages.append(Message(kind: .failure, text: error.localizedDescription))
        } catch {
            lastError = "\(error)"
            messages.append(Message(kind: .failure, text: "\(error)"))
        }
    }

    private func boardContext() -> String {
        let tasks = store.tasks.filter { !$0.isArchived }
        guard !tasks.isEmpty else { return "empty" }
        return tasks.prefix(200).map { task in
            var line = "- id=\(task.id.uuidString) | \(task.title) | status=\(task.status.rawValue)"
            line += " | priority=\(task.priority.longLabel.lowercased())"
            if let due = task.dueDate { line += " | due=\(DateInput.iso(due))" }
            if !task.tags.isEmpty { line += " | tags=\(task.tags.joined(separator: ","))" }
            if !task.notes.isEmpty { line += " | notes=\(LocalAgentPlan.brief(task.notes, 80))" }
            return line
        }.joined(separator: "\n")
    }

    private func meetingContext() -> String {
        let meetings = store.meetings.prefix(10)
        guard !meetings.isEmpty else { return "none" }
        return meetings.map { meeting in
            var line = "- \(meeting.title) | \(DateInput.shortLabel(meeting.startedAt)) | \(meeting.status.rawValue)"
            if !meeting.summary.isEmpty { line += " | summary: \(LocalAgentPlan.brief(meeting.summary, 300))" }
            if !meeting.decisions.isEmpty { line += " | decisions: \(LocalAgentPlan.brief(meeting.decisions.joined(separator: "; "), 240))" }
            let items = meeting.actionItems.prefix(5)
                .map { "\($0.title) [\($0.state.rawValue)]" }
                .joined(separator: "; ")
            if !items.isEmpty { line += " | action items: \(items)" }
            return line
        }.joined(separator: "\n")
    }

    private func applyLocal(_ reply: LocalAgentReply) {
        var newPending: [AgentAction] = []
        var prepared: [String: LocalAgentReply.Action] = [:]
        for raw in reply.actions {
            guard let ready = LocalAgentPlan.action(raw, task: { store.task($0) }) else { continue }
            newPending.append(ready)
            prepared[ready.id] = raw
        }
        pending = newPending
        localActions = prepared

        let text = reply.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            messages.append(Message(kind: .agent, text: text))
        } else if newPending.isEmpty {
            messages.append(Message(kind: .agent, text: "Nothing to change."))
        }
        if !reply.actions.isEmpty, newPending.isEmpty {
            messages.append(Message(kind: .system,
                                    text: "The agent proposed an operation I could not validate, so it was dropped."))
        }
    }

    private func executeLocal(_ action: AgentAction) async {
        guard let raw = localActions[action.id] else { return }
        let taskID = raw.taskId.flatMap(UUID.init(uuidString:))
        let service = TaskService(store: store, syncEnabled: settings.backendIsConfigured)
        pending.removeAll { $0.id == action.id }
        do {
            switch raw.tool {
            case "create_task":
                guard let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { throw APIError.badRequest("title is required") }
                _ = try service.create(CreateTaskBody(
                    title: title,
                    notes: raw.notes,
                    status: (raw.status.flatMap(TaskStatus.parse) ?? .inbox).rawValue,
                    priority: (raw.priority.flatMap(Priority.parse) ?? .medium).longLabel.lowercased(),
                    due: raw.due,
                    tags: raw.tags ?? [],
                    source: TaskSource.agent.rawValue))
            case "update_task":
                guard let taskID else { throw APIError.badRequest("task id is required") }
                _ = try service.edit(taskID) { task in
                    if let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                        task.title = title
                    }
                    if let notes = raw.notes { task.notes = notes }
                    if let priority = raw.priority.flatMap(Priority.parse) { task.priority = priority }
                    if let due = raw.due {
                        task.dueDate = LocalAgentPlan.isClear(due) ? nil : DateInput.parse(due)
                    }
                    if let tags = raw.tags { task.tags = TaskService.normalise(tags) }
                }
            case "move_task":
                guard let taskID, let status = raw.status.flatMap(TaskStatus.parse) else {
                    throw APIError.badRequest("task id and status are required")
                }
                _ = try service.move(taskID, to: status, index: 0)
            case "complete_task":
                guard let taskID else { throw APIError.badRequest("task id is required") }
                _ = try service.complete(taskID)
            case "archive_task":
                guard let taskID else { throw APIError.badRequest("task id is required") }
                _ = try service.delete(taskID, hard: false)
            case "delete_task":
                guard let taskID else { throw APIError.badRequest("task id is required") }
                _ = try service.delete(taskID, hard: true)
            default:
                throw APIError.badRequest("unknown operation")
            }
            localActions[action.id] = nil
            messages.append(Message(kind: .applied, text: action.summary))
            onTasksChanged?(1)
        } catch {
            messages.append(Message(kind: .failure,
                                    text: "\(action.summary): \(error.localizedDescription)"))
        }
    }

    /// The user pressed EXECUTE on a proposed operation.
    func execute(_ action: AgentAction) async {
        if settings.hasGeminiKey, localActions[action.id] != nil {
            isBusy = true
            defer { isBusy = false }
            await executeLocal(action)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        pending.removeAll { $0.id == action.id }
        do {
            let response = try await client.executeAgentAction(action.id)
            messages.append(Message(kind: .applied, text: action.summary))
            await handle(response, suppressPendingReset: true)
        } catch let error as APIError {
            // A 409 means the server already executed it; retrying forever would be
            // noise. Auth failures need a settings change, not another tap.
            let permanent = error.statusCode == 409 || error.statusCode == 401
                || error.statusCode == 403
            if !permanent, !pending.contains(where: { $0.id == action.id }) {
                pending.insert(action, at: 0)
            }
            messages.append(Message(kind: .failure, text: "\(action.summary): \(error.localizedDescription)"))
        } catch {
            if !pending.contains(where: { $0.id == action.id }) { pending.insert(action, at: 0) }
            messages.append(Message(kind: .failure, text: "\(action.summary): \(error)"))
        }
    }

    func executeAll() async {
        // A bulk press must not quietly include a destructive operation unless the
        // user has turned the extra confirmation off.
        let batch = pending.filter {
            !$0.destructive || !settings.confirmDestructiveAgentActions
        }
        for action in batch { await execute(action) }
    }

    /// Operations a single bulk press may run.
    var bulkExecutableCount: Int {
        pending.filter { !$0.destructive || !settings.confirmDestructiveAgentActions }.count
    }

    func dismiss(_ action: AgentAction) {
        pending.removeAll { $0.id == action.id }
        localActions[action.id] = nil
        messages.append(Message(kind: .system, text: "Dismissed: \(action.summary)"))
    }

    func dismissAll() {
        guard !pending.isEmpty else { return }
        pending.removeAll()
        localActions.removeAll()
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
            onTasksChanged?((response.appliedActions ?? []).count)
        }
    }
}
