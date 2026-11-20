import AppKit
import Observation
import SwiftUI
import WidgetKit

/// Single owner of app-wide state. Views stay dumb; lifecycle lives here.
@Observable
@MainActor
final class AppModel {

    /// Top-level navigation.
    enum Section: String, CaseIterable, Hashable {
        case tasks, meetings, mail, calendar, agent
        var label: String {
            switch self {
            case .tasks: return "TASKS"
            case .meetings: return "MEETINGS"
            case .mail: return "MAIL"
            case .calendar: return "MEET"
            case .agent: return "AGENT"
            }
        }
    }

    enum Inspector: Equatable {
        case hidden
        case task(UUID)
    }

    /// The four surfaces of the Meet workspace.
    enum MeetTab: String, CaseIterable {
        case briefs = "BRIEFS"
        case commitments = "COMMITMENTS"
        case memory = "MEMORY"
        case automation = "AUTOMATION"
    }

    // Dependencies
    let store: LocalStore
    let settings: AppSettings
    let client: APIClient
    let sync: SyncEngine
    let recorder: MeetingRecorder
    let processor: MeetingProcessor
    /// The bundled model catalog and the engine that runs its GGUF models.
    let catalog: ModelCatalog?
    let transcription: TranscriptionEngine
    let models: ModelDownloader
    let dictation: DictationController
    let agent: AgentSession
    /// Gmail, entirely on this Mac. The factory talks only to Google and SQLite.
    let gmailStore: GmailStore
    let gmailFactory: GmailLiveAPIFactory
    let gmailSync: GmailSyncEngine
    let gmailService: GmailService
    let gmailAuth: GmailAuthController
    let mail: MailModel
    /// Read-only Google/Outlook calendars via the accounts macOS already has.
    let calendar = CalendarBridge()
    /// Last computed pre-meeting briefs, keyed by scheduled meeting id.
    private(set) var briefs: [UUID: ScheduledMeetingBrief] = [:]
    @ObservationIgnored private let notifications = NotificationCenterBridge()

    // Navigation
    var section: Section = .tasks
    var meetTab: MeetTab = .briefs
    var selectedMeeting: UUID?
    var selectedScheduledMeetingID: UUID?
    /// The scheduled meeting the current recording belongs to, if any.
    private var scheduledRecordingID: UUID?
    /// Set when the agent (or a deep link) opens a meeting on a specific section.
    var meetingFocus: MeetingFocus?

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
        let catalog = try? ModelCatalog.bundled()
        let transcription = TranscriptionEngine()
        self.catalog = catalog
        self.transcription = transcription
        self.models = ModelDownloader()

        // First launch after a model was placed on disk: use what is there
        // rather than the shipped default, which may not be downloaded.
        if settings.transcriptionModelWasDefaulted, let catalog,
           let installed = ModelStorage.resolve(in: catalog,
                                                preferred: settings.transcriptionModelID) {
            settings.transcriptionModelID = installed.entry.id
        }

