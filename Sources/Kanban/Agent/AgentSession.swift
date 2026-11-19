import Foundation
import Observation
import os

/// The Mac side of the agent.
///
/// Reads are answered from the local store by `AgentEngine`, so the panel is useful
/// with no network and no API key. A model is consulted only when the deterministic
/// planner reports a miss. Writes are proposed and executed here, one confirmed
/// operation at a time, through the same `TaskService` the board uses.
@Observable
@MainActor
final class AgentSession {

    struct Message: Identifiable, Equatable {
        enum Kind: Equatable { case user, agent, applied, failure, system }
        var id = UUID()
        var kind: Kind
        var text: String
        var artifacts: [AgentArtifact] = []
        var suggestions: [String] = []
        var stage: AgentStage?
        var isStreaming = false
        /// The user stopped this turn; keep whatever text had arrived.
        var wasCancelled = false
        /// Set on a failure row so RETRY can rerun the exact prompt.
        var failedPrompt: String?
        var at: Date = Date()
    }

    private(set) var messages: [Message] = []
    private(set) var isBusy = false
    private(set) var stage: AgentStage?
    /// Server-proposed or locally-proposed operations awaiting EXECUTE.
    private(set) var pending: [AgentAction] = []
    private(set) var lastError: String?
    private(set) var canRetry = false

    /// Playback is part of the workspace, not a separate screen: a recording card
    /// and the meeting page share one player.
    let player = RecordingPlayer()

    private let store: LocalStore
    private let client: APIClient
    private let settings: AppSettings
    private let sync: SyncEngine
    private let model: AgentModelProvider
    /// The deadline for one model/server turn. Tests shorten it.
    private let requestTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.kanban.app", category: "agent")

    private var context = AgentContext()
    /// Locally validated operations, keyed by the action id shown on the card.
    private var operations: [String: AgentOperation] = [:]
    /// Scheduling proposals awaiting confirmation, keyed by the action id.
    private var scheduledDrafts: [String: ScheduledMeetingDraft] = [:]
    private var currentTask: Task<Void, Never>?
    private var requestID = UUID()
    private var failedAttempt: FailedAttempt?

    private struct FailedAttempt {
        var prompt: String
        var prior: [Message]
    }

    /// Raised when task data changed, so the app can refresh.
    var onTasksChanged: ((Int) -> Void)?
    /// Raised after a scheduled meeting lands, so the app can flash a confirmation.
    var onScheduledMeetingCreated: ((ScheduledMeeting) -> Void)?
    /// Performs a move the app already knows how to make.
    var onNavigate: ((AgentNavigation) -> Void)?
    /// Read-only events from the system calendars, supplied by AppModel.
    var externalScheduledMeetings: (() -> [ScheduledMeeting])?

    init(store: LocalStore, client: APIClient, settings: AppSettings, sync: SyncEngine,
         model: AgentModelProvider? = nil, requestTimeout: TimeInterval = 60) {
        self.store = store
        self.client = client
        self.settings = settings
        self.sync = sync
        self.model = model ?? GeminiModelProvider(settings: settings)
        self.requestTimeout = requestTimeout
    }

    // MARK: Status

    /// Local reads and local writes are always available.
    var isAvailable: Bool { true }

    /// A model can answer open-ended questions in addition to the deterministic tools.
    var freeFormAvailable: Bool {
        settings.hasGeminiKey || (settings.backendIsConfigured && sync.connection.isOnline)
    }

    var statusLabel: String {
        if isBusy { return "WORKING" }
        if settings.hasGeminiKey { return "LOCAL AI · READY" }
        if settings.backendIsConfigured {
            return sync.connection.isOnline ? "VPS · ONLINE" : "VPS OFFLINE · LOCAL"
        }
        return "LOCAL · READY"
    }

    var artifactCount: Int {
        messages.reduce(0) { $0 + $1.artifacts.count }
    }

    func clear() {
        currentTask?.cancel()
        currentTask = nil
        requestID = UUID()
        messages.removeAll()
        pending.removeAll()
        operations.removeAll()
        scheduledDrafts.removeAll()
        context.clear()
        lastError = nil
        stage = nil
        isBusy = false
        canRetry = false
        failedAttempt = nil
        player.stop()
    }

