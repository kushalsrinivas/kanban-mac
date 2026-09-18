import SwiftUI

/// Compact menu bar popover. Counts, one-line add, today's list, and the handful of
/// actions worth having without opening the window.
struct MenuBarView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let counts = app.store.counts()
        let today = app.store.openTasks.agendaSorted()
            .filter { $0.isDueToday() || $0.isOverdue() || $0.status == .inProgress }

        VStack(alignment: .leading, spacing: 0) {
            if app.recorder.isRecording {
                recordingHeader
            } else {
                header(counts: counts)
            }

            Rule()

            quickAdd

            Rule()

            todaySection(today: today, counts: counts)

            Rule()

            actions
        }
        .frame(width: 272)
        .background(theme.paper)
        .environment(\.theme, app.theme)
    }

    // MARK: Header

    private func header(counts: (open: Int, active: Int, dueToday: Int, overdue: Int)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("TASKS")
                    .font(Theme.display(15, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                StatusDot(app.sync.connection.isOnline ? .on :
                            app.sync.connection == .unconfigured ? .off : .alert)
            }
            HStack(spacing: 6) {
                Text("\(String(format: "%02d", counts.open)) OPEN")
                Text("·")
                Text("\(String(format: "%02d", counts.dueToday)) DUE TODAY")
                if counts.overdue > 0 {
                    Text("·")
                    Text("\(counts.overdue) LATE").foregroundStyle(theme.signal)
                }
            }
            .font(Theme.mono(10))
            .monospacedDigit()
            .foregroundStyle(theme.inkSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    /// A live recording takes over the top of the popover.
    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(theme.signal).frame(width: 7, height: 7)
                Text("RECORDING")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(theme.signal)
                Spacer()
                Text(Meeting.timecode(app.recorder.elapsed))
                    .font(Theme.mono(13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.ink)
            }

            if let id = app.recorder.currentMeetingID, let meeting = app.store.meeting(id) {
                Text(meeting.title.uppercased())
                    .font(Theme.mono(10))
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Button(app.recorder.phase == .paused ? "RESUME" : "PAUSE") {
                    app.recorder.phase == .paused ? app.recorder.resume() : app.recorder.pause()
                }
                .buttonStyle(PanelButtonStyle(compact: true))

                Button("STOP") {
                    app.stopRecording()
                    openMain()
                }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            }

            // Escape hatch. If the engine ever wedges, STOP alone could leave the
            // recording state stuck; this always tears it down.
            Button("FORCE STOP") { Task { await app.recorder.forceStop() } }
                .buttonStyle(BareButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    // MARK: Pieces

    private var quickAdd: some View {
        HStack(spacing: 7) {
            Text("+").font(Theme.mono(12)).foregroundStyle(theme.inkTertiary)
            TextField("", text: $draft, prompt: Text("new task")
                .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(theme.ink)
                .focused($fieldFocused)
                .onSubmit {
                    guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    app.quickAdd(draft)
                    draft = ""
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func todaySection(today: [TaskItem],
                              counts: (open: Int, active: Int, dueToday: Int, overdue: Int)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MicroLabel("today")
                Spacer()
                Text("\(String(format: "%02d", today.count)) TASKS")
                    .font(Theme.mono(9.5))
                    .monospacedDigit()
                    .foregroundStyle(theme.inkTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 6)

            if today.isEmpty {
                Text("Nothing scheduled.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(theme.inkTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            } else {
                ForEach(today.prefix(5)) { task in
                    MenuTaskRow(task: task)
                }
                if today.count > 5 {
                    Text("+ \(today.count - 5) MORE")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                } else {
                    Color.clear.frame(height: 6)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            if !app.recorder.isRecording {
                MenuAction(label: "RECORD MEETING", shortcut: "⌘R", accent: true) {
                    openMain()
                    app.startRecording()
                }
            }
            if app.openSuggestionCount > 0 {
                MenuAction(label: "REVIEW \(app.openSuggestionCount) SUGGESTED", shortcut: "") {
                    openMain()
                    app.section = .meetings
                }
            }
            MenuAction(label: "ASK AGENT", shortcut: "⌘K") {
                openMain()
                app.section = .agent
            }
            MenuAction(label: "OPEN APP", shortcut: "⌘O") { openMain() }
            MenuAction(label: "QUIT", shortcut: "⌘Q") {
                app.shutdown()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func openMain() {
        openWindow(id: KanbanWindow.board)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuTaskRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let task: TaskItem

    @State private var hovering = false

    var body: some View {
        Button {
            try? app.taskService.complete(task.id)
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(hovering ? theme.ink : theme.lineStrong, lineWidth: 1)
                    .frame(width: 9, height: 9)

                Text(task.title)
                    .font(Theme.mono(11))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let due = task.dueDate {
                    Text(DateInput.shortLabel(due))
                        .font(Theme.mono(9))
                        .foregroundStyle(task.isOverdue() ? theme.signal : theme.inkTertiary)
                } else if task.status == .inProgress {
                    Text("ACTIVE").font(Theme.mono(9)).foregroundStyle(theme.inkTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(hovering ? theme.selectionFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Complete “\(task.title)”")
    }
}

private struct MenuAction: View {
    @Environment(\.theme) private var theme
    let label: String
    let shortcut: String
    var accent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if accent { Circle().fill(theme.signal).frame(width: 6, height: 6) }
                Text(label)
                    .font(Theme.mono(10.5, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(shortcut)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(hovering ? theme.selectionFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
