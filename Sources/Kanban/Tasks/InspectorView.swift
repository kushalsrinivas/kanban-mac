import SwiftUI

struct InspectorView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @FocusState.Binding var focus: FocusTarget?

    var body: some View {
        VStack(spacing: 0) {
            switch app.inspector {
            case .task(let id):
                if let task = app.store.task(id) {
                    TaskInspector(task: task)
                        .id(id)
                } else {
                    placeholder("TASK NOT FOUND")
                }
            case .agent:
                // The agent has its own section now; the inspector is tasks only.
                placeholder("AGENT MOVED TO ITS OWN TAB")
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.paper)
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            MicroLabel(text)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Inline editor. Every control writes straight through to the store — there is no
/// save button and no draft state to lose.
struct TaskInspector: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    let task: TaskItem

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var dueText: String = ""
    @State private var tagText: String = ""
    @State private var newSubtask: String = ""
    @FocusState private var editorFocus: Field?

    private enum Field: Hashable { case title, notes, due, tags, subtask }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    titleField
                    Rule()
                    controls
                    Rule()
                    notesField
                    Rule()
                    subtasksBlock
                    Rule()
                    sourceBlock
                    metadata
                    actions
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
        }
        .onAppear(perform: load)
        .onChange(of: task.id) { _, _ in load() }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            MicroLabel("task")
            Spacer()
            Text(task.status.label)
                .font(Theme.mono(9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(theme.inkSecondary)
            Button { app.closeInspector() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(BareButtonStyle())
            .help("Close (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rule() }
    }

    private var titleField: some View {
        TextField("", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.display(16, weight: .medium))
            .foregroundStyle(theme.ink)
            .lineLimit(1...4)
            .focused($editorFocus, equals: .title)
            .onSubmit(commitTitle)
            .onChange(of: editorFocus) { old, _ in if old == .title { commitTitle() } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("priority")
                SegmentPicker(
                    selection: Binding(
                        get: { task.priority },
                        set: { value in try? app.taskService.edit(task.id) { $0.priority = value } }
                    ),
                    options: Priority.allCases.map { ($0, $0.label) }
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("column")
                SegmentPicker(
                    selection: Binding(
                        get: { task.status },
                        set: { value in try? app.taskService.move(task.id, to: value, index: 0) }
                    ),
                    options: TaskStatus.allCases.map { ($0, $0.label) }
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    MicroLabel("due")
                    Spacer()
                    if task.dueDate != nil {
                        Button("CLEAR") {
                            try? app.taskService.edit(task.id) { $0.dueDate = nil }
                            dueText = ""
                        }
                        .buttonStyle(BareButtonStyle())
                    }
                }
                HStack(spacing: 6) {
                    fieldBox {
                        TextField("", text: $dueText, prompt: Text("today · fri · 18 sep")
                            .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                            .textFieldStyle(.plain)
                            .font(Theme.mono(11.5))
                            .focused($editorFocus, equals: .due)
                            .onSubmit(commitDue)
                            .onChange(of: editorFocus) { old, _ in if old == .due { commitDue() } }
                    }
                    ForEach(["TODAY", "TMRW", "+7D"], id: \.self) { shortcut in
                        Button(shortcut) {
                            let value = shortcut == "TODAY" ? "today" : shortcut == "TMRW" ? "tomorrow" : "+7d"
                            try? app.taskService.edit(task.id) { $0.dueDate = DateInput.parse(value) }
                            dueText = task.dueDate.map { DateInput.shortLabel($0) } ?? ""
                        }
                        .buttonStyle(PanelButtonStyle(compact: true))
                    }
                }
                if task.isOverdue() {
                    Text("OVERDUE")
                        .font(Theme.mono(9.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(theme.signal)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("tags")
                fieldBox {
                    TextField("", text: $tagText, prompt: Text("comma separated")
                        .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .focused($editorFocus, equals: .tags)
                        .onSubmit(commitTags)
                        .onChange(of: editorFocus) { old, _ in if old == .tags { commitTags() } }
                }
            }
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 5) {
            MicroLabel("notes")
            TextEditor(text: $notes)
                .font(Theme.body)
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 160)
                .padding(6)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
                .focused($editorFocus, equals: .notes)
                .onChange(of: editorFocus) { old, _ in if old == .notes { commitNotes() } }
        }
    }

    private var subtasksBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                MicroLabel("subtasks")
                Spacer()
                if !task.subtasks.isEmpty {
                    Text("\(task.doneSubtaskCount)/\(task.subtasks.count)")
                        .font(Theme.mono(9.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkTertiary)
                }
            }

            ForEach(task.subtasks) { subtask in
                HStack(spacing: 7) {
                    Button {
                        try? app.taskService.setSubtask(subtask.id, on: task.id, done: !subtask.isDone)
                    } label: {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(subtask.isDone ? theme.ink : .clear)
                            .frame(width: 10, height: 10)
                            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(subtask.isDone ? theme.ink : theme.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Text(subtask.title)
                        .font(Theme.body)
                        .foregroundStyle(subtask.isDone ? theme.inkTertiary : theme.ink)
                        .strikethrough(subtask.isDone, color: theme.inkTertiary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    Button {
                        try? app.taskService.removeSubtask(subtask.id, from: task.id)
                    } label: {
                        Image(systemName: "minus").font(.system(size: 8, weight: .medium))
                    }
                    .buttonStyle(BareButtonStyle())
                }
            }

            HStack(spacing: 6) {
                Text("+").font(Theme.mono(11)).foregroundStyle(theme.inkTertiary)
                TextField("", text: $newSubtask, prompt: Text("add subtask")
                    .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11.5))
                    .focused($editorFocus, equals: .subtask)
                    .onSubmit {
                        let t = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        try? app.taskService.addSubtask(task.id, title: t)
                        newSubtask = ""
                    }
            }
        }
    }

    /// Meeting → discussion → action item → task. The chain stays walkable.
    @ViewBuilder
    private var sourceBlock: some View {
        if let meetingID = task.meetingID, let meeting = app.store.meeting(meetingID) {
            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("source")
                Button { app.openMeeting(meetingID) } label: {
                    HStack(spacing: 6) {
                        Text(meeting.title.uppercased())
                            .font(Theme.mono(10.5, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text("·").font(Theme.mono(9.5)).foregroundStyle(theme.line)
                        Text(DateInput.shortLabel(meeting.startedAt))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkSecondary)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(theme.inkTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the meeting this came from")
            }
        } else if task.source == .agent {
            HStack {
                MicroLabel("source")
                Spacer()
                Text("AGENT").font(Theme.mono(9.5)).foregroundStyle(theme.inkSecondary)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaRow("CREATED", stamp(task.createdAt))
            metaRow("UPDATED", stamp(task.updatedAt))
            if let completed = task.completedAt { metaRow("COMPLETED", stamp(completed)) }
            if let archived = task.archivedAt { metaRow("ARCHIVED", stamp(archived)) }
            metaRow("ID", String(task.id.uuidString.prefix(8)).lowercased())
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(task.isDone ? "REOPEN" : "COMPLETE") {
                app.selection = task.id
                app.completeSelection()
            }
            .buttonStyle(PanelButtonStyle(prominent: !task.isDone))

            Button(task.isArchived ? "UNARCHIVE" : "ARCHIVE") {
                if task.isArchived { try? app.taskService.unarchive(task.id) }
                else {
                    app.selection = task.id
                    app.archiveSelection()
                }
            }
            .buttonStyle(PanelButtonStyle())

            Spacer()

            Button("DELETE") {
                app.selection = task.id
                app.deleteSelection()
            }
            .buttonStyle(PanelButtonStyle())
        }
        .padding(.top, 2)
    }

    // MARK: Helpers

    private func fieldBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            MicroLabel(label)
            Spacer()
            Text(value)
                .font(Theme.mono(9.5))
                .foregroundStyle(theme.inkSecondary)
        }
    }

    private func stamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd MMM yy HH:mm"
        return df.string(from: date).uppercased()
    }

    private func load() {
        title = task.title
        notes = task.notes
        tagText = task.tags.joined(separator: ", ")
        dueText = task.dueDate.map { DateInput.shortLabel($0) } ?? ""
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else {
            title = task.title
            return
        }
        try? app.taskService.edit(task.id) { $0.title = trimmed }
    }

    private func commitNotes() {
        guard notes != task.notes else { return }
        try? app.taskService.edit(task.id) { $0.notes = notes }
    }

    private func commitTags() {
        let tags = tagText
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #")).lowercased() }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for tag in tags where !unique.contains(tag) { unique.append(tag) }
        guard unique != task.tags else { return }
        try? app.taskService.edit(task.id) { $0.tags = unique }
        tagText = unique.joined(separator: ", ")
    }

    private func commitDue() {
        let raw = dueText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            if task.dueDate != nil { try? app.taskService.edit(task.id) { $0.dueDate = nil } }
            return
        }
        guard let date = DateInput.parse(raw) else {
            dueText = task.dueDate.map { DateInput.shortLabel($0) } ?? ""
            app.flash("UNPARSEABLE DATE")
            return
        }
        try? app.taskService.edit(task.id) { $0.dueDate = date }
        dueText = DateInput.shortLabel(date)
    }
}