        // A meeting left mid-flight by a quit has no task behind it any more;
        // release it so it can be processed again instead of spinning forever.
        for meeting in store.meetings where meeting.status.isProcessing {
            store.updateMeeting(meeting.id) {
                $0.status = $0.audioFilename == nil ? .failed : .readyToProcess
                if $0.audioFilename == nil {
                    $0.failureReason = "Processing was interrupted."
                }
            }
        }
        self.processor = MeetingProcessor(store: store, client: client, settings: settings,
                                          engine: transcription, catalog: catalog)
        self.dictation = DictationController(settings: settings, engine: transcription,
                                             catalog: catalog)
        // Gmail is a purely local subsystem. The factory reads Google only; the
        // store, drafts and search all live in this Mac's SQLite file.
        let gmailStore = GmailStore()
        // Do not touch the Keychain during app init: a missing ACL entry can put a
        // modal prompt on screen before the window exists. The secret is added by
        // MailModel.syncNow/connect on the main actor, just before it is needed.
        let gmailConfig = GmailOAuthConfig(clientID: settings.gmailClientID,
                                           clientSecret: nil)
        let gmailFactory = GmailLiveAPIFactory(config: { gmailConfig })
        let gmailSync = GmailSyncEngine(
            store: gmailStore, factory: gmailFactory,
            initialLimit: { max(50, min(5_000, settings.gmailInitialSyncLimit)) })
        let gmailService = GmailService(store: gmailStore, sync: gmailSync,
                                        factory: gmailFactory)
        let gmailAuth = GmailAuthController()
        #if DEBUG
        let fileVault: FileVaultChecking = {
            if let raw = ProcessInfo.processInfo.environment["KANBAN_ASSUME_FILEVAULT"],
               let state = FileVaultState(rawValue: raw) {
                return StaticFileVault(state)
            }
            return SystemFileVault()
        }()
        #else
        let fileVault: FileVaultChecking = SystemFileVault()
        #endif
        let mail = MailModel(store: gmailStore, sync: gmailSync, service: gmailService,
                             auth: gmailAuth, factory: gmailFactory, settings: settings,
                             fileVault: fileVault)
        gmailSync.setSemanticIndexer { [weak gmailStore] in
            guard settings.gmailSemanticSearch, let gmailStore else { return }
            await GmailSemanticIndex.indexPending(store: gmailStore, limit: 200)
        }
        self.gmailStore = gmailStore
        self.gmailFactory = gmailFactory
        self.gmailSync = gmailSync
        self.gmailService = gmailService
        self.gmailAuth = gmailAuth
        self.mail = mail

        self.agent = AgentSession(store: store, client: client, settings: settings, sync: sync)
        notifications.onOpenTask = { [weak self] id in
            guard let self else { return }
            guard self.store.task(id) != nil else {
                self.flash("TASK NOT FOUND")
                return
            }
            self.openInspector(for: id)
        }
        mail.onThreadSelected = { [weak self] accountID, threadID in
            self?.agent.focusEmail(accountID: accountID, threadID: threadID)
        }
        self.agent.gmail = gmailStore
        self.agent.gmailActions = gmailService
        self.agent.onNavigate = { [weak self] navigation in
            self?.navigate(navigation)
        }
        self.agent.onScheduledMeetingCreated = { [weak self] meeting in
            self?.flash("SCHEDULED · \(CalendarFormat.dateTime(meeting.startsAt))")
        }
        self.agent.externalScheduledMeetings = { [weak self] in
            self?.calendar.events.map(\.scheduledMeeting) ?? []
        }
        self.agent.onEmailChanged = { [weak self] _ in
            guard let self else { return }
            self.flash("AGENT UPDATED YOUR MAIL")
            self.mail.reload(reset: true)
            self.mail.refreshThread()
        }

