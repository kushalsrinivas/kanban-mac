import SwiftUI

enum FocusTarget: Hashable {
    case quickAdd, search, board, agent
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: FocusTarget?

    var body: some View {
        @Bindable var app = app

        ZStack {
            app.theme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TitleBar()
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.top, 6)

                SectionTabs()
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.top, 10)

                // ZStack, not Group: a switch inside Group is not an insertion
                // container, so the cross-fade never ran.
                ZStack {
                    switch app.section {
                    case .tasks: tasksSection.transition(.opacity)
                    case .meetings: MeetingsView().padding(.top, 10).transition(.opacity)
                    case .agent: AgentConsoleView(focus: $focus).padding(.top, 10).transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: app.section)

                StatusFooter()
            }
        }
        .environment(\.theme, app.theme)
        .preferredColorScheme(app.settings.colorScheme)
        .onAppear {
            app.systemIsDark = colorScheme == .dark
            // On a genuinely empty board the hint says to type; make that true.
            let live = app.store.tasks.filter { !$0.isArchived }
            focus = live.isEmpty ? .quickAdd : .board
        }
        .onChange(of: colorScheme) { _, new in app.systemIsDark = new == .dark }
        .onChange(of: app.quickAddRequestID) { _, _ in focus = .quickAdd }
        .onChange(of: app.isSearchActive) { _, active in focus = active ? .search : .board }
        .onChange(of: app.inspector) { _, inspector in
            // Board shortcuts must not stay armed while the inspector is being
            // edited, and closing it should give the board its keyboard back.
            switch inspector {
            case .task:
                if focus == .board { focus = nil }
            case .hidden:
                if focus == nil { focus = .board }
            }
        }
        .overlay {
            if app.isPaletteOpen {
                CommandPaletteView(isPresented: $app.isPaletteOpen)
                    .environment(\.theme, app.theme)
                    .transition(.opacity.combined(with: .scale(0.98)))
                    .accessibilityAddTraits(.isModal)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: app.isPaletteOpen)
        // The one modal in the app: turning an AI suggestion into a real task.
        .overlay {
            if let draft = app.pendingSuggestion {
                ZStack {
                    Rectangle()
                        .fill(app.theme.paper.opacity(0.72))
                        .ignoresSafeArea()
                        .onTapGesture { app.pendingSuggestion = nil }
                    AddTaskConfirmation(draft: draft)
                        .id(draft.id)
                        .accessibilityAddTraits(.isModal)
                }
                .environment(\.theme, app.theme)
                .transition(.opacity.combined(with: .scale(0.97)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: app.pendingSuggestion != nil)
        .confirmationDialog("Delete this task?",
                            isPresented: Binding(get: { app.deletionRequest != nil },
                                                 set: { if !$0 { app.deletionRequest = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) { app.confirmDeletion() }
            Button("Cancel", role: .cancel) { app.deletionRequest = nil }
        } message: {
            Text("“\(app.selectedTask?.title ?? "This task")” is removed from this Mac"
                 + (app.settings.backendIsConfigured ? " and the VPS" : "")
                 + ". This cannot be undone.")
        }
        .onKeyPress(.upArrow) { arrow(.up) }
        .onKeyPress(.downArrow) { arrow(.down) }
        .onKeyPress(.leftArrow) { arrow(.left) }
        .onKeyPress(.rightArrow) { arrow(.right) }
        .onKeyPress(.return) {
            guard boardHasFocus, let id = app.selection else { return .ignored }
            app.openInspector(for: id)
            return .handled
        }
        .onKeyPress(.space) {
            guard boardHasFocus, app.selection != nil else { return .ignored }
            app.completeSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            if app.pendingSuggestion != nil { app.pendingSuggestion = nil; return .handled }
            if app.isPaletteOpen { app.isPaletteOpen = false; return .handled }
            if app.isSearchActive { app.toggleSearch(); focus = .board; return .handled }
            if app.inspector != .hidden { app.closeInspector(); focus = .board; return .handled }
            return .ignored
        }
        .onKeyPress(.delete) {
            guard boardHasFocus, app.selection != nil else { return .ignored }
            app.archiveSelection()
            return .handled
        }
    }

    private var boardHasFocus: Bool { focus == .board && app.section == .tasks }

    // MARK: Tasks section

    private var tasksSection: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            StatusPanel()
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.top, 10)

            QuickAddBar(focus: $focus)
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.top, 10)

            // First run: the board of empty columns says nothing about what to do.
            // Count only live tasks: archived rows are pulled now, and a board whose
            // only tasks are archived is still empty to the user.
            if app.store.tasks.filter({ !$0.isArchived }).isEmpty && !app.isSearchActive {
                Text("TYPE ABOVE OR PRESS ⌘N TO FILE YOUR FIRST TASK")
                    .font(Theme.mono(9.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(app.theme.inkTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }

            if app.isSearchActive {
                SearchBar(focus: $focus)
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.top, 8)
            }

            HStack(spacing: 0) {
                BoardView()
                    .focused($focus, equals: .board)

                if app.inspector != .hidden {
                    VRule()
                    InspectorView(focus: $focus)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.top, 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: app.inspector == .hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func arrow(_ direction: MoveCommandDirection) -> KeyPress.Result {
        guard boardHasFocus else { return .ignored }
        if NSEvent.modifierFlags.contains(.option), direction == .up || direction == .down {
            app.shiftSelection(up: direction == .up)
        } else {
            app.moveSelectionCursor(direction)
        }
        return .handled
    }
}

// MARK: - Title bar

private struct TitleBar: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(app.section == .tasks ? "TASK SYSTEM"
                 : app.section == .meetings ? "MEETINGS" : "AGENT")
                .font(Theme.display(24, weight: .medium))
                .tracking(-0.2)
                .foregroundStyle(theme.ink)

            if let message = app.transientMessage {
                HStack(spacing: 8) {
                    Text(message)
                        .font(Theme.mono(9.5, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(theme.inkTertiary)
                    if app.canUndo {
                        Button("UNDO") { app.undoLast() }
                            .buttonStyle(PanelButtonStyle(compact: true))
                    }
                }
                .padding(.bottom, 2)
            }

            Spacer(minLength: 0)

            // A recording in progress follows you across every section.
            if app.recorder.isRecording {
                Button { app.section = .meetings } label: {
                    HStack(spacing: 5) {
                        Circle().fill(theme.signal).frame(width: 6, height: 6)
                        Text(Meeting.timecode(app.recorder.elapsed))
                            .font(Theme.mono(10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(theme.ink)
                    }
                }
                .buttonStyle(PanelButtonStyle(compact: true))
                .help("Recording — open meetings")
            }

            ConnectionBadge()

            Button { app.toggleSearch() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle(compact: true))
            .help("Search (⌘F)")
            .accessibilityLabel("Search")

            Button { app.isPaletteOpen = true } label: { Text("⌘K") }
                .buttonStyle(PanelButtonStyle(compact: true))
                .help("Command palette")

            SettingsLink {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle(compact: true))
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.leading, 64)   // clears the traffic lights
    }
}

/// VPS reachability, plus anything queued while offline.
private struct ConnectionBadge: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            if app.settings.backendIsConfigured {
                Task { await app.connect() }
            } else {
                // Clicking LOCAL should take you to the thing it is missing.
                openSettings()
            }
        } label: {
            HStack(spacing: 5) {
                StatusDot(dot)
                Text(app.sync.connection.label)
                    .font(Theme.mono(9.5, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(theme.inkSecondary)
                if app.sync.pendingCount > 0 {
                    Text("↑\(app.sync.pendingCount)")
                        .font(Theme.mono(9.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkTertiary)
                }
            }
        }
        .buttonStyle(PanelButtonStyle(compact: true))
        .help(helpText)
    }

    private var dot: StatusDot.State {
        switch app.sync.connection {
        case .online: return .on
        case .offline: return .alert
        case .checking: return .idle
        case .unconfigured: return .off
        }
    }

    private var helpText: String {
        switch app.sync.connection {
        case .unconfigured: return "Running locally. Click to open Settings."
        case .offline: return "VPS unreachable. Tasks and recording still work. Click to retry."
        case .checking: return "Checking the connection…"
        case .online:
            return app.sync.pendingCount > 0
                ? "\(app.sync.pendingCount) change(s) syncing"
                : "Connected to your VPS"
        }
    }
}

// MARK: - Section tabs

private struct SectionTabs: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppModel.Section.allCases, id: \.self) { section in
                let active = app.section == section
                Button { app.section = section } label: {
                    HStack(spacing: 5) {
                        Text(section.label)
                            .font(Theme.mono(10.5, weight: active ? .semibold : .regular))
                            .tracking(1)
                        if let badge = badge(for: section) {
                            if section == .meetings {
                                // A count alone reads as "meetings"; the dot says an
                                // item needs review.
                                Circle()
                                    .fill(theme.signal)
                                    .overlay(Circle().strokeBorder(active ? theme.paper : .clear, lineWidth: 1))
                                    .frame(width: 5, height: 5)
                            }
                            Text(badge)
                                .font(Theme.mono(9))
                                .monospacedDigit()
                                .foregroundStyle(active ? theme.paper.opacity(0.7) : theme.inkTertiary)
                        }
                    }
                    .foregroundStyle(active ? theme.paper : theme.inkSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(active ? theme.ink : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(helpText(for: section))
            }
            Spacer()
        }
        .background(theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
    }

    private func badge(for section: AppModel.Section) -> String? {
        switch section {
        case .tasks:
            let open = app.store.counts().open
            return open > 0 ? String(format: "%02d", open) : nil
        case .meetings:
            let suggestions = app.openSuggestionCount
            return suggestions > 0 ? "\(suggestions)" : nil
        case .agent:
            return nil
        }
    }

    private func helpText(for section: AppModel.Section) -> String {
        switch section {
        case .tasks:
            return "\(app.store.counts().open) open tasks"
        case .meetings:
            let suggestions = app.openSuggestionCount
            return suggestions == 0 ? "Meetings and recordings"
                : "\(suggestions) task\(suggestions == 1 ? "" : "s") to review"
        case .agent:
            return "Agent console"
        }
    }
}

// MARK: - Search

private struct SearchBar: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @FocusState.Binding var focus: FocusTarget?

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 8) {
            MicroLabel("find")
            TextField("", text: $app.searchText,
                      prompt: Text("search titles, notes, tags")
                        .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(theme.ink)
                .focused($focus, equals: .search)
                .onSubmit { focus = .board }

            Text("\(app.searchResultCount) MATCH\(app.searchResultCount == 1 ? "" : "ES")")
                .font(Theme.mono(9.5))
                .monospacedDigit()
                .foregroundStyle(theme.inkTertiary)

            Button { app.toggleSearch() } label: { Text("ESC") }
                .buttonStyle(BareButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
    }
}

// MARK: - Footer

private struct StatusFooter: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            MicroLabel("⌘N NEW")
            MicroLabel("⌘K COMMAND")
            MicroLabel("⌘F FIND")
            MicroLabel("⏎ OPEN")
            MicroLabel("⌘1-4 COLUMN")
            MicroLabel("⌘R RECORD")
            Spacer(minLength: 0)
            if let error = app.store.lastError {
                Text("STORAGE ERROR")
                    .font(Theme.mono(9.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.signal)
                    .help(error)
            }
            if app.processor.isBusy {
                MicroLabel("PROCESSING \(app.processor.active.count)")
            }
            MicroLabel("\(app.store.tasks.count) TASKS")
            MicroLabel("\(app.store.meetings.count) MEETINGS")
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rule() }
    }
}
