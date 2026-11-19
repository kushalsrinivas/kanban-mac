import SwiftUI

/// Raycast-style palette: one field, one list, Return runs the highlighted row.
/// Commands and tasks share the list, so "deploy" jumps to a task and "move" offers
/// the move commands without any mode switching.
struct CommandPaletteView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Scrim: flat, no blur — blur is expensive and off-language here.
            Rectangle()
                .fill(theme.paper.opacity(0.72))
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                field
                if !rows.isEmpty {
                    Rule()
                    list
                }
            }
            .frame(width: 520)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
            .padding(.top, 88)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Text(">")
                .font(Theme.mono(13, weight: .medium))
                .foregroundStyle(theme.inkTertiary)

            TextField("", text: $query, prompt: Text("run a command or find a task")
                .font(Theme.display(14)).foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(Theme.display(14))
                .foregroundStyle(theme.ink)
                .focused($fieldFocused)
                .onSubmit(runHighlighted)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) { isPresented = false; return .handled }

            MicroLabel("esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        PaletteRow(row: row, isHighlighted: index == highlighted)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { run(row) }
                            .onHover { if $0 { highlighted = index } }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { run(row) }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 320)
            .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
        }
    }

    // MARK: Rows

    private var rows: [PaletteItem] {
        let commands = PaletteItem.commands(app: app)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(commands.prefix(9)) }

        let scoredCommands = commands
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = fuzzyScore(trimmed, in: item.title + " " + item.subtitle) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        let matchingTasks = app.store.tasks
            .filter { !$0.isArchived && $0.matches(query: trimmed) }
            .agendaSorted()
            .prefix(6)
            .map { PaletteItem.task($0, app: app) }

        // Creating what you typed is always available as the last resort.
        let create = PaletteItem(
            id: "create-literal",
            title: "Create “\(QuickParse.parse(trimmed).title)”",
            subtitle: QuickParse.hint(for: trimmed, defaultPriority: app.settings.defaultPriority,
                                      defaultStatus: app.settings.defaultStatus),
            group: "NEW",
            action: {
                if app.quickAdd(trimmed) != nil { app.flash("TASK FILED") }
            }
        )

        return Array((scoredCommands + matchingTasks).prefix(9)) + [create]
    }

    // MARK: Actions

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .handled }
        highlighted = max(0, min(rows.count - 1, highlighted + delta))
        return .handled
    }

    private func runHighlighted() {
        guard rows.indices.contains(highlighted) else { return }
        run(rows[highlighted])
    }

    private func run(_ row: PaletteItem) {
        isPresented = false
        row.action()
    }

    /// Subsequence match with a bonus for contiguous runs and word starts.
    private func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        var score = 0, ni = 0, streak = 0
        for (index, char) in h.enumerated() {
            guard ni < n.count else { break }
            if char == n[ni] {
                score += 1 + streak
                if index == 0 || h[index - 1] == " " { score += 3 }
                streak += 1
                ni += 1
            } else {
                streak = 0
            }
        }
        return ni == n.count ? score : nil
    }
}

// MARK: - Items

