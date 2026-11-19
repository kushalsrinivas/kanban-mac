import SwiftUI

enum FocusTarget: Hashable {
    case quickAdd, search, board, agent
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: FocusTarget?
    /// A sidebar is a navigation drawer: it can collapse to an icon rail without
    /// losing the current section. Remembered across launches.
    @AppStorage("nav.sidebar.expanded") private var sidebarExpanded = true

    var body: some View {
        @Bindable var app = app

        ZStack {
            app.theme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TitleBar(sidebarExpanded: $sidebarExpanded)
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.top, 6)

                HStack(spacing: 0) {
                    Sidebar(expanded: $sidebarExpanded)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    // ZStack, not Group: a switch inside Group is not an insertion
                    // container, so the cross-fade never ran.
                    ZStack {
                        switch app.section {
                        case .tasks: tasksSection.transition(.opacity)
                        case .meetings: MeetingsView().padding(.top, 10).transition(.opacity)
                        case .agent: AgentConsoleView(focus: $focus).padding(.top, 10).transition(.opacity)
                        case .calendar: CalendarView().padding(.top, 10).transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: app.section)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
    @Binding var sidebarExpanded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(app.section == .tasks ? "TASK SYSTEM"
                 : app.section == .meetings ? "MEETINGS"
                 : app.section == .agent ? "AGENT" : "MEET")
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

            Button { sidebarExpanded.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 10))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle(compact: true))
            .help(sidebarExpanded ? "Collapse navigation (⌃⌘S)" : "Expand navigation (⌃⌘S)")
            .accessibilityLabel(sidebarExpanded ? "Collapse navigation" : "Expand navigation")

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

// MARK: - Sidebar

/// The main navigation drawer. It replaces the old header tabs: the categories are
/// always visible, carry their counts, and can collapse to a compact rail when the
/// board needs the width.
private struct Sidebar: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var expanded: Bool

    /// Deliberately explicit: MEET belongs beside the recordings it summarises, and
    /// the agent stays last as the conversational surface.
    private let order: [AppModel.Section] = [.tasks, .meetings, .calendar, .agent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            Rule()
            nav
            Spacer(minLength: 0)
            if app.recorder.isRecording { recording }
            Rule()
            footer
        }
        .frame(width: expanded ? 208 : 64)
        .background(theme.panelAlt)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.lineStrong).frame(width: Theme.Metric.hairline)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Text("WC")
                .font(Theme.mono(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(theme.paper)
                .frame(width: 28, height: 28)
                .background(theme.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    Text("WORK CONSOLE")
                        .font(Theme.mono(9.5, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(theme.ink)
                    Text("LOCAL-FIRST")
                        .font(Theme.mono(8))
                        .tracking(0.8)
                        .foregroundStyle(theme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, expanded ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
        .padding(.vertical, 12)
    }

    private var nav: some View {
        VStack(spacing: 3) {
            ForEach(order, id: \.self) { section in
                SidebarItem(section: section, expanded: expanded,
                            badge: badge(for: section), alert: alert(for: section)) {
                    app.section = section
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    private var recording: some View {
        Button { app.section = .meetings } label: {
            HStack(spacing: 7) {
                Circle().fill(theme.signal).frame(width: 6, height: 6)
                if expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("RECORDING")
                            .font(Theme.mono(8.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(theme.signal)
                        Text(Meeting.timecode(app.recorder.elapsed))
                            .font(Theme.mono(10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(theme.ink)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, expanded ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Recording — open meetings")
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: expanded ? "sidebar.left" : "sidebar.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 18)
                    if expanded {
                        Text("COLLAPSE")
                            .font(Theme.mono(9))
                            .tracking(0.8)
                        Spacer(minLength: 0)
                        Text("⌃⌘S")
                            .font(Theme.mono(8.5))
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
                .foregroundStyle(theme.inkSecondary)
                .padding(.horizontal, expanded ? 12 : 0)
                .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse navigation" : "Expand navigation")
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
        .padding(.vertical, 4)
    }

    private func badge(for section: AppModel.Section) -> String? {
        switch section {
        case .tasks:
            let open = app.store.counts().open
            return open > 0 ? String(format: "%02d", open) : nil
        case .meetings:
            let suggestions = app.openSuggestionCount
            return suggestions > 0 ? "\(suggestions)" : nil
        case .calendar:
            let upcoming = app.upcomingMeetings().count
            return upcoming > 0 ? String(format: "%02d", upcoming) : nil
        case .agent:
            let pending = app.agent.pending.count
            return pending > 0 ? "\(pending)" : nil
        }
    }

    /// The count says "there is work here"; the dot says "something needs a
    /// decision". Only meetings and overdue commitments earn red.
    private func alert(for section: AppModel.Section) -> Bool {
        switch section {
        case .meetings:
            return app.openSuggestionCount > 0
        case .calendar:
            return !app.store.overdueCommitments.isEmpty
        default:
            return false
        }
    }
}

private struct SidebarItem: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let section: AppModel.Section
    let expanded: Bool
    let badge: String?
    let alert: Bool
    let action: () -> Void
    @State private var hovering = false

    private var active: Bool { app.section == section }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .frame(width: 18, alignment: .center)
                    .overlay(alignment: .topTrailing) {
                        if !expanded && alert {
                            Circle().fill(theme.signal).frame(width: 5, height: 5)
                                .offset(x: 3, y: -2)
                        }
                    }

                if expanded {
                    Text(section.label)
                        .font(Theme.mono(10, weight: active ? .semibold : .regular))
                        .tracking(0.9)
                    Spacer(minLength: 0)
                    if alert {
                        Circle().fill(active ? theme.paper : theme.signal)
                            .frame(width: 5, height: 5)
                    }
                    if let badge {
                        Text(badge)
                            .font(Theme.mono(9))
                            .monospacedDigit()
                            .foregroundStyle(active ? theme.paper.opacity(0.7) : theme.inkTertiary)
                    }
                }
            }
            .foregroundStyle(active ? theme.paper : theme.inkSecondary)
            .padding(.horizontal, expanded ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.vertical, 8)
            .background(active ? theme.ink : (hovering ? theme.panel : Color.clear),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var icon: String {
        switch section {
        case .tasks: return "rectangle.split.3x1"
        case .meetings: return "waveform"
        case .calendar: return "calendar.badge.clock"
        case .agent: return "terminal"
        }
    }

    private var tooltip: String {
        let count = badge.map { " · \($0)" } ?? ""
        switch section {
        case .tasks: return "\(app.store.counts().open) open task\(app.store.counts().open == 1 ? "" : "s")\(count)"
        case .meetings: return "Meetings and recordings\(count)"
        case .calendar: return "Briefs, commitments, memory and automation\(count)"
        case .agent: return "Agent console\(count)"
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
            MicroLabel("⌘⇧A AGENT")
            MicroLabel("⌘⌥4 MEET")
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