        store.onChange = { [weak self] _ in
            guard let self else { return }
            // Briefs are derived; a task or commitment change invalidates them.
            self.briefs.removeAll()
            WidgetCenter.shared.reloadTimelines(ofKind: KanbanWidgetKind.today)
            self.notifications.reschedule(for: self.store.tasks, enabled: self.settings.notificationsEnabled)
            self.notifications.rescheduleCommitments(
                self.store.meetings.flatMap { meeting in
                    meeting.actionItems.map { (item: $0, meeting: meeting) }
                },
                enabled: self.settings.notificationsEnabled)
            self.scheduleStaleNotifications()
        }
        processor.onCompleted = { [weak self] meeting in
            guard let self else { return }
            self.flash(meeting.summary.isEmpty
                       ? "TRANSCRIBED"
                       : "MEETING PROCESSED · \(meeting.suggestedCount) SUGGESTED")
            if self.settings.notifyOnMeetingProcessed {
                self.notifications.notifyMeetingProcessed(title: meeting.title,
                                                          suggestions: meeting.suggestedCount)
            }
            // Local rules run after the analysis is stored, never before it.
            if let fresh = self.store.meeting(meeting.id) {
                self.runAutomations(for: fresh)
                self.sweepCommitments()
            }
        }
        agent.onTasksChanged = { [weak self] applied in
            guard let self else { return }
            self.flash("AGENT UPDATED THE BOARD")
            if applied > 0, self.settings.notifyOnAgentAction {
                self.notifications.notifyAgentAction(count: applied)
            }
        }
        agent.onReminderScheduled = { [weak self] in
            guard let self else { return }
            let arm = { [weak self] in
                guard let self else { return }
                self.notifications.reschedule(for: self.store.tasks, enabled: true)
                self.notifications.rescheduleCommitments(
                    self.store.meetings.flatMap { meeting in
                        meeting.actionItems.map { (item: $0, meeting: meeting) }
                    },
                    enabled: true)
                self.flash("REMINDER SET")
            }
            if self.settings.notificationsEnabled {
                arm()
            } else {
                self.notifications.requestAuthorisation { granted in
                    guard granted else {
                        self.flash("NOTIFICATIONS OFF · REMINDER NOT ARMED")
                        return
                    }
                    self.settings.notificationsEnabled = true
                    arm()
                }
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
        if settings.dictationEnabled { dictation.setEnabled(true) }
        mail.start()
        #if DEBUG
        ScreenshotDriver.runIfRequested(self)
        AgentDiagnostics.runIfRequested(self)
        #endif
        Task {
            // Credentials load off-main; until they arrive the getters return the
            // session cache rather than blocking this actor on a Keychain dialog.
            await settings.preloadCredentials()
            // With a Gemini key the pipeline is local; retry anything left ready
            // when the app last closed without waiting for a server.
            if settings.hasGeminiKey, settings.autoUpload { processor.processPending() }
            await connect()
            await recorder.probe()
            if calendar.isAuthorized { await refreshCalendar() }
            sweepCommitments()
            scheduleStaleNotifications()
        }
        if settings.notificationsEnabled {
            notifications.requestAuthorisation { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.notifications.reschedule(for: self.store.tasks, enabled: true)
                    self.scheduleStaleNotifications()
                } else {
                    self.settings.notificationsEnabled = false
                }
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
        Task {
            if calendar.isAuthorized { await refreshCalendar() }
            sweepCommitments()
            scheduleStaleNotifications()
            await mail.syncIfStale()
        }
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
                self.scheduleStaleNotifications()
                if !granted { self.flash("NOTIFICATIONS DENIED IN SYSTEM SETTINGS") }
            }
        } else {
            notifications.reschedule(for: [], enabled: false)
            notifications.rescheduleCommitments([], enabled: false)
            notifications.rescheduleStale(tasks: [], policy: settings.staleTaskPolicy,
                                          enabled: false) { _, _ in }
        }
    }

