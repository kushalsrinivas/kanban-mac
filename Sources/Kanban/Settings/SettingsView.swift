import SwiftUI

/// One scrolling pane of blocks. No tabs, no sidebar — everything fits on a page.
struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    @State private var recordingsBytes: Int64 = 0
    @State private var confirmingRecordingPurge = false
    @State private var confirmingArchivedPurge = false
    @State private var confirmingOutboxDiscard = false
    @State private var confirmingEmptyPull = false
    @State private var showingArchived = false
    /// The API key is drafted here and only written to the Keychain on commit —
    /// writing on every keystroke hammered the Keychain and hid failures.
    @State private var apiKeyDraft = ""
    @State private var apiKeyStored = false
    @FocusState private var apiKeyFocused: Bool
    /// Gemini key used by the in-app analysis and agent.
    @State private var geminiKeyDraft = ""
    @State private var geminiKeyStored = false
    @FocusState private var geminiKeyFocused: Bool

    private var archivedCount: Int { app.store.tasks.filter(\.isArchived).count }

    /// The policy's own answer, so Settings cannot drift from what the client accepts.
    private var serverURLProblem: String? {
        ServerURLPolicy.problem(with: app.settings.serverURL)
    }

    var body: some View {
        let bindable = Bindable(app.settings)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                appearanceBlock(bindable)
                tasksBlock(bindable)
                localAIBlock(bindable)
                backendBlock(bindable)
                meetingsBlock(bindable)
                notificationsBlock(bindable)
                dataBlock()
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .frame(width: 580, height: 660)
        .background(theme.paper)
        .environment(\.theme, app.theme)
        .preferredColorScheme(app.settings.colorScheme)
        .onAppear {
            recordingsBytes = KanbanPaths.recordingsByteCount()
            apiKeyDraft = app.settings.apiKey
            apiKeyStored = !apiKeyDraft.isEmpty
            geminiKeyDraft = app.settings.geminiAPIKey
            geminiKeyStored = !geminiKeyDraft.isEmpty
        }
        .onDisappear {
            commitAPIKey()
            commitGeminiKey()
        }
        .confirmationDialog("Delete every saved recording?",
                            isPresented: $confirmingRecordingPurge,
                            titleVisibility: .visible) {
            Button("Delete Recordings", role: .destructive) {
                app.deleteAllRecordingFiles()
                recordingsBytes = KanbanPaths.recordingsByteCount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The meetings, their notes and their transcripts are kept — only the audio "
                 + "files are deleted. Anything still waiting to upload is left alone. "
                 + "This cannot be undone.")
        }
        .confirmationDialog("Permanently delete \(archivedCount) archived task\(archivedCount == 1 ? "" : "s")?",
                            isPresented: $confirmingArchivedPurge,
                            titleVisibility: .visible) {
            Button("Delete Archived Tasks", role: .destructive) {
                let removed = app.purgeArchived()
                app.flash("PURGED \(removed)")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are removed from this Mac"
                 + (app.settings.backendIsConfigured ? " and from the VPS" : "")
                 + ". This cannot be undone.")
        }
        .confirmationDialog("Discard \(app.sync.pendingCount) queued change\(app.sync.pendingCount == 1 ? "" : "s")?",
                            isPresented: $confirmingOutboxDiscard,
                            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                app.store.clearOutbox()
                app.flash("QUEUE DISCARDED")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Those edits have not reached the VPS. Discarding them keeps the local copy but "
                 + "the next refresh will replace it with the server's version.")
        }
        .confirmationDialog("Replace \(app.store.tasks.count) local task\(app.store.tasks.count == 1 ? "" : "s") with the empty server?",
                            isPresented: $confirmingEmptyPull,
                            titleVisibility: .visible) {
            Button("Delete Local Tasks", role: .destructive) {
                Task { await app.sync.pull(allowEmptyTasks: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server has no tasks. Your local tasks are not on the VPS and will be "
                 + "removed from this Mac. This cannot be undone.")
        }
        .sheet(isPresented: $showingArchived) {
            ArchivedTasksSheet().environment(app)
        }
    }

    // MARK: Blocks

    private func appearanceBlock(_ settings: Bindable<AppSettings>) -> some View {
        block("appearance") {
            row("THEME") {
                SegmentPicker(selection: settings.appearance,
                              options: AppearanceChoice.allCases.map { ($0, $0.label) })
                    .frame(width: 190)
            }
            row("ACCENT") {
                SegmentPicker(selection: settings.accent,
                              options: AccentChoice.allCases.map { ($0, $0.label) })
                    .frame(width: 250)
            }
            row("DOCK ICON") {
                PillToggle(isOn: app.settings.showInDock) { settings.showInDock.wrappedValue.toggle() }
            }
        }
    }

    private func tasksBlock(_ settings: Bindable<AppSettings>) -> some View {
        block("tasks") {
            row("DEFAULT PRIORITY") {
                SegmentPicker(selection: settings.defaultPriority,
                              options: Priority.allCases.map { ($0, $0.label) })
                    .frame(width: 190)
            }
            row("DEFAULT COLUMN") {
                SegmentPicker(selection: settings.defaultStatus,
                              options: TaskStatus.allCases.map { ($0, $0.label) })
                    .frame(width: 230)
            }
            row("SHOW DONE COLUMN") {
                PillToggle(isOn: app.settings.showDoneColumn) { settings.showDoneColumn.wrappedValue.toggle() }
            }
            row("ARCHIVED") {
                HStack(spacing: 8) {
                    Text("\(archivedCount) RECORD\(archivedCount == 1 ? "" : "S")")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(theme.inkSecondary)
                    Button("RESTORE…") { showingArchived = true }
                        .buttonStyle(PanelButtonStyle(compact: true))
                        .disabled(archivedCount == 0)
                    Button("PURGE") { confirmingArchivedPurge = true }
                        .buttonStyle(PanelButtonStyle(compact: true))
                        .disabled(archivedCount == 0)
                }
            }
        }
    }

    private func meetingsBlock(_ settings: Bindable<AppSettings>) -> some View {
        block("meeting recordings") {
            row("MICROPHONE") {
                PillToggle(isOn: app.settings.captureMicrophone) {
                    settings.captureMicrophone.wrappedValue.toggle()
                    Task { await app.recorder.probe() }
                }
            }
            row("SYSTEM AUDIO") {
                PillToggle(isOn: app.settings.captureSystemAudio) {
                    settings.captureSystemAudio.wrappedValue.toggle()
                    Task { await app.recorder.probe() }
                }
            }
            row("AUTO UPLOAD") {
                PillToggle(isOn: app.settings.autoUpload) { settings.autoUpload.wrappedValue.toggle() }
            }
            row("KEEP RECORDINGS") {
                PillToggle(isOn: app.settings.keepRecordings) { settings.keepRecordings.wrappedValue.toggle() }
            }
            row("RECORDINGS ON DISK") {
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: recordingsBytes, countStyle: .file)
                        .uppercased())
                        .font(Theme.mono(10.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkSecondary)
                        .frame(width: 70, alignment: .leading)
                    Button("REVEAL") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [KanbanPaths.ensureRecordingsDirectory()])
                    }
                    .buttonStyle(PanelButtonStyle(compact: true))
                    Button("DELETE ALL") { confirmingRecordingPurge = true }
                        .buttonStyle(PanelButtonStyle(compact: true))
                        .disabled(recordingsBytes == 0)
                }
            }
            row("MICROPHONE ACCESS") {
                permissionControls(
                    state: app.recorder.sources.microphone,
                    pane: "Privacy_Microphone",
                    enabled: app.settings.captureMicrophone)
            }
            row("SCREEN RECORDING") {
                permissionControls(
                    state: app.recorder.sources.systemAudio,
                    pane: "Privacy_ScreenCapture",
                    enabled: app.settings.captureSystemAudio)
            }
            if app.recorder.needsPermission {
                HStack(spacing: 8) {
                    Button("GRANT ACCESS") {
                        Task { await app.recorder.requestPermissions() }
                    }
                    .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                    Button("RE-CHECK") { Task { await app.recorder.probe() } }
                        .buttonStyle(PanelButtonStyle(compact: true))
                }
                .padding(.leading, 168)
                note("macOS only lists an app under Privacy & Security once it has asked for the permission. Press GRANT ACCESS to ask \u{2014} that is what puts Kanban in those lists. Screen Recording also needs the app quit and reopened afterwards.")
            }
            note("Recording never starts on its own. With AUTO UPLOAD on, stopping a recording saves it to this Mac and sends it to the VPS for transcription; with it off, audio only leaves this Mac when you press PROCESS. KEEP RECORDINGS decides whether the audio survives once the VPS has returned results.")
        }
    }

    private func backendBlock(_ settings: Bindable<AppSettings>) -> some View {
        block("vps (optional sync)") {
            row("SERVER URL") {
                field(text: settings.serverURL, placeholder: "https://vps.example.com")
            }
            if let problem = serverURLProblem {
                note(problem)
            }
            row("API KEY") {
                HStack(spacing: 8) {
                    secureField(text: $apiKeyDraft, placeholder: "bearer token")
                        .focused($apiKeyFocused)
                        .onSubmit { commitAPIKey() }
                        .onChange(of: apiKeyFocused) { _, focused in
                            if !focused { commitAPIKey() }
                        }
                    Button("SAVE") { commitAPIKey() }
                        .buttonStyle(PanelButtonStyle(compact: true))
                    MicroLabel(apiKeyStored ? "in keychain" : "not set")
                }
            }
            if app.settings.apiKeyWriteFailed {
                note("Could not write the API key to the keychain. It works for this session but "
                     + "will be gone after a restart — unlock the login keychain and press SAVE again.")
            }
            row("TIMEOUT") {
                HStack(spacing: 8) {
                    Stepper(value: settings.requestTimeout, in: 5...120, step: 5) { EmptyView() }
                        .labelsHidden()
                    Text("\(Int(app.settings.requestTimeout))s")
                        .font(Theme.mono(11)).monospacedDigit()
                        .foregroundStyle(theme.ink)
                }
            }
            row("CONFIRM DESTRUCTIVE") {
                PillToggle(isOn: app.settings.confirmDestructiveAgentActions) {
                    settings.confirmDestructiveAgentActions.wrappedValue.toggle()
                }
            }
            row("STATUS") {
                HStack(spacing: 8) {
                    StatusDot(app.sync.connection.isOnline ? .on :
                                app.sync.connection == .unconfigured ? .off : .alert)
                    Text(app.sync.connection.label)
                        .font(Theme.mono(10.5, weight: .medium))
                        .foregroundStyle(theme.inkSecondary)
                    Button("CONNECT") { Task { await app.connect() } }
                        .buttonStyle(PanelButtonStyle(compact: true))
                }
            }
            row("LAST SYNC") {
                Text(app.sync.lastSyncedAt.map { DateInput.shortLabel($0) } ?? "NEVER")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(theme.inkSecondary)
            }
            if app.sync.pendingCount > 0 {
                row("QUEUED") {
                    HStack(spacing: 8) {
                        Text("\(app.sync.pendingCount) CHANGES")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(theme.inkSecondary)
                        Button("RETRY") { Task { await app.sync.flushOutbox() } }
                            .buttonStyle(PanelButtonStyle(compact: true))
                        Button("DISCARD") { confirmingOutboxDiscard = true }
                            .buttonStyle(PanelButtonStyle(compact: true))
                    }
                }
            }
            if let error = app.sync.lastError {
                note(error)
            }
            if app.sync.heldEmptyPull {
                HStack(spacing: 8) {
                    Button("REPLACE WITH EMPTY SERVER…") { confirmingEmptyPull = true }
                        .buttonStyle(PanelButtonStyle(compact: true))
                }
            }
            note("Transcription and analysis happen inside this app. A VPS is optional and only adds multi-device sync.")
        }
    }

    private func localAIBlock(_ settings: Bindable<AppSettings>) -> some View {
        block("local ai") {
            row("GEMINI KEY") {
                HStack(spacing: 8) {
                    secureField(text: $geminiKeyDraft, placeholder: "AIza…")
                        .focused($geminiKeyFocused)
                        .onSubmit { commitGeminiKey() }
                        .onChange(of: geminiKeyFocused) { _, focused in
                            if !focused { commitGeminiKey() }
                        }
                    Button("SAVE") { commitGeminiKey() }
                        .buttonStyle(PanelButtonStyle(compact: true))
                    MicroLabel(geminiKeyStored ? "in keychain" : "not set")
                }
            }
            if app.settings.geminiKeyWriteFailed {
                note("Could not write the Gemini key to the keychain. Unlock the login keychain and press SAVE again.")
            }
            row("MODEL") {
                field(text: settings.geminiModel, placeholder: "gemini-2.5-flash")
            }
            row("SPEECH MODEL") {
                speechModelMenu(settings)
            }
            row("QUALITY") {
                speechQualityMenu(settings)
            }
            row("MODEL FILE") {
                speechModelStatus(settings)
            }
            row("VOCABULARY") {
                field(text: settings.transcriptionVocabulary,
                      placeholder: "names, products, acronyms")
            }
            note("Meetings are transcribed on this Mac by whisper, through the same engine and GGUF models Handy uses. Audio never leaves this Mac; only the transcript goes to Gemini for analysis.")
        }
    }


    // MARK: Speech model

    private var selectedSpeechModel: ModelCatalog.Entry? {
        app.catalog?.entry(app.settings.transcriptionModelID)
    }

    private var selectedSpeechFile: ModelCatalog.File? {
        guard let entry = selectedSpeechModel else { return nil }
        return entry.file(quant: app.settings.transcriptionQuant.isEmpty
                          ? nil : app.settings.transcriptionQuant)
    }

    private func speechModelMenu(_ settings: Bindable<AppSettings>) -> some View {
        Menu {
            if let catalog = app.catalog {
                ForEach(catalog.whisperModels) { model in
                    Button {
                        settings.transcriptionModelID.wrappedValue = model.id
                        settings.transcriptionQuant.wrappedValue = ""
                    } label: {
                        if model.id == app.settings.transcriptionModelID {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            }
        } label: {
            menuLabel(selectedSpeechModel?.name.uppercased() ?? "NO CATALOG")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func speechQualityMenu(_ settings: Bindable<AppSettings>) -> some View {
        Menu {
            if let entry = selectedSpeechModel {
                ForEach(entry.quantKeys, id: \.self) { key in
                    Button {
                        settings.transcriptionQuant.wrappedValue = key
                    } label: {
                        let size = ByteCountFormatter.string(
                            fromByteCount: entry.files[key]?.size ?? 0, countStyle: .file)
                        Text("\(key) · \(size)")
                    }
                }
            }
        } label: {
            let entry = selectedSpeechModel
            let file = selectedSpeechFile
            let size = ByteCountFormatter.string(fromByteCount: file?.size ?? 0, countStyle: .file)
            menuLabel((app.settings.transcriptionQuant.isEmpty ? entry?.quant : app.settings.transcriptionQuant)
                .map { "\($0) · \(size)" } ?? "—")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func speechModelStatus(_ settings: Bindable<AppSettings>) -> some View {
        let entry = selectedSpeechModel
        let file = selectedSpeechFile
        let key = entry.flatMap { entry in file.map { ModelDownloader.key(entry, $0) } }
        let progress = key.flatMap { app.models.active[$0] }
        let installed: Bool = {
            guard let entry, let file else { return false }
            return ModelStorage.isInstalled(entry, file: file)
        }()
        return HStack(spacing: 8) {
            if let progress {
                Text("\(Int(progress.fraction * 100))%")
                    .font(Theme.mono(10.5)).monospacedDigit()
                    .foregroundStyle(theme.inkSecondary)
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
            } else if installed, let entry, let file {
                StatusDot(.on)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file).uppercased())
                    .font(Theme.mono(10.5)).monospacedDigit()
                    .foregroundStyle(theme.inkSecondary)
                Button("DELETE") {
                    ModelStorage.delete(entry)
                    Task { await app.transcription.unload() }
                }
                .buttonStyle(PanelButtonStyle(compact: true))
            } else if let entry, let file {
                StatusDot(.alert)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file).uppercased())
                    .font(Theme.mono(10.5)).monospacedDigit()
                    .foregroundStyle(theme.inkSecondary)
                Button("DOWNLOAD") {
                    Task {
                        do {
                            _ = try await app.models.download(entry, file: file)
                            app.flash("SPEECH MODEL READY")
                        } catch {
                            app.flash("MODEL DOWNLOAD FAILED")
                        }
                    }
                }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            } else {
                Text("NO CATALOG")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(theme.signal)
            }
            if let error = app.models.lastError, progress == nil, !installed {
                Text(error.uppercased())
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.signal)
                    .lineLimit(2)
            }
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Theme.mono(10.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(theme.ink)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.inkTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
    }

    /// Commits the Gemini key only on submit, focus loss or close.
    private func commitGeminiKey() {
        let current = app.settings.geminiAPIKey
        guard geminiKeyDraft != current || app.settings.geminiKeyWriteFailed else { return }
        if app.settings.commitGeminiAPIKey(geminiKeyDraft) {
            geminiKeyStored = !geminiKeyDraft.isEmpty
            app.flash(geminiKeyDraft.isEmpty ? "GEMINI KEY REMOVED" : "GEMINI KEY SAVED")
        }
    }

    /// Commits the draft on submit, focus loss, or close. An unchanged value is skipped
    /// so merely opening Settings never rewrites the Keychain.
    private func commitAPIKey() {
        let current = app.settings.apiKey
        guard apiKeyDraft != current || app.settings.apiKeyWriteFailed else { return }
        if app.settings.commitAPIKey(apiKeyDraft) {
            apiKeyStored = !apiKeyDraft.isEmpty
            app.flash(apiKeyDraft.isEmpty ? "API KEY REMOVED" : "API KEY SAVED")
        }
    }

    private func notificationsBlock(_ settings: Bindable<AppSettings>) -> some View {
        block("notifications") {
            row("DUE REMINDERS") {
                PillToggle(isOn: app.settings.notificationsEnabled) {
                    app.setNotifications(enabled: !app.settings.notificationsEnabled)
                }
            }
            row("MEETING PROCESSED") {
                PillToggle(isOn: app.settings.notifyOnMeetingProcessed) {
                    settings.notifyOnMeetingProcessed.wrappedValue.toggle()
                }
            }
            row("AGENT COMPLETED") {
                PillToggle(isOn: app.settings.notifyOnAgentAction) {
                    settings.notifyOnAgentAction.wrappedValue.toggle()
                }
            }
            note("Reminders are scheduled with the system at the task's due time. The app runs no timers.")
        }
    }

    private func dataBlock() -> some View {
        block("data") {
            row("LOCAL CACHE") {
                HStack(spacing: 8) {
                    Text(KanbanPaths.databaseURL.path)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("REVEAL") {
                        NSWorkspace.shared.activateFileViewerSelecting([KanbanPaths.databaseURL])
                    }
                    .buttonStyle(PanelButtonStyle(compact: true))
                }
            }
            row("VERSION") {
                Text("KANBAN \(AppInfo.version)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(theme.inkSecondary)
            }
        }
    }

    // MARK: Building blocks

    /// Status plus the two things you can actually do about it.
    private func permissionControls(state: CaptureSources.State, pane: String,
                                    enabled: Bool) -> some View {
        HStack(spacing: 8) {
            StatusDot(enabled ? (state.isWorking ? .on : .alert) : .off)
            Text(enabled ? state.label : "OFF")
                .font(Theme.mono(10.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(enabled ? (state.isWorking ? theme.ink : theme.signal)
                                         : theme.inkTertiary)
                .frame(width: 92, alignment: .leading)

            if enabled {
                Button("OPEN SETTINGS") {
                    // Deep-links to the specific pane; the generic one drops you on
                    // Microphone even when it is Screen Recording that is missing.
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .buttonStyle(PanelButtonStyle(compact: true))
            }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 9) {
                MicroLabel(title)
                Rule()
                content()
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(Theme.mono(10.5))
                .tracking(0.6)
                .foregroundStyle(theme.inkSecondary)
                .frame(width: 168, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(9.5))
            .foregroundStyle(theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    private func field(text: Binding<String>, placeholder: String) -> some View {
        TextField("", text: text, prompt: Text(placeholder)
            .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
            .frame(maxWidth: 280)
    }

    private func secureField(text: Binding<String>, placeholder: String) -> some View {
        SecureField("", text: text, prompt: Text(placeholder)
            .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
            .frame(maxWidth: 200)
    }
}

// MARK: - Archived tasks

/// The recovery path for ARCHIVE. Without it an archived task would be unreachable:
/// the board hides it and the only other action was PURGE.
private struct ArchivedTasksSheet: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var archived: [TaskItem] {
        app.store.tasks
            .filter(\.isArchived)
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                MicroLabel("archived tasks")
                Spacer()
                Button("DONE") { dismiss() }
                    .buttonStyle(BareButtonStyle(emphasised: true))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 9)

            Rule()

            if archived.isEmpty {
                VStack(spacing: 5) {
                    Text("—").font(Theme.mono(14)).foregroundStyle(theme.line)
                    MicroLabel("nothing archived")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(archived) { task in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .font(Theme.body)
                                        .foregroundStyle(theme.ink)
                                        .lineLimit(1)
                                    Text(archivedLabel(task))
                                        .font(Theme.mono(9.5))
                                        .foregroundStyle(theme.inkTertiary)
                                }
                                Spacer(minLength: 8)
                                Button("RESTORE") {
                                    _ = try? app.taskService.unarchive(task.id)
                                }
                                .buttonStyle(PanelButtonStyle(compact: true))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Rule() }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: 480, height: 380)
        .background(theme.paper)
        .environment(\.theme, app.theme)
    }

    private func archivedLabel(_ task: TaskItem) -> String {
        guard let date = task.archivedAt else { return task.status.label }
        return "ARCHIVED \(DateInput.shortLabel(date)) · \(task.status.label)"
    }
}
