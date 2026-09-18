import SwiftUI

/// One scrolling pane of blocks. No tabs, no sidebar — everything fits on a page.
struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    @State private var recordingsBytes: Int64 = 0

    var body: some View {
        let bindable = Bindable(app.settings)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                appearanceBlock(bindable)
                tasksBlock(bindable)
                meetingsBlock(bindable)
                backendBlock(bindable)
                notificationsBlock(bindable)
                dataBlock()
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .frame(width: 580, height: 660)
        .background(theme.paper)
        .environment(\.theme, app.theme)
        .preferredColorScheme(app.settings.colorScheme)
        .onAppear { recordingsBytes = KanbanPaths.recordingsByteCount() }
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
                    Text("\(app.store.tasks.filter(\.isArchived).count) RECORDS")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(theme.inkSecondary)
                    Button("PURGE") {
                        let n = app.store.purgeArchivedTasks()
                        app.flash("PURGED \(n)")
                    }
                    .buttonStyle(PanelButtonStyle(compact: true))
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
            row("UPLOAD FOR TRANSCRIPTION") {
                // Not a toggle on purpose. Audio only ever leaves this Mac when the
                // user presses PROCESS on a specific recording.
                Text(app.settings.uploadPolicy)
                    .font(Theme.mono(10.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(theme.ink)
            }
            row("KEEP RECORDINGS") {
                PillToggle(isOn: app.settings.keepRecordings) { settings.keepRecordings.wrappedValue.toggle() }
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
            note("Recording never starts on its own. Audio is a transport file: unless you keep originals, it is deleted once the VPS returns results.")
        }
    }

    private func backendBlock(_ settings: Bindable<AppSettings>) -> some View {
        block("vps") {
            row("SERVER URL") {
                field(text: settings.serverURL, placeholder: "https://vps.example.com")
            }
            row("API KEY") {
                HStack(spacing: 8) {
                    secureField(text: settings.apiKey, placeholder: "bearer token")
                    MicroLabel(KeychainStore.has(.apiToken) ? "in keychain" : "not set")
                }
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
            if app.sync.pendingCount > 0 {
                row("QUEUED") {
                    HStack(spacing: 8) {
                        Text("\(app.sync.pendingCount) CHANGES")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(theme.inkSecondary)
                        Button("RETRY") { Task { await app.sync.flushOutbox() } }
                            .buttonStyle(PanelButtonStyle(compact: true))
                        Button("DISCARD") { app.store.clearOutbox() }
                            .buttonStyle(PanelButtonStyle(compact: true))
                    }
                }
            }
            if let error = app.sync.lastError {
                note(error)
            }
            note("Transcription, analysis and the agent all run on your VPS. Tasks and recording keep working when it is unreachable.")
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
                .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
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
                .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
            .frame(maxWidth: 200)
    }
}
