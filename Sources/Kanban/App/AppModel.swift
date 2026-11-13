import AppKit
import Observation
import SwiftUI
import WidgetKit

/// Single owner of app-wide state. Views stay dumb; lifecycle lives here.
@Observable
@MainActor
final class AppModel {

    /// Top-level navigation. Three sections, nothing more.
    enum Section: String, CaseIterable, Hashable {
        case tasks, meetings, agent
        var label: String { rawValue.uppercased() }
    }

    enum Inspector: Equatable {
        case hidden
        case task(UUID)
    }

    // Dependencies
    let store: LocalStore
    let settings: AppSettings
    let client: APIClient
    let sync: SyncEngine
    let recorder: MeetingRecorder
    let processor: MeetingProcessor
    let agent: AgentSession
    @ObservationIgnored private let notifications = NotificationCenterBridge()

    // Navigation
    var section: Section = .tasks
    var selectedMeeting: UUID?

    // Task UI state
    var inspector: Inspector = .hidden
    var selection: UUID?
    var focusedStatus: TaskStatus = .inbox
    var searchText: String = ""
    var isSearchActive = false
    var isPaletteOpen = false
    var quickAddText: String = ""
    var quickAddRequestID = 0
    var systemIsDark = false
    var transientMessage: String?
    /// Suggestion the user is confirming before it becomes a task.
    var pendingSuggestion: SuggestionDraft?
    /// Task awaiting an explicit delete confirmation. Set by the inspector and menu.
    var deletionRequest: UUID?
    /// The last reversible board action, surfaced as an UNDO button in the title bar.
    private(set) var undoAction: UndoAction?

    enum UndoAction: Equatable {
        case archived(UUID)
        case completed(UUID, TaskStatus)
    }

    var canUndo: Bool { undoAction != nil }
    var undoLabel: String {
        switch undoAction {
        case .archived: return "Undo Archive"
        case .completed: return "Undo Complete"
        case nil: return "Undo"
        }
    }

    @ObservationIgnored private var transientWorkItem: DispatchWorkItem?