    // MARK: Conversation

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        // The request carries the new message separately, so history is everything
        // before it. Sending it twice confuses the model.
        let prior = Array(messages.suffix(12))
        messages.append(Message(kind: .user, text: trimmed))
        start(trimmed, prior: prior, appendUser: false)
    }

    func retry() {
        guard !isBusy, let attempt = failedAttempt else { return }
        // Replace the failure row rather than stacking another identical prompt.
        if let index = messages.lastIndex(where: { $0.failedPrompt == attempt.prompt }) {
            messages.remove(at: index)
        }
        failedAttempt = nil
        canRetry = false
        start(attempt.prompt, prior: attempt.prior, appendUser: false)
    }

    func cancel() {
        guard isBusy else { return }
        currentTask?.cancel()
        currentTask = nil
        requestID = UUID()
        markStreamingStopped()
        stage = nil
        isBusy = false
    }

    private func start(_ prompt: String, prior: [Message], appendUser: Bool) {
        isBusy = true
        lastError = nil
        canRetry = false
        failedAttempt = nil
        stage = .thinking
        if appendUser { messages.append(Message(kind: .user, text: prompt)) }

        let placeholder = Message(kind: .agent, text: "", stage: .thinking, isStreaming: true)
        messages.append(placeholder)

        let id = UUID()
        requestID = id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(prompt, prior: prior, placeholderID: placeholder.id, requestID: id)
        }
        currentTask = task
    }

    private func run(_ prompt: String, prior: [Message],
                     placeholderID: UUID, requestID id: UUID) async {
        defer {
            if requestID == id {
                isBusy = false
                stage = nil
                currentTask = nil
            }
        }

        do {
            var working = context
            let engine = makeEngine()
            let turn = engine.run(prompt, context: &working) { [weak self] next in
                guard let self, self.requestID == id else { return }
                self.stage = next
                self.updatePlaceholder(placeholderID) { $0.stage = next }
            }
            guard requestID == id, !Task.isCancelled else { return }
            context = working

            if let draft = turn.scheduledDraft {
                let summary = CalendarFormat.proposal(draft)
                if !pending.contains(where: { $0.summary == summary }) {
                    let action = AgentAction(id: UUID().uuidString, tool: "schedule_meeting",
                                             summary: summary)
                    scheduledDrafts[action.id] = draft
                    pending.append(action)
                }
            }

            var reply = turn.reply
            var artifacts = turn.artifacts
            var operations = turn.operations
            var serverActions: [AgentAction] = []
            var applied: [AgentAction] = []
            var tasksChanged = false

            if turn.fallback {
                stage = .processing("model")
                updatePlaceholder(placeholderID) { $0.stage = .processing("model") }
                let outcome = try await freeFormAnswer(prompt, prior: prior) { [weak self] text in
                    guard let self else { return }
                    await MainActor.run {
                        self.receiveStreamedText(text, placeholderID: placeholderID, requestID: id)
                    }
                }
                guard requestID == id, !Task.isCancelled else { return }
                if !outcome.text.isEmpty {
                    reply = reply.isEmpty ? outcome.text : reply + "\n\n" + outcome.text
                }
                operations.append(contentsOf: outcome.operations)
                serverActions = outcome.pending
                applied = outcome.applied
                tasksChanged = outcome.tasksChanged
                artifacts.append(contentsOf: outcome.artifacts)
            }

            guard requestID == id, !Task.isCancelled else { return }

            if let navigation = turn.navigation { onNavigate?(navigation) }

            for operation in operations {
                if self.operations[operation.id] == nil {
                    self.operations[operation.id] = operation
                    pending.append(operation.action)
                }
            }
            if !serverActions.isEmpty {
                for action in serverActions where !pending.contains(where: { $0.id == action.id }) {
                    pending.append(action)
                }
            }
            for action in applied {
                messages.append(Message(kind: .applied, text: action.summary))
            }

            if tasksChanged || !applied.isEmpty {
                await sync.pull()
                onTasksChanged?(max(1, applied.count))
            }

            let finalReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText: String
            if !finalReply.isEmpty {
                finalText = finalReply
            } else if !artifacts.isEmpty {
                finalText = ""
            } else if pending.isEmpty {
                finalText = "I couldn't find that in your board or meetings. Try one of the suggestions below."
            } else {
                finalText = "\(pending.count) operation\(pending.count == 1 ? "" : "s") ready for confirmation."
            }

            updatePlaceholder(placeholderID) { message in
                message.text = finalText
                message.artifacts = artifacts
                message.suggestions = turn.suggestions
                message.stage = nil
                message.isStreaming = false
                if turn.fallback && finalReply.isEmpty && artifacts.isEmpty && pending.isEmpty {
                    message.kind = .system
                }
            }

            if turn.autoPlay, let meeting = artifacts.compactMap(\.meeting).first {
                startPlayback(meeting)
            }
        } catch is CancellationError {
            guard requestID == id else { return }
            markStreamingStopped()
        } catch {
            guard requestID == id else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = message
            failedAttempt = FailedAttempt(prompt: prompt, prior: prior)
            canRetry = true
            updatePlaceholder(placeholderID) { row in
                row.kind = .failure
                row.text = message
                row.stage = nil
                row.isStreaming = false
                row.failedPrompt = prompt
            }
            if let api = error as? APIError, api.isTransient { await sync.refreshConnection() }
        }
    }

    private func updatePlaceholder(_ id: UUID, _ edit: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        edit(&messages[index])
    }

    /// Keep the partial answer visible, mark the turn stopped, and stop appending.
    private func markStreamingStopped() {
        guard let index = messages.lastIndex(where: { $0.isStreaming }) else { return }
        messages[index].isStreaming = false
        messages[index].stage = nil
        messages[index].wasCancelled = true
        if messages[index].text.isEmpty {
            messages[index].text = "Stopped before an answer was produced."
        }
    }

    /// Called from the model stream. Setting (not appending) the full partial text
    /// means an escape sequence completing cannot duplicate characters.
    private func receiveStreamedText(_ text: String, placeholderID: UUID, requestID id: UUID) {
        guard requestID == id else { return }
        stage = .responding
        updatePlaceholder(placeholderID) { message in
            message.text = text
            message.stage = .responding
        }
    }

    private func makeEngine() -> AgentEngine {
        AgentEngine(store: store, remotePlayback: settings.backendIsConfigured,
                    externalScheduledMeetings: { [weak self] in
                        self?.externalScheduledMeetings?() ?? []
                    })
    }

    private func mergedScheduledMeetings() -> [ScheduledMeeting] {
        var seen = Set<UUID>()
        var out: [ScheduledMeeting] = []
        for meeting in store.scheduledMeetings + (externalScheduledMeetings?() ?? []) {
            if seen.insert(meeting.id).inserted { out.append(meeting) }
        }
        return out
    }

    // MARK: Free-form fallback

    private struct FreeFormOutcome {
        var text = ""
        var operations: [AgentOperation] = []
        var pending: [AgentAction] = []
        var applied: [AgentAction] = []
        var artifacts: [AgentArtifact] = []
        var tasksChanged = false
    }

    private func freeFormAnswer(
        _ prompt: String, prior: [Message],
        onText: @Sendable @escaping (String) async -> Void
    ) async throws -> FreeFormOutcome {
        if settings.hasGeminiKey {
            let turns = history(prior)
            let board = boardContext()
            let meetings = meetingContext()
            let model = self.model
            let reply = try await AgentTimeout.run(seconds: requestTimeout) { @Sendable in
                try await model.reply(
                    prompt: prompt,
                    history: turns,
                    boardContext: board,
                    meetingContext: meetings,
                    onText: onText)
            }
            let operations = reply.actions.compactMap {
                LocalAgentPlan.operation($0, task: self.store.task)
            }
            return FreeFormOutcome(text: reply.reply, operations: operations)
        }

        if settings.backendIsConfigured, sync.connection.isOnline {
            let request = AgentRequest(
                message: prompt,
                history: history(prior).map { AgentRequest.Turn(role: $0.role, content: $0.content) },
                context: TaskService(store: store).summary(),
                clientVersion: AppInfo.version)
            let client = self.client
            let response = try await AgentTimeout.run(seconds: requestTimeout) { @Sendable in
                try await client.agentChat(request)
            }
            return FreeFormOutcome(
                text: response.reply ?? "",
                pending: response.pendingActions ?? [],
                applied: response.appliedActions ?? [],
                tasksChanged: response.tasksChanged ?? false)
        }

        return FreeFormOutcome()
    }

    private func history(_ prior: [Message]) -> [(role: String, content: String)] {
        prior.compactMap { message in
            switch message.kind {
            case .user: return (role: "user", content: message.text)
            case .agent: return (role: "assistant", content: message.text)
            default: return nil
            }
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
            if !task.notes.isEmpty { line += " | notes=\(AgentText.brief(task.notes, 80))" }
            return line
        }.joined(separator: "\n")
    }

    private func meetingContext() -> String {
        let meetings = store.meetings.prefix(10)
        guard !meetings.isEmpty else { return "none" }
        return meetings.map { meeting in
            var line = "- id=\(meeting.id.uuidString) | \(meeting.title) | \(DateInput.shortLabel(meeting.startedAt)) | \(meeting.status.rawValue)"
            if !meeting.summary.isEmpty { line += " | summary: \(AgentText.brief(meeting.summary, 300))" }
            if !meeting.decisions.isEmpty {
                line += " | decisions: \(AgentText.brief(meeting.decisions.joined(separator: "; "), 240))"
            }
            let items = meeting.actionItems.prefix(5)
                .map { "\($0.title) [\($0.state.rawValue)]" }
                .joined(separator: "; ")
            if !items.isEmpty { line += " | action items: \(items)" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: Execution

    /// The user pressed EXECUTE on a proposed operation.
    func execute(_ action: AgentAction) async {
        guard !isBusy else { return }
        if let draft = scheduledDrafts[action.id] {
            await executeScheduled(draft, action: action)
            return
        }
        guard let operation = operations[action.id] else {
            await executeServer(action)
            return
        }
        isBusy = true
        defer { isBusy = false }
        pending.removeAll { $0.id == action.id }
        operations.removeValue(forKey: operation.id)

        do {
            try apply(operation)
            messages.append(Message(kind: .applied, text: operation.summary))
            onTasksChanged?(1)
            logger.debug("agent applied \(operation.kind.rawValue, privacy: .public)")
        } catch {
            // A failed write is not silently dropped: the user can retry it from the
            // same card, and the failure is visible in the transcript.
            operations[operation.id] = operation
            if !pending.contains(where: { $0.id == action.id }) { pending.insert(action, at: 0) }
            messages.append(Message(kind: .failure,
                                    text: "\(operation.summary): \(error.localizedDescription)"))
            logger.error("agent operation \(operation.kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func apply(_ operation: AgentOperation) throws {
        try AgentExecutor.apply(operation, store: store,
                                syncEnabled: settings.backendIsConfigured)
    }

    private func executeScheduled(_ draft: ScheduledMeetingDraft,
                                  action: AgentAction) async {
        isBusy = true
        defer { isBusy = false }
        pending.removeAll { $0.id == action.id }
        scheduledDrafts.removeValue(forKey: action.id)

        let meeting = store.upsertScheduledMeeting(draft.materialise())
        context.focus(scheduledMeeting: meeting.id)
        messages.append(Message(kind: .applied, text: action.summary))
        messages.append(Message(
            kind: .agent,
            text: "Scheduled · \(meeting.title) · \(CalendarFormat.line(meeting)).",
            artifacts: [AgentArtifactBuilder.scheduledMeeting(meeting)],
            suggestions: ["Prepare me for it", "What's on my calendar?", "Open my calendar"]))
        onScheduledMeetingCreated?(meeting)
    }

    /// Public so an artifact can offer SCHEDULE without going back through the parser.
    func proposeSchedule(_ draft: ScheduledMeetingDraft) {
        let summary = CalendarFormat.proposal(draft)
        guard !pending.contains(where: { $0.summary == summary }) else { return }
        let action = AgentAction(id: UUID().uuidString, tool: "schedule_meeting",
                                 summary: summary)
        scheduledDrafts[action.id] = draft
        pending.append(action)
        messages.append(Message(kind: .system,
                                text: "Proposed: \(summary). Confirm it in PROPOSED OPERATIONS."))
    }

    func showSchedule() {
        let meetings = mergedScheduledMeetings().upcoming()
        if let first = meetings.first { context.focus(scheduledMeeting: first.id) }
        let artifact = AgentArtifactBuilder.scheduledList(meetings, title: "UPCOMING")
        messages.append(Message(
            kind: .agent,
            text: meetings.isEmpty ? "No scheduled meetings." : "\(meetings.count) scheduled meeting\(meetings.count == 1 ? "" : "s").",
            artifacts: [artifact],
            suggestions: meetings.isEmpty
                ? ["Schedule a meeting"]
                : ["Prepare me for the next one", "Open my calendar"]))
    }

    func showScheduledBrief(_ meetingID: UUID) {
        let all = mergedScheduledMeetings()
        guard let meeting = all.first(where: { $0.id == meetingID }) else { return }
        context.focus(scheduledMeeting: meetingID)
        let brief = MeetingMemory.brief(
            for: meeting, meetings: store.meetings,
            scheduledMeetings: all, tasks: store.tasks)
        messages.append(Message(kind: .agent,
                                text: "Brief · \(meeting.title) · \(CalendarFormat.line(meeting)).",
                                artifacts: [AgentArtifactBuilder.scheduledBrief(brief)],
                                suggestions: ["Open my calendar", "What's on my todo?"]))
    }

    private func executeServer(_ action: AgentAction) async {
        isBusy = true
        defer { isBusy = false }
        pending.removeAll { $0.id == action.id }
        do {
            let response = try await client.executeAgentAction(action.id)
            messages.append(Message(kind: .applied, text: action.summary))
            await handle(response, suppressPendingReset: true)
        } catch let error as APIError {
            let permanent = error.statusCode == 409 || error.statusCode == 401 || error.statusCode == 403
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
        let batch = pending.filter {
            !$0.destructive || !settings.confirmDestructiveAgentActions
        }
        for action in batch { await execute(action) }
    }

    var bulkExecutableCount: Int {
        pending.filter { !$0.destructive || !settings.confirmDestructiveAgentActions }.count
    }

    func dismiss(_ action: AgentAction) {
        pending.removeAll { $0.id == action.id }
        operations.removeValue(forKey: action.id)
        scheduledDrafts.removeValue(forKey: action.id)
        messages.append(Message(kind: .system, text: "Dismissed: \(action.summary)"))
    }

    func dismissAll() {
        guard !pending.isEmpty else { return }
        pending.removeAll()
        operations.removeAll()
        scheduledDrafts.removeAll()
        messages.append(Message(kind: .system, text: "Nothing was changed."))
    }

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
            for action in more where !pending.contains(where: { $0.id == action.id }) {
                pending.append(action)
            }
        }
        if response.tasksChanged == true || !(response.appliedActions ?? []).isEmpty {
            await sync.pull()
            onTasksChanged?((response.appliedActions ?? []).count)
        }
    }

    // MARK: Proposals from artifact cards

    func propose(_ operation: AgentOperation) {
        guard operations[operation.id] == nil else { return }
        // Two clicks on the same card must not create two identical proposals.
        guard !pending.contains(where: {
            $0.tool == operation.kind.rawValue && $0.summary == operation.summary
        }) else { return }
        operations[operation.id] = operation
        pending.append(operation.action)
        messages.append(Message(kind: .system,
                                text: "Proposed: \(operation.summary). Confirm it in PROPOSED OPERATIONS."))
    }

    func proposeComplete(_ taskID: UUID) {
        guard let task = store.task(taskID) else { return }
        propose(.complete(task))
    }

    func proposeCreate(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        propose(.create(title: trimmed, notes: nil, due: nil,
                        priority: nil, status: nil, tags: []))
    }

    // MARK: Artifact actions

    func summarize(_ meetingID: UUID) {
        guard let artifact = makeEngine().summaryArtifact(for: meetingID),
              let meeting = store.meeting(meetingID) else { return }
        context.focus(meeting: meetingID)
        messages.append(Message(
            kind: .agent,
            text: meeting.summary.isEmpty
                ? "“\(meeting.title)” · what the transcript contains."
                : "Summary · \(meeting.title) · \(DateInput.shortLabel(meeting.startedAt)).",
            artifacts: [artifact],
            suggestions: meetingFollowUps(meeting)))
    }

    func showTranscript(_ meetingID: UUID, query: String? = nil) {
        guard let artifact = makeEngine().transcriptArtifact(for: meetingID, query: query),
              let meeting = store.meeting(meetingID) else { return }
        context.focus(meeting: meetingID)
        messages.append(Message(kind: .agent,
                                text: "Transcript · \(meeting.title) · \(meeting.durationLabel).",
                                artifacts: [artifact],
                                suggestions: ["Summarize it"] + meetingFollowUps(meeting)))
    }

    func showActionItems(_ meetingID: UUID) {
        guard let artifact = makeEngine().actionItemsArtifact(for: meetingID),
              let meeting = store.meeting(meetingID) else { return }
        context.focus(meeting: meetingID)
        messages.append(Message(kind: .agent,
                                text: "Action items · \(meeting.title).",
                                artifacts: [artifact],
                                suggestions: ["Summarize it"] + meetingFollowUps(meeting)))
    }

    func showParticipants(_ meetingID: UUID) {
        guard let artifact = makeEngine().participantsArtifact(for: meetingID),
              let meeting = store.meeting(meetingID) else { return }
        context.focus(meeting: meetingID)
        messages.append(Message(kind: .agent,
                                text: "Participants · \(meeting.title).",
                                artifacts: [artifact],
                                suggestions: ["Summarize it", "What tasks came out of it?"]))
    }

    /// Follow-up chips that respect whether this meeting actually has audio.
    private func meetingFollowUps(_ meeting: Meeting) -> [String] {
        var out = ["What tasks came out of it?"]
        if makeEngine().recordingArtifact(for: meeting.id)?.playable == true {
            out.append("Play its recording")
        }
        out.append("Show the transcript")
        return out
    }

    func play(_ meeting: Meeting) {
        guard let artifact = makeEngine().recordingArtifact(for: meeting.id) else { return }
        context.focus(meeting: meeting.id)
        messages.append(Message(kind: .agent, text: playbackLine(meeting),
                                artifacts: [artifact],
                                suggestions: ["Summarize it", "What tasks came out of it?",
                                              "Show the transcript"]))
        startPlayback(meeting)
    }

    /// Plays from a transcript timestamp, which is how the summary's timecodes work.
    func play(_ meeting: Meeting, at seconds: TimeInterval) {
        guard let artifact = makeEngine().recordingArtifact(for: meeting.id) else { return }
        context.focus(meeting: meeting.id)
        messages.append(Message(kind: .agent,
                                text: "\(playbackLine(meeting)) Starting at \(Meeting.timecode(seconds)).",
                                artifacts: [artifact],
                                suggestions: ["Summarize it", "Show the transcript"]))
        startPlayback(meeting, at: seconds)
    }

    func togglePlayback(_ meeting: Meeting) {
        let engine = makeEngine()
        guard let artifact = engine.recordingArtifact(for: meeting.id) else { return }
        guard artifact.playable else {
            messages.append(Message(kind: .system, text: playbackLine(meeting)))
            return
        }
        if player.meetingID == meeting.id {
            player.toggle()
        } else {
            startPlayback(meeting)
        }
    }

    private func playbackLine(_ meeting: Meeting) -> String {
        let artifact = makeEngine().recordingArtifact(for: meeting.id)
        if artifact?.playable == true {
            return "\(meeting.title) · \(DateInput.shortLabel(meeting.startedAt)) · \(meeting.durationLabel)."
        }
        return "“\(meeting.title)” has no audio available. \(artifact?.unavailableReason ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    private func startPlayback(_ meeting: Meeting, at seconds: TimeInterval? = nil) {
        Task {
            let config = await client.currentConfiguration
            var remote: RecordingPlayer.Remote?
            if settings.backendIsConfigured, let id = meeting.remoteID, let config {
                remote = RecordingPlayer.Remote(
                    url: config.apiRoot.appendingPathComponent("meetings/\(id)/audio"),
                    token: config.token)
            }
            player.load(meeting: meeting, remote: remote)
            if let seconds {
                player.seekAndPlay(seconds)
            } else {
                player.play()
            }
        }
    }

}

// MARK: - Artifact convenience

private extension AgentArtifact {
    var playable: Bool {
        if case .recording(let recording) = payload { return recording.isPlayable }
        return false
    }

    var unavailableReason: String? {
        if case .recording(let recording) = payload { return recording.unavailableReason }
        return nil
    }
}