    /// Called when a stale-task preference changes, and on Settings close.
    func refreshStaleNotifications() {
        scheduleStaleNotifications()
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

    // MARK: Calendar

    func openCalendar(_ id: UUID? = nil) {
        section = .calendar
        if let id, scheduledMeeting(id) != nil {
            selectedScheduledMeetingID = id
        } else if let selected = selectedScheduledMeetingID,
                  scheduledMeeting(selected) != nil {
            // keep the current selection
        } else {
            selectedScheduledMeetingID = store.scheduledMeetings.upcoming().first?.id
        }
    }

    func deleteScheduledMeeting(_ id: UUID) {
        guard store.deleteScheduledMeeting(id) else { return }
        if selectedScheduledMeetingID == id {
            selectedScheduledMeetingID = store.scheduledMeetings.upcoming().first?.id
        }
        flash("SCHEDULED MEETING REMOVED")
    }

    // MARK: Meetings

    func openMeeting(_ id: UUID) {
        openMeeting(id, focus: nil)
    }

    func openMeeting(_ id: UUID, focus: MeetingFocus?) {
        section = .meetings
        selectedMeeting = id
        meetingFocus = focus
    }

    /// Performs an agent-named destination using the same moves a click makes.
    func navigate(_ navigation: AgentNavigation) {
        switch navigation {
        case .meeting(let id, let focus):
            guard store.meeting(id) != nil else { flash("MEETING NOT FOUND"); return }
            openMeeting(id, focus: focus)
        case .task(let id):
            guard store.task(id) != nil else { flash("TASK NOT FOUND"); return }
            openInspector(for: id)
        case .calendar(let id):
            openCalendar(id)
        case .mail(let accountID, let threadID):
            if threadID == nil { mail.setMailbox(.inbox) }
            openMail(accountID: accountID, threadID: threadID)
        case .mailDraft(let id):
            openMailDraft(id)
        case .recorder:
            section = .meetings
        case .board:
            section = .tasks
        }
    }

    /// The one route into the mail workspace. A meeting or agent card calls this
    /// with the same arguments a click in the sidebar would.
    func openMail(accountID: UUID? = nil, threadID: String? = nil) {
        section = .mail
        if let accountID {
            mail.setAccount(accountID)
        }
        if let threadID {
            let account = accountID ?? mail.selectedAccountID ?? mail.store.accounts.first?.id
            if let account {
                mail.select(accountID: account, threadID: threadID)
            }
        }
    }

    func openMailDraft(_ id: UUID) {
        section = .mail
        mail.mailbox = .drafts
        if let draft = mail.store.draft(id) {
            mail.setAccount(draft.accountID)
            Task { await mail.editDraft(draft) }
        } else {
            mail.reload(reset: true)
        }
    }

    func composeMail() {
        section = .mail
        if mail.isStorageBlocked {
            flash("MAIL LOCKED · FILEVAULT REQUIRED")
        } else {
            mail.composeNew()
        }
    }

    func startRecording() {
        startRecording(forScheduled: nil)
    }

    /// Starts a recording and remembers which scheduled meeting it belongs to, so
    /// the finished recording can be linked back in the Calendar.
    func startRecording(forScheduled scheduledID: UUID?) {
        if let scheduledID, let scheduled = scheduledMeeting(scheduledID) {
            // An external event has no local row to link back to; it still supplies
            // the title so the recording is named correctly.
            scheduledRecordingID = store.scheduledMeeting(scheduledID) != nil
                ? scheduledID : nil
            recorder.title = scheduled.title
        } else {
            scheduledRecordingID = nil
        }
        section = .meetings
        // Do not capture the agent's own playback into the new recording.
        agent.player.pause()
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
                scheduledRecordingID = nil
                flash("NOTHING WAS RECORDED")
                return
            }
            if let scheduledID = scheduledRecordingID {
                store.linkScheduledMeeting(scheduledID, to: finished.meetingID)
                scheduledRecordingID = nil
            }
            section = .meetings
            selectedMeeting = finished.meetingID

            if finished.wasSilent {
                // Transcribing silence costs minutes and returns nothing. Keep the
                // file, say what happened, and leave PROCESS available.
                flash("SAVED · NO AUDIO DETECTED")
                return
            }
            guard settings.autoUpload, settings.canProcessMeetings else {
                flash("RECORDING SAVED LOCALLY")
                return
            }
            processor.process(finished.meetingID)
            flash(settings.hasLocalTranscriptionModel
                  ? "SAVED · TRANSCRIBING ON THIS MAC"
                  : (sync.connection.isOnline ? "SAVED · UPLOADING" : "SAVED · UPLOADS WHEN ONLINE"))
        }
    }

    /// The user chose PROCESS on a finished recording.
    func processRecording(_ meetingID: UUID) {
        selectedMeeting = meetingID
        guard settings.canProcessMeetings else {
            flash("DOWNLOAD A SPEECH MODEL IN SETTINGS · LOCAL AI")
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

    // MARK: Meeting intelligence

    /// Everything the Meet workspace shows: local scheduled meetings plus the next
    /// two weeks of Google/Outlook events read through EventKit.
    func upcomingMeetings(now: Date = Date(), days: Int = 14) -> [ScheduledMeeting] {
        let cutoff = now.addingTimeInterval(TimeInterval(days) * 86_400)
        let external = calendar.events
            .filter { $0.endsAt >= now && $0.startsAt <= cutoff }
            .map(\.scheduledMeeting)
        var byID: [UUID: ScheduledMeeting] = [:]
        for meeting in store.scheduledMeetings where meeting.endsAt >= now {
            byID[meeting.id] = meeting
        }
        for meeting in external { byID[meeting.id] = meeting }
        return byID.values.sorted { $0.startsAt < $1.startsAt }
    }

    /// Explicit connect: this is the only path that asks macOS for permission.
    func connectCalendar() async {
        await calendar.requestAccess()
        await prepareBriefsForUpcoming()
    }

    /// Refresh an already-authorised feed. Never prompts, so launch and activation
    /// cannot surprise the user with a permission dialog.
    func refreshCalendar() async {
        guard calendar.isAuthorized else { return }
        await calendar.refresh()
        await prepareBriefsForUpcoming()
    }

    /// Local scheduled rows and external events share one identity space.
    func scheduledMeeting(_ id: UUID) -> ScheduledMeeting? {
        store.scheduledMeeting(id)
            ?? calendar.events.first(where: { $0.id == id })?.scheduledMeeting
    }

    func isExternalScheduledMeeting(_ id: UUID) -> Bool {
        calendar.events.contains { $0.id == id }
    }

    var selectedScheduledMeeting: ScheduledMeeting? {
        selectedScheduledMeetingID.flatMap(scheduledMeeting)
    }

    /// Builds the brief for one meeting. Pure local work: meetings, tasks and the
    /// schedule already on this Mac.
    func brief(for scheduled: ScheduledMeeting) -> ScheduledMeetingBrief {
        if let cached = briefs[scheduled.id] { return cached }
        let brief = MeetingMemory.brief(
            for: scheduled, meetings: store.meetings,
            scheduledMeetings: upcomingMeetings().filter { $0.id != scheduled.id },
            tasks: store.tasks)
        briefs[scheduled.id] = brief
        return brief
    }

    /// Called from the Meet workspace and at launch. Refreshing a brief is cheap;
    /// this deliberately does not call a model.
    func prepareBriefsForUpcoming(now: Date = Date()) async {
        let upcoming = upcomingMeetings(now: now).filter { $0.isUpcoming(now: now) }
        for meeting in upcoming { _ = brief(for: meeting) }
        notifications.scheduleBriefs(
            upcoming.compactMap { meeting in
                briefs[meeting.id].map { (meeting: meeting, summary: $0.summary) }
            },
            enabled: settings.notificationsEnabled)
    }

    /// Persisted rules, in creation order.
    var automationRules: [AutomationRule] { store.automationRules }

    @discardableResult
    func saveAutomationRule(_ rule: AutomationRule) -> AutomationRule {
        store.upsertAutomationRule(rule)
    }

    func deleteAutomationRule(_ id: UUID) {
        store.deleteAutomationRule(id)
    }

    func addStandardAutomation() {
        let rule = AutomationRule.standardFollowUp()
        store.upsertAutomationRule(rule)
        flash("AUTOMATION ADDED")
    }

    /// Runs every enabled rule for a finished meeting and records what happened.
    /// Local effects only: task rows, composed drafts and in-app notifications.
    func runAutomations(for meeting: Meeting, now: Date = Date()) {
        for rule in store.automationRules where AutomationPlanner.matches(rule, meeting: meeting) {
            let started = Date()
            var details: [String] = []
            var failures = 0
            for action in AutomationPlanner.plan(rule, meeting: meeting) {
                switch action.type {
                case "tasks.create":
                    let minimum = action.minConfidence ?? 0
                    var created = 0
                    for item in meeting.actionItems
                    where item.confidence >= minimum && item.taskID == nil
                        && item.state != .dismissed && item.isOpen {
                        if createTaskFromCommitment(item, meeting: meeting) != nil { created += 1 }
                    }
                    details.append("created \(created) task\(created == 1 ? "" : "s")")
                case "email.summary", "email.followup":
                    let message = action.type == "email.summary"
                        ? FollowUpComposer.summary(meeting: meeting)
                        : FollowUpComposer.followUp(meeting: meeting)
                    var recipients = action.recipients ?? []
                    recipients.append(contentsOf: message.recipients)
                    var composed = message
                    composed.recipients = Array(Set(recipients)).sorted()
                    store.addLocalMessage(composed)
                    details.append("drafted \(action.type == "email.summary" ? "summary" : "follow-up")")
                case "notify.commitments":
                    var notified = 0
                    for item in meeting.actionItems where item.isOpen && item.state != .dismissed {
                        if item.remindedAt.map({ now.timeIntervalSince($0) < 86_400 }) == true {
                            continue
                        }
                        store.addLocalMessage(FollowUpComposer.reminder(commitment: item,
                                                                        meeting: meeting))
                        if let email = FollowUpComposer.reminderEmail(commitment: item,
                                                                       meeting: meeting) {
                            store.addLocalMessage(email)
                        }
                        store.markCommitmentReminded(item.id, in: meeting.id, at: now)
                        notified += 1
                    }
                    details.append("notified \(notified) owner\(notified == 1 ? "" : "s")")
                case "commitments.remind":
                    let count = sweepCommitments(now: now)
                    details.append("reminded \(count) overdue")
                case "tasks.external":
                    guard let raw = action.url, let url = URL(string: raw), !raw.isEmpty else {
                        failures += 1
                        details.append("external tasks skipped (bad URL)")
                        continue
                    }
                    let minimum = action.minConfidence ?? 0
                    var pushed = 0
                    for item in meeting.actionItems
                    where item.isOpen && item.state != .dismissed
                        && item.confidence >= minimum {
                        if let task = createTaskFromCommitment(item, meeting: meeting) {
                            postTaskWebhook(url: url, task: task, commitment: item, meeting: meeting)
                            pushed += 1
                        }
                    }
                    details.append("pushed \(pushed) task\(pushed == 1 ? "" : "s") to the board webhook")
                case "webhook.post":
                    guard let raw = action.url, let url = URL(string: raw), !raw.isEmpty else {
                        failures += 1
                        details.append("webhook skipped (bad URL)")
                        continue
                    }
                    postAutomationWebhook(url: url, meeting: meeting, dryRun: action.dryRun ?? false)
                    details.append("webhook queued")
                default:
                    details.append("ignored \(action.type)")
                }
            }
            let status: AutomationRun.Status = failures == 0 ? .completed : .partial
            store.recordAutomationRun(AutomationRun(
                ruleID: rule.id, ruleName: rule.name, meetingID: meeting.id,
                status: status, detail: details.joined(separator: " · "),
                startedAt: started, finishedAt: Date()))
        }
    }

    /// The generic external-task payload. An incoming webhook in Jira Automation,
    /// Linear, Notion or Zapier maps these fields to its own issue shape.
    private func postTaskWebhook(url: URL, task: TaskItem, commitment: ActionItem,
                                 meeting: Meeting) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "source": "workconsole",
            "title": task.title,
            "notes": task.notes,
            "due": jsonOrNull(task.dueDate.map { DateInput.iso($0) }),
            "assignee": jsonOrNull(commitment.assignee),
            "quote": jsonOrNull(commitment.quote),
            "meeting": ["id": meeting.id.uuidString, "title": meeting.title],
            "commitmentId": commitment.id.uuidString
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }

    private func postAutomationWebhook(url: URL, meeting: Meeting, dryRun: Bool) {
        guard !dryRun else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "trigger": "meeting.completed",
            "meeting": [
                "id": meeting.id.uuidString,
                "title": meeting.title,
                "summary": meeting.summary,
                "decisions": meeting.decisions,
                "participants": meeting.participants,
                "commitments": meeting.actionItems.map {
                    ["title": $0.title, "assignee": $0.assignee ?? "",
                     "due": $0.dueDate.map { DateInput.iso($0) } ?? ""]
                }
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Notifies overdue commitment owners at most once a day. Called at launch, when
    /// the app becomes active and when the Meet workspace opens.
    @discardableResult
    func sweepCommitments(now: Date = Date()) -> Int {
        var sent = 0
        for meeting in store.meetings {
            for item in meeting.actionItems where item.state != .dismissed && item.needsReminder(now: now) {
                store.addLocalMessage(FollowUpComposer.reminder(commitment: item,
                                                                meeting: meeting))
                if let email = FollowUpComposer.reminderEmail(commitment: item,
                                                               meeting: meeting) {
                    store.addLocalMessage(email)
                }
                store.markCommitmentReminded(item.id, in: meeting.id, at: now)
                sent += 1
            }
        }
        runOverdueAutomations(now: now, alreadyReminded: sent)
        return sent
    }

    /// Custom rules on the overdue trigger. The built-in once-a-day reminder above
    /// always runs; these add the user's own actions on top, with the same 24h guard.
    private func runOverdueAutomations(now: Date, alreadyReminded: Int) {
        let overdue: [(ActionItem, Meeting)] = store.meetings.flatMap { meeting in
            meeting.actionItems.filter { $0.state != .dismissed && $0.isOverdue(now: now) }.map { ($0, meeting) }
        }
        guard !overdue.isEmpty else { return }

        for rule in store.automationRules
        where rule.enabled && rule.trigger == .commitmentOverdue {
            let relevant = overdue.filter { item, meeting in
                let title = rule.conditions.titleContains.lowercased()
                let person = rule.conditions.participantContains.lowercased()
                if !title.isEmpty, !meeting.title.lowercased().contains(title) { return false }
                if !person.isEmpty,
                   !(item.assignee ?? "").lowercased().contains(person) { return false }
                return true
            }
            guard !relevant.isEmpty else { continue }

            let started = Date()
            var details: [String] = []
            var failures = 0
            for action in rule.actions {
                switch action.type {
                case "commitments.remind":
                    details.append("reminded \(alreadyReminded) overdue")
                case "notify.commitments":
                    var notified = 0
                    for (item, meeting) in relevant
                    where item.needsReminder(now: now) {
                        store.addLocalMessage(FollowUpComposer.reminder(commitment: item,
                                                                        meeting: meeting))
                        if let email = FollowUpComposer.reminderEmail(commitment: item,
                                                                       meeting: meeting) {
                            store.addLocalMessage(email)
                        }
                        store.markCommitmentReminded(item.id, in: meeting.id, at: now)
                        notified += 1
                    }
                    details.append("notified \(notified) owner\(notified == 1 ? "" : "s")")
                case "webhook.post", "tasks.external":
                    guard let raw = action.url, let url = URL(string: raw), !raw.isEmpty else {
                        failures += 1
                        details.append("webhook skipped (bad URL)")
                        continue
                    }
                    postOverdueWebhook(url: url, items: relevant)
                    details.append("webhook queued")
                default:
                    details.append("ignored \(action.type)")
                }
            }
            let status: AutomationRun.Status = failures == 0 ? .completed : .partial
            store.recordAutomationRun(AutomationRun(
                ruleID: rule.id, ruleName: rule.name, meetingID: nil,
                status: status, detail: details.joined(separator: " · "),
                startedAt: started, finishedAt: Date()))
        }
    }

    private func jsonOrNull(_ value: Any?) -> Any { value ?? NSNull() }

    private func postOverdueWebhook(url: URL, items: [(ActionItem, Meeting)]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "trigger": "commitment.overdue",
            "commitments": items.map { item, meeting in
                ["id": item.id.uuidString, "title": item.title,
                 "assignee": jsonOrNull(item.assignee),
                 "due": jsonOrNull(item.dueDate.map { DateInput.iso($0) }),
                 "meetingId": meeting.id.uuidString, "meetingTitle": meeting.title]
            }
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Creates a task for a commitment directly, used by automations. The manual UI
    /// still goes through `beginAdding`, which asks for confirmation first.
    @discardableResult
    func createTaskFromCommitment(_ item: ActionItem, meeting: Meeting,
                                  title: String? = nil,
                                  status: TaskStatus = .todo,
                                  priority: Priority? = nil,
                                  due: Date? = nil) -> TaskItem? {
        // Consult the live row: an earlier action in the same rule may already have
        // created the task, and `meeting` is a value snapshot.
        if let current = store.commitment(item.id)?.item,
           let taskID = current.taskID, let existing = store.task(taskID) {
            return existing
        }
        var notes = "From \(meeting.title) · \(DateInput.shortLabel(meeting.startedAt))"
        if let quote = item.quote { notes += "\nSpoken: \"\(quote)\"" }
        do {
            let created = try taskService.create(CreateTaskBody(
                title: title ?? item.title,
                notes: notes,
                status: status.rawValue,
                priority: (priority ?? settings.defaultPriority).longLabel.lowercased(),
                due: (due ?? item.dueDate).map { DateInput.iso($0) },
                source: TaskSource.meeting.rawValue,
                meetingId: meeting.id.uuidString,
                actionItemId: item.id.uuidString))
            store.setActionItemState(item.id, in: meeting.id, to: .added, taskID: created.id)
            return created
        } catch {
            flash("COULD NOT ADD TASK")
            return nil
        }
    }

    func setCommitment(_ item: ActionItem, in meeting: Meeting,
                       to state: ActionItem.Commitment) {
        store.setCommitmentState(item.id, in: meeting.id, to: state)
        flash(state == .done ? "COMMITMENT DONE" : "COMMITMENT OPEN")
    }

    func remindCommitment(_ item: ActionItem, meeting: Meeting) {
        store.addLocalMessage(FollowUpComposer.reminder(commitment: item, meeting: meeting))
        if let email = FollowUpComposer.reminderEmail(commitment: item, meeting: meeting) {
            store.addLocalMessage(email)
        }
        store.markCommitmentReminded(item.id, in: meeting.id)
        flash("REMINDER SAVED")
    }

    func memorySearch(_ query: String, since: Date? = nil,
                      kind: LocalMemoryEntry.Kind? = nil,
                      participant: String? = nil) -> [LocalMemoryHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return MeetingMemory.search(query, meetings: store.meetings,
                                    transcripts: loadedTranscripts(),
                                    kind: kind, participant: participant,
                                    since: since)
    }

    func askMemory(_ question: String, since: Date? = nil) -> LocalMemoryAnswer {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else {
            return LocalMemoryAnswer(answer: "Ask a question first.", citations: [],
                                     confident: false)
        }
        return MeetingMemory.answer(question, meetings: store.meetings,
                                    transcripts: loadedTranscripts(), since: since)
    }

    func contradictions() -> [LocalContradiction] {
        MeetingMemory.contradictions(meetings: store.meetings)
    }

    /// Transcripts are paged from disk; only the search and answer views ask for
    /// them, so the board never pays this cost.
    private func loadedTranscripts() -> [UUID: [TranscriptSegment]] {
        var out: [UUID: [TranscriptSegment]] = [:]
        for meeting in store.meetings {
            let segments = store.transcript(for: meeting.id)
            if !segments.isEmpty { out[meeting.id] = segments }
        }
        return out
    }

    /// Stale nudges use the same store-change coalescing as due reminders. The
    /// bridge keeps an unchanged task's pending request and never queues a second
    /// one; marking the notice is not task progress, so it does not reset the clock.
    func scheduleStaleNotifications() {
        notifications.rescheduleStale(
            tasks: store.tasks,
            policy: settings.staleTaskPolicy,
            enabled: settings.notificationsEnabled && settings.staleTaskNudges) { [weak self] id, at in
                self?.store.markStaleNotified(id, at: at)
            }
    }

    // MARK: Deleting

    /// Removes a meeting everywhere: the audio file, the local row, and the VPS copy.
    ///
    /// The server delete is queued rather than sent directly, so deleting while
    /// offline still reaches the VPS once the connection returns instead of leaving a
    /// meeting behind that only exists there.
    func deleteMeeting(_ id: UUID) {
        guard let meeting = store.meeting(id) else { return }
        if agent.player.meetingID == id { agent.player.stop() }
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
        if agent.player.meetingID == id { agent.player.stop() }
        deleteRecordingFile(for: meeting)
        store.updateMeeting(id) { $0.audioFilename = nil }
        flash("RECORDING FILE DELETED")
    }

    /// Clears every audio file on disk, leaving the meetings themselves alone.
    /// Anything still waiting to upload is skipped — that would lose the only copy.
    @discardableResult
    func deleteAllRecordingFiles() -> Int {
        var removed = 0
        if agent.player.isLoaded { agent.player.stop() }
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
        case "calendar": openCalendar()
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
