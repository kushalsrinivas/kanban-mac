import SwiftUI

/// Suggested tasks from a meeting.
///
/// The whole point of this view: an extracted action item is a *proposal*. Nothing
/// here writes to the board until the user presses ADD and confirms. ADD ALL skips the
/// per-item dialog, not the decision.
struct SuggestionsSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    let meeting: Meeting

    private var suggested: [ActionItem] { meeting.actionItems.filter(\.isSuggested) }
    private var added: [ActionItem] { meeting.actionItems.filter { $0.state == .added } }
    private var dismissed: [ActionItem] { meeting.actionItems.filter { $0.state == .dismissed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if meeting.actionItems.isEmpty {
                Text("No action items were found in this meeting.")
                    .font(Theme.body)
                    .foregroundStyle(theme.inkTertiary)
            }

            if !suggested.isEmpty {
                HStack {
                    Text("\(String(format: "%02d", suggested.count)) SUGGESTED")
                        .font(Theme.mono(11, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Button("ADD ALL") { app.addAllSuggestions(from: meeting.id) }
                        .buttonStyle(PanelButtonStyle(compact: true))
                }

                VStack(spacing: 7) {
                    ForEach(suggested) { item in
                        SuggestionCard(item: item)
                    }
                }
            }

            if !added.isEmpty {
                Rule()
                MicroLabel("added · \(added.count)")
                VStack(spacing: 4) {
                    ForEach(added) { item in
                        AcceptedRow(item: item)
                    }
                }
            }

            if !dismissed.isEmpty {
                Rule()
                MicroLabel("dismissed · \(dismissed.count)")
                VStack(spacing: 4) {
                    ForEach(dismissed) { item in
                        HStack(spacing: 7) {
                            Text(item.title)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(theme.inkTertiary)
                                .strikethrough(color: theme.line)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Button("RESTORE") { app.restoreSuggestion(item) }
                                .buttonStyle(BareButtonStyle())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Suggestion card

private struct SuggestionCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title.uppercased())
                .font(Theme.mono(11.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.assignee != nil || item.dueDate != nil || item.confidence > 0 {
                HStack(spacing: 6) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        MicroLabel("assigned")
                        Text(assignee.uppercased())
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkSecondary)
                    }
                    if let due = item.dueDate {
                        if item.assignee != nil { Text("·").font(Theme.mono(9)).foregroundStyle(theme.line) }
                        Text(DateInput.shortLabel(due))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    if item.confidence > 0 {
                        // Shown for judgement, never used to auto-accept.
                        Text("\(Int(item.confidence * 100))% CONF")
                            .font(Theme.mono(9.5))
                            .monospacedDigit()
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
            }

            Rule()

            HStack(spacing: 6) {
                Spacer()
                Button("DISMISS") { app.dismissSuggestion(item) }
                    .buttonStyle(PanelButtonStyle(compact: true))
                Button("ADD") { app.beginAdding(item) }
                    .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            }
        }
        .padding(11)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
    }
}

private struct AcceptedRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let item: ActionItem

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(item.title)
                .font(Theme.mono(10.5))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let taskID = item.taskID, let task = app.store.task(taskID) {
                Text(task.status.label)
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkTertiary)
                Button("OPEN") { app.openInspector(for: taskID) }
                    .buttonStyle(BareButtonStyle())
            }
        }
    }
}

// MARK: - Confirmation

/// The lightweight "ADD TASK" step. Editable before anything is written.
struct AddTaskConfirmation: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    @State var draft: AppModel.SuggestionDraft
    @State private var dueText: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel("add task")
            Rule()

            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("title")
                TextField("", text: $draft.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.display(14, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .accessibilityLabel("Task title")
            }

            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("status")
                SegmentPicker(selection: $draft.status,
                              options: TaskStatus.allCases.map { ($0, $0.label) })
            }

            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("priority")
                SegmentPicker(selection: $draft.priority,
                              options: Priority.allCases.map { ($0, $0.label) })
            }

            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("due")
                HStack(spacing: 6) {
                    TextField("", text: $dueText,
                              prompt: Text("no due date")
                                .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
                        .accessibilityLabel("Due date")
                    Button("TODAY") { setDue("today") }.buttonStyle(PanelButtonStyle(compact: true))
                    Button("TMRW") { setDue("tomorrow") }.buttonStyle(PanelButtonStyle(compact: true))
                }
            }

            if let assignee = draft.item.assignee, !assignee.isEmpty {
                HStack {
                    MicroLabel("assignee")
                    Spacer()
                    Text(assignee.uppercased())
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.inkSecondary)
                }
            }

            Rule()

            HStack {
                Button("CANCEL") { app.pendingSuggestion = nil }
                    .buttonStyle(PanelButtonStyle())
                Spacer()
                Button("ADD TASK") {
                    // The parsed date is the source of truth. Only a field the user
                    // actually edited is re-parsed, so TODAY/TMRW labels never go
                    // back through the parser.
                    if dueIsEdited {
                        let typed = dueText.trimmingCharacters(in: .whitespaces)
                        if typed.isEmpty {
                            draft.dueDate = nil
                        } else if let date = DateInput.parse(typed) {
                            draft.dueDate = date
                        } else {
                            app.flash("UNPARSEABLE DATE")
                            return
                        }
                    }
                    app.commitSuggestion(draft)
                }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(theme.panel)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
            .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .onAppear {
            dueText = draft.dueDate.map { DateInput.shortLabel($0) } ?? ""
            titleFocused = true
        }
    }

    private func setDue(_ value: String) {
        draft.dueDate = DateInput.parse(value)
        dueText = draft.dueDate.map { DateInput.shortLabel($0) } ?? ""
    }

    /// True only when the field no longer shows the label of the parsed date, i.e.
    /// the user typed into it after the last programmatic set.
    private var dueIsEdited: Bool {
        dueText != (draft.dueDate.map { DateInput.shortLabel($0) } ?? "")
    }
}