struct PaletteItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var group: String
    var shortcut: String = ""
    var action: () -> Void

    @MainActor
    static func commands(app: AppModel) -> [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(id: "new", title: "Create task", subtitle: "focus the quick-add field",
                        group: "TASK", shortcut: "⌘N", action: { app.newTask() }),
            PaletteItem(id: "search", title: "Search tasks", subtitle: "filter the board",
                        group: "FIND", shortcut: "⌘F", action: {
                            if !app.isSearchActive { app.toggleSearch() }
                        }),
            PaletteItem(id: "today", title: "Show today's tasks", subtitle: "due today and overdue",
                        group: "FIND", action: {
                            app.isSearchActive = false
                            let due = app.store.openTasks.agendaSorted()
                                .filter { $0.isDueToday() || $0.isOverdue() }
                            if let first = due.first {
                                app.selection = first.id
                                app.focusedStatus = first.status
                                app.openInspector(for: first.id)
                                app.flash("\(due.count) DUE TODAY")
                            } else {
                                app.flash("NOTHING DUE TODAY")
                            }
                        }),
            PaletteItem(id: "agent", title: "Ask agent", subtitle: "open the agent console",
                        group: "AGENT", shortcut: "⌘⇧A", action: { app.section = .agent }),
            PaletteItem(id: "calendar", title: "Open Meet", subtitle: "briefs, commitments, memory, automation",
                        group: "MEET", shortcut: "⌘⌥4", action: { app.openCalendar() }),
            PaletteItem(id: "record", title: "Record meeting", subtitle: "start a new recording",
                        group: "MEETING", shortcut: "⌘R", action: { app.startRecording() }),
            PaletteItem(id: "meetings", title: "Show meetings", subtitle: "recordings and notes",
                        group: "MEETING", action: { app.section = .meetings }),
            PaletteItem(id: "suggestions", title: "Review suggested tasks",
                        subtitle: "\(app.openSuggestionCount) awaiting review",
                        group: "MEETING", action: {
                            app.section = .meetings
                            if let meeting = app.store.meetings.first(where: { $0.suggestedCount > 0 }) {
                                app.selectedMeeting = meeting.id
                            }
                        }),
            PaletteItem(id: "sync", title: "Sync with VPS", subtitle: app.sync.connection.label,
                        group: "APP", action: { Task { await app.connect() } }),
            PaletteItem(id: "settings", title: "Open settings", subtitle: "appearance, agent, API",
                        group: "APP", shortcut: "⌘,", action: {
                            // Settings moved from the preferences selector in Ventura;
                            // try both, and tell the user rather than doing nothing.
                            let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                                || NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                            if !opened { app.flash("SETTINGS UNAVAILABLE · PRESS ⌘,") }
                        })
        ]

        if let selected = app.selectedTask {
            let name = selected.title
            items.insert(contentsOf: [
                PaletteItem(id: "complete", title: selected.isDone ? "Reopen selected task" : "Complete selected task",
                            subtitle: name, group: "TASK", shortcut: "␣",
                            action: { app.completeSelection() }),
                PaletteItem(id: "archive", title: "Archive selected task", subtitle: name,
                            group: "TASK", shortcut: "⌫", action: { app.archiveSelection() })
            ], at: 1)

            for column in TaskStatus.allCases where column != selected.status {
                items.append(PaletteItem(
                    id: "move-\(column.rawValue)",
                    title: "Move selected task to \(column.label.capitalized)",
                    subtitle: name, group: "MOVE",
                    action: { app.moveSelection(to: column) }))
            }
        }

        for column in TaskStatus.allCases {
            items.append(PaletteItem(
                id: "focus-\(column.rawValue)",
                title: "Go to \(column.label.capitalized)",
                subtitle: "\(app.store.tasks(in: column).count) tasks",
                group: "VIEW",
                action: { app.focus(status: column) }))
        }

        items.append(PaletteItem(id: "appearance", title: "Toggle appearance",
                                 subtitle: app.settings.appearance.label, group: "APP", action: {
                                     app.settings.appearance = app.settings.appearance == .dark ? .light : .dark
                                 }))
        return items
    }

    @MainActor
    static func task(_ task: TaskItem, app: AppModel) -> PaletteItem {
        var subtitle = "\(task.status.label) · \(task.priority.label)"
        if let due = task.dueDate { subtitle += " · \(DateInput.shortLabel(due))" }
        return PaletteItem(id: task.id.uuidString, title: task.title, subtitle: subtitle, group: "OPEN", action: {
            app.selection = task.id
            app.focusedStatus = task.status
            app.openInspector(for: task.id)
        })
    }
}

private struct PaletteRow: View {
    @Environment(\.theme) private var theme
    let row: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(row.group)
                .font(Theme.mono(9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(theme.inkTertiary)
                .lineLimit(1)
                .frame(width: 56, alignment: .leading)

            Text(row.title)
                .font(Theme.display(12.5))
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.subtitle)
                .font(Theme.mono(9.5))
                .foregroundStyle(theme.inkTertiary)
                .lineLimit(1)

            if !row.shortcut.isEmpty {
                Text(row.shortcut)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkSecondary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHighlighted ? theme.selectionFill : .clear)
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle().fill(theme.ink).frame(width: 2)
            }
        }
    }
}