    init(store: LocalStore? = nil, settings: AppSettings? = nil) {
        let store = store ?? LocalStore()
        let settings = settings ?? AppSettings.shared
        let client = APIClient()
        let sync = SyncEngine(store: store, client: client)

        self.store = store
        self.settings = settings
        self.client = client
        self.sync = sync
        self.recorder = MeetingRecorder(store: store, settings: settings)
        self.processor = MeetingProcessor(store: store, client: client, settings: settings)
        self.agent = AgentSession(store: store, client: client, settings: settings, sync: sync)

        store.onChange = { [weak self] _ in
            guard let self else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: KanbanWidgetKind.today)
            self.notifications.reschedule(for: self.store.tasks, enabled: self.settings.notificationsEnabled)
        }
        processor.onCompleted = { [weak self] meeting in
            guard let self else { return }
            self.flash("MEETING PROCESSED · \(meeting.suggestedCount) SUGGESTED")
            if self.settings.notifyOnMeetingProcessed {
                self.notifications.notifyMeetingProcessed(title: meeting.title,
                                                          suggestions: meeting.suggestedCount)
            }
        }
        agent.onTasksChanged = { [weak self] applied in
            guard let self else { return }
            self.flash("AGENT UPDATED THE BOARD")
            if applied > 0, self.settings.notifyOnAgentAction {
                self.notifications.notifyAgentAction(count: applied)
            }
        }
    }

    var theme: Theme {
        Theme.resolved(dark: settings.isDark(systemIsDark: systemIsDark), accent: settings.accent)
    }

    var visibleStatuses: [TaskStatus] {
        settings.showDoneColumn ? TaskStatus.allCases : TaskStatus.allCases.filter { $0 != .done }
    }

    var taskService: TaskService {
        TaskService(store: store, syncEnabled: settings.backendIsConfigured)
    }

    // MARK: Lifecycle

    func start() {
        settings.applyActivationPolicy()
        #if DEBUG
        if ProcessInfo.processInfo.environment["KANBAN_DEMO_DATA"] == "1" {
            DemoSeed.seedIfNeeded(store)
        }
        #endif
        store.flush()
        #if DEBUG
        ScreenshotDriver.runIfRequested(self)
        #endif
        Task {
            await connect()
            await recorder.probe()
        }
        if settings.notificationsEnabled {
            notifications.requestAuthorisation { [weak self] granted in
                guard let self else { return }
                if granted { self.notifications.reschedule(for: self.store.tasks, enabled: true) }
                else { self.settings.notificationsEnabled = false }
            }
        }
    }

    /// Applies the current server settings and does one connectivity check.
    func connect() async {
        await sync.configure(baseURL: settings.serverURL,
                             token: settings.apiKey,
                             timeout: settings.requestTimeout)
        if sync.connection.isOnline {
            await sync.pull()
            // Anything recorded while offline goes up now.
            processor.processPending()
        }
    }

    /// Called when the app becomes active. One cheap check, no polling.
    func applicationDidActivate() {
        guard settings.backendIsConfigured else { return }
        Task {
            await sync.refreshConnection()
            if sync.connection.isOnline {
                await sync.pull()
                processor.processPending()
            }
        }
    }

    func shutdown() {
        store.flush()
        if recorder.isRecording {
            // Never lose a recording to a quit: stop cleanly and keep the file.
            Task { await recorder.stop() }
        }
    }

    /// The terminal path used by `applicationShouldTerminate`: it waits for the
    /// recorder to finalise the file before the process exits.
    func shutdownAndWait() async {
        if recorder.isRecording {
            await recorder.stop()
        }
        store.flush()
    }

    func setNotifications(enabled: Bool) {
        settings.notificationsEnabled = enabled
        if enabled {
            notifications.requestAuthorisation { [weak self] granted in
                guard let self else { return }
                self.settings.notificationsEnabled = granted
                self.notifications.reschedule(for: self.store.tasks, enabled: granted)
                if !granted { self.flash("NOTIFICATIONS DENIED IN SYSTEM SETTINGS") }
            }
        } else {
            notifications.reschedule(for: [], enabled: false)
        }
    }

    // MARK: Board queries

    func tasks(in status: TaskStatus) -> [TaskItem] {
        let base = store.tasks(in: status)
        guard isSearchActive, !searchText.isEmpty else { return base }
        return base.filter { $0.matches(query: searchText) }
    }

    var searchResultCount: Int {
        guard isSearchActive, !searchText.isEmpty else { return 0 }
        return visibleStatuses.reduce(0) { $0 + tasks(in: $1).count }
    }

    var selectedTask: TaskItem? { selection.flatMap { store.task($0) } }

    /// Total suggestions awaiting review across every processed meeting.
    var openSuggestionCount: Int {
        store.meetings.reduce(0) { $0 + $1.suggestedCount }
    }

    // MARK: Task intents

    @discardableResult
    func quickAdd(_ raw: String, into status: TaskStatus? = nil) -> TaskItem? {
        let parsed = QuickParse.parse(raw)
        guard !parsed.title.isEmpty else { return nil }
        do {
            let created = try taskService.create(CreateTaskBody(
                title: parsed.title,
                status: (parsed.status ?? status ?? settings.defaultStatus).rawValue,
                priority: (parsed.priority ?? settings.defaultPriority).longLabel.lowercased(),
                due: parsed.due.map(DateInput.iso),
                tags: parsed.tags,
                source: TaskSource.manual.rawValue))
            selection = created.id
            focusedStatus = created.status
            return created
        } catch {
            flash("COULD NOT CREATE TASK")
            return nil
        }
    }

    func newTask() {
        section = .tasks
        isSearchActive = false
        quickAddRequestID += 1
    }

    func toggleSearch() {
        section = .tasks
        isSearchActive.toggle()
        if !isSearchActive { searchText = "" }
    }

    func openInspector(for id: UUID) {
        section = .tasks
        selection = id
        inspector = .task(id)
    }

    func closeInspector() { inspector = .hidden }

    func focus(status: TaskStatus) {
        section = .tasks
        focusedStatus = status
        if let first = tasks(in: status).first {
            selection = first.id
            if case .task = inspector { inspector = .task(first.id) }
        } else {
            selection = nil
        }
    }

    func moveSelection(to status: TaskStatus) {
        guard let id = selection else { return }
        do {
            try taskService.move(id, to: status, index: 0)
            focusedStatus = status
            flash("MOVED TO \(status.label)")
        } catch {
            flash("COULD NOT MOVE TASK")
        }
    }

    func completeSelection() {
        guard let id = selection, let task = store.task(id) else { return }
        do {
            if task.isDone {
                try taskService.reopen(id)
                undoAction = nil
                flash("REOPENED")
            } else {
                try taskService.complete(id)
                undoAction = .completed(id, task.status)
                flash("COMPLETED", duration: 5)
            }
        } catch {
            flash("COULD NOT UPDATE TASK")
        }
    }

    func archiveSelection() {
        guard let id = selection, let task = store.task(id) else { return }
        let next = neighbour(of: id)
        do {
            try taskService.delete(id, hard: false)
            selection = next
            if next == nil, case .task = inspector { inspector = .hidden }
            undoAction = .archived(id)
            flash("ARCHIVED \(task.title.uppercased().prefix(24))", duration: 5)
        } catch {
            flash("COULD NOT ARCHIVE TASK")
        }
    }

    func undoLast() {
        guard let action = undoAction else { return }
        undoAction = nil
        do {
            switch action {
            case .archived(let id):
                try taskService.unarchive(id)
                selection = id
                openInspector(for: id)
                flash("RESTORED")
            case .completed(let id, let status):
                try taskService.reopen(id, to: status)
                selection = id
                focusedStatus = status
                flash("REOPENED")
            }
        } catch {
            flash("COULD NOT UNDO")
        }
    }

    func deleteSelection() {
        guard let id = selection, store.task(id) != nil else { return }
        let next = neighbour(of: id)
        do {
            try taskService.delete(id, hard: true)
            undoAction = nil
            selection = next
            if next == nil, case .task = inspector { inspector = .hidden }
            flash("DELETED")
        } catch {
            flash("COULD NOT DELETE TASK")
        }
    }

    /// Destructive delete is always asked about first, wherever it is triggered.
    func requestDelete(_ id: UUID) {
        selection = id
        deletionRequest = id
    }

    func confirmDeletion() {
        guard deletionRequest != nil else { return }
        deletionRequest = nil
        deleteSelection()
    }

    /// Permanently removes every archived task, locally and on the VPS. Kept out of
    /// LocalStore because that has no knowledge of the outbox.
    @discardableResult
    func purgeArchived() -> Int {
        var removed = 0
        for id in store.tasks.filter(\.isArchived).map(\.id) {
            do { try taskService.delete(id, hard: true); removed += 1 }
            catch { /* keep going: one bad row must not block the rest */ }
        }
        return removed
    }

    func moveSelectionCursor(_ direction: MoveCommandDirection) {
        let status = selectedTask?.status ?? focusedStatus
        let items = tasks(in: status)
        let index = items.firstIndex { $0.id == selection }

        switch direction {
        case .up, .down:
            guard !items.isEmpty else { return }
            let next: Int
            if let index {
                next = direction == .down ? min(index + 1, items.count - 1) : max(index - 1, 0)
            } else {
                next = 0
            }
            selection = items[next].id
            focusedStatus = status
        case .left, .right:
            let statuses = visibleStatuses
            guard let current = statuses.firstIndex(of: status) else { return }
            let target = current + (direction == .right ? 1 : -1)
            guard statuses.indices.contains(target) else { return }
            focus(status: statuses[target])
        @unknown default:
            break
        }
        if case .task = inspector, let selection { inspector = .task(selection) }
    }

    func shiftSelection(up: Bool) {
        guard let id = selection, let task = store.task(id) else { return }
        let items = tasks(in: task.status)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 2
        guard target >= 0, target <= items.count else { return }
        _ = try? taskService.move(id, to: task.status, index: target)
    }

    private func neighbour(of id: UUID) -> UUID? {
        guard let task = store.task(id) else { return nil }
        let items = tasks(in: task.status)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1 < items.count ? items[index + 1].id : (index > 0 ? items[index - 1].id : nil)
    }

    // MARK: Meetings

    func openMeeting(_ id: UUID) {
        section = .meetings
        selectedMeeting = id
    }

    func startRecording() {
        section = .meetings
        Task { await recorder.start() }
    }

    /// Stops, keeps the audio on this Mac, and sends it for transcription.
    ///
    /// Both halves happen without another press: the file is already on disk by the
    /// time the engine stops, and the upload starts here. Turning off AUTO UPLOAD in
    /// Settings leaves the recording local until PROCESS is pressed.
    func stopRecording() {
        Task {
            guard let finished = await recorder.stop() else {
                flash("NOTHING WAS RECORDED")
                return
            }
            section = .meetings
            selectedMeeting = finished.meetingID

            if finished.wasSilent {
                // Transcribing silence costs minutes and returns nothing. Keep the
                // file, say what happened, and leave PROCESS available.
                flash("SAVED · NO AUDIO DETECTED")
                return
            }
            guard settings.autoUpload, settings.backendIsConfigured else {
                flash("RECORDING SAVED LOCALLY")
                return
            }
            processor.process(finished.meetingID)
            flash(sync.connection.isOnline ? "SAVED · UPLOADING" : "SAVED · UPLOADS WHEN ONLINE")
        }
    }

    /// The user chose PROCESS on a finished recording.
    func processRecording(_ meetingID: UUID) {
        selectedMeeting = meetingID
        guard settings.backendIsConfigured else {
            flash("NO VPS CONFIGURED · SAVED LOCALLY")
            store.updateMeeting(meetingID) { $0.status = .readyToProcess }
            return
        }
        processor.process(meetingID)
    }

    /// Keeps this recording on this Mac and never uploads it.
    func keepMeetingLocal(_ meetingID: UUID) {
        processor.cancel(meetingID)
        store.updateMeeting(meetingID) { $0.status = .localOnly }
        flash("KEPT LOCAL")
    }

    // MARK: Deleting

    /// Removes a meeting everywhere: the audio file, the local row, and the VPS copy.
    ///
    /// The server delete is queued rather than sent directly, so deleting while
    /// offline still reaches the VPS once the connection returns instead of leaving a
    /// meeting behind that only exists there.
    func deleteMeeting(_ id: UUID) {
        guard let meeting = store.meeting(id) else { return }
        processor.cancel(id)
        deleteRecordingFile(for: meeting)
        if settings.backendIsConfigured, let remoteID = meeting.remoteID {
            store.enqueue(kind: "meeting.delete", method: "DELETE",
                          path: "/meetings/\(remoteID)", entityID: id)
        }
        store.deleteMeeting(id)
        if selectedMeeting == id { selectedMeeting = nil }
        if recorder.lastFinished?.meetingID == id { recorder.clearLastFinished() }
        flash("MEETING DELETED")
    }

    /// Drops the audio file but keeps the meeting and everything the VPS returned.
    func deleteRecordingAudio(_ id: UUID) {
        guard let meeting = store.meeting(id), meeting.audioFilename != nil else { return }
        deleteRecordingFile(for: meeting)
        store.updateMeeting(id) { $0.audioFilename = nil }
        flash("RECORDING FILE DELETED")
    }

    /// Clears every audio file on disk, leaving the meetings themselves alone.
    /// Anything still waiting to upload is skipped — that would lose the only copy.
    @discardableResult
    func deleteAllRecordingFiles() -> Int {
        var removed = 0
        for meeting in store.meetings where meeting.audioFilename != nil && !meeting.awaitsUpload {
            deleteRecordingFile(for: meeting)
            store.updateMeeting(meeting.id) { $0.audioFilename = nil }
            removed += 1
        }
        // Sweep anything orphaned by an earlier crash or a deleted row.
        let known = Set(store.meetings.compactMap(\.audioFilename))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: KanbanPaths.recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !known.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        flash("DELETED \(removed) RECORDING\(removed == 1 ? "" : "S")")
        return removed
    }

    private func deleteRecordingFile(for meeting: Meeting) {
        guard let filename = meeting.audioFilename else { return }
        try? FileManager.default.removeItem(at: KanbanPaths.recordingURL(filename: filename))
    }

    // MARK: Suggested tasks

    /// A suggestion the user is editing before it becomes a real task.
    struct SuggestionDraft: Identifiable, Equatable {
        var id: UUID { item.id }
        var item: ActionItem
        var title: String
        var status: TaskStatus
        var priority: Priority
        var dueDate: Date?
    }

    func beginAdding(_ item: ActionItem) {
        pendingSuggestion = SuggestionDraft(
            item: item,
            title: item.title,
            status: .todo,
            priority: settings.defaultPriority,
            dueDate: item.dueDate)
    }

    /// Commits the confirmed suggestion. This is the only path from an AI action item
    /// to a real task — nothing is created without passing through here.
    func commitSuggestion(_ draft: SuggestionDraft) {
        guard let meeting = store.meeting(draft.item.meetingID) else { return }
        var notes = "From \(meeting.title) · \(DateInput.shortLabel(meeting.startedAt))"
        if let assignee = draft.item.assignee, !assignee.isEmpty {
            notes += "\nAssignee: \(assignee)"
        }
        do {
            let created = try taskService.create(CreateTaskBody(
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notes,
                status: draft.status.rawValue,
                priority: draft.priority.longLabel.lowercased(),
                due: draft.dueDate.map(DateInput.iso),
                source: TaskSource.meeting.rawValue,
                meetingId: meeting.id.uuidString,
                actionItemId: draft.item.id.uuidString))
            store.setActionItemState(draft.item.id, in: meeting.id, to: .added, taskID: created.id)
            pendingSuggestion = nil
            flash("TASK ADDED")
        } catch {
            flash("COULD NOT ADD TASK")
        }
    }

    func dismissSuggestion(_ item: ActionItem) {
        store.setActionItemState(item.id, in: item.meetingID, to: .dismissed, taskID: nil)
    }

    func restoreSuggestion(_ item: ActionItem) {
        store.setActionItemState(item.id, in: item.meetingID, to: .suggested, taskID: nil)
    }

    /// ADD ALL still creates one task per suggestion with defaults — it skips the
    /// per-item dialog, not the user's decision.
    func addAllSuggestions(from meetingID: UUID) {
        guard let meeting = store.meeting(meetingID) else { return }
        let suggestions = meeting.actionItems.filter(\.isSuggested)
        for item in suggestions {
            commitSuggestion(SuggestionDraft(item: item, title: item.title, status: .todo,
                                             priority: settings.defaultPriority, dueDate: item.dueDate))
        }
        pendingSuggestion = nil
        flash("ADDED \(suggestions.count) TASK\(suggestions.count == 1 ? "" : "S")")
    }

    // MARK: URL scheme

    /// kanban://open | kanban://new | kanban://agent | kanban://record
    /// kanban://task/<uuid> | kanban://meeting/<uuid>
    func handle(url: URL) {
        guard url.scheme == "kanban" else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch url.host {
        case "open": section = .tasks
        case "new": newTask()
        case "agent": section = .agent
        case "record": section = .meetings
        case "task":
            guard let id = UUID(uuidString: url.pathComponents.last ?? ""), let task = store.task(id) else {
                flash("TASK NOT FOUND")
                return
            }
            focusedStatus = task.status
            openInspector(for: id)
        case "meeting":
            guard let id = UUID(uuidString: url.pathComponents.last ?? ""), store.meeting(id) != nil else {
                flash("MEETING NOT FOUND")
                return
            }
            openMeeting(id)
        default:
            break
        }
    }

    // MARK: Transient status line

    func flash(_ message: String, duration: TimeInterval = 2.2) {
        transientMessage = message
        // VoiceOver users otherwise get no feedback for complete/archive/errors.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        transientWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.transientMessage = nil }
        transientWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }
}
