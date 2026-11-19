import AppKit
import SwiftUI

// MARK: - Commitments

/// Meeting-to-execution: every promise with its owner, date, verbatim quote and the
/// second it was said. The board task is one press away; completion stays in sync.
struct CommitmentsPane: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .open

    enum Filter: String, CaseIterable {
        case open = "OPEN"
        case overdue = "OVERDUE"
        case done = "DONE"
        case all = "ALL"
    }

    fileprivate struct Row: Identifiable {
        var item: ActionItem
        var meeting: Meeting
        var id: UUID { item.id }
    }

    private var rows: [Row] {
        var out: [Row] = []
        for meeting in app.store.meetings {
            for item in meeting.actionItems {
                let include: Bool
                switch filter {
                case .open: include = item.isOpen && item.state != .dismissed
                case .overdue: include = item.state != .dismissed && item.isOverdue()
                case .done: include = item.commitmentState == .done
                case .all: include = true
                }
                if include { out.append(Row(item: item, meeting: meeting)) }
            }
        }
        return out.sorted { a, b in
            switch (a.item.dueDate, b.item.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.meeting.startedAt > b.meeting.startedAt
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { item in
                    let active = filter == item
                    Button { filter = item } label: {
                        Text("\(item.rawValue) \(count(item))")
                            .font(Theme.mono(9.5, weight: active ? .semibold : .regular))
                            .tracking(0.5)
                            .foregroundStyle(active ? theme.paper : theme.inkSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(active ? theme.ink : theme.panelAlt)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Text("\(rows.count) COMMITMENT\(rows.count == 1 ? "" : "S")")
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkTertiary)
            }

            if rows.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No commitments here yet.")
                            .font(Theme.body)
                            .foregroundStyle(theme.inkSecondary)
                        Text("Process a meeting with a Gemini key. Every promise becomes a row with its quote and timestamp.")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in
                            CommitmentRow(row: row)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func count(_ filter: Filter) -> Int {
        app.store.meetings.reduce(0) { total, meeting in
            total + meeting.actionItems.filter { item in
                switch filter {
                case .open: return item.isOpen && item.state != .dismissed
                case .overdue: return item.state != .dismissed && item.isOverdue()
                case .done: return item.commitmentState == .done
                case .all: return true
                }
            }.count
        }
    }
}

private struct CommitmentRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let row: CommitmentsPane.Row

    private var overdue: Bool { row.item.isOverdue() }

    var body: some View {
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { app.openMeeting(row.meeting.id, focus: .actionItems) } label: {
                        Text(row.item.title)
                            .font(Theme.cardTitle)
                            .foregroundStyle(theme.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Text(row.item.commitmentState.rawValue.uppercased())
                        .font(Theme.mono(8.5, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(row.item.commitmentState == .done ? theme.inkTertiary : (overdue ? theme.signal : theme.inkSecondary))
                }

                if let quote = row.item.quote {
                    Text("\"\(quote)\"")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    if let owner = row.item.assignee, !owner.isEmpty {
                        MicroLabel("owner")
                        Text(owner.uppercased())
                            .font(Theme.mono(9))
                            .foregroundStyle(theme.inkSecondary)
                    }
                    if let due = row.item.dueDate {
                        Text("·").font(Theme.mono(9)).foregroundStyle(theme.line)
                        Text(DateInput.shortLabel(due))
                            .font(Theme.mono(9))
                            .foregroundStyle(overdue ? theme.signal : theme.inkSecondary)
                    }
                    if let start = row.item.sourceStart {
                        Text("·").font(Theme.mono(9)).foregroundStyle(theme.line)
                        Button(Meeting.timecode(start)) {
                            app.openMeeting(row.meeting.id, focus: .transcript)
                        }
                        .buttonStyle(BareButtonStyle())
                        .help("Open the transcript at this moment")
                    }
                    Spacer(minLength: 0)
                    Text(row.meeting.title.uppercased())
                        .font(Theme.mono(8.5))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if row.item.taskID == nil {
                        Button("ADD TASK") { app.beginAdding(row.item) }
                            .buttonStyle(BareButtonStyle())
                    } else {
                        Button("OPEN TASK") { app.openInspector(for: row.item.taskID!) }
                            .buttonStyle(BareButtonStyle())
                    }
                    Button("REMIND") { app.remindCommitment(row.item, meeting: row.meeting) }
                        .buttonStyle(BareButtonStyle())
                    Button(row.item.commitmentState == .done ? "REOPEN" : "DONE") {
                        app.setCommitment(row.item, in: row.meeting,
                                          to: row.item.commitmentState == .done ? .open : .done)
                    }
                    .buttonStyle(BareButtonStyle())
                }
            }
        }
    }
}

// MARK: - Memory

/// Searchable organizational memory: decisions, commitments, questions, discussions
/// and the transcript itself. The answer is extractive, so it works offline and every
/// sentence points at a real meeting.
struct MemoryPane: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var answer: LocalMemoryAnswer?
    @State private var results: [LocalMemoryHit] = []
    @State private var contradictions: [LocalContradiction] = []
    @State private var since90Days = false
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchBar
            if let answer { answerView(answer) }
            if !results.isEmpty {
                Text("\(results.count) MATCH\(results.count == 1 ? "" : "ES")")
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkTertiary)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(results) { hit in hitRow(hit) }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 300)
            }
            contradictionsSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(theme.inkTertiary)
            TextField("", text: $query,
                      prompt: Text("ask a question or search every meeting")
                        .font(Theme.mono(11))
                        .foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(theme.ink)
                .onSubmit { ask() }
            Toggle("90 DAYS", isOn: $since90Days)
                .toggleStyle(.checkbox)
                .font(Theme.mono(9))
                .foregroundStyle(theme.inkTertiary)
            Button(searching ? "…" : "ASK") { ask() }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            Button("SEARCH") { search() }
                .buttonStyle(PanelButtonStyle(compact: true))
            if answer != nil || !results.isEmpty {
                Button("CLEAR") { answer = nil; results = [] }
                    .buttonStyle(BareButtonStyle())
            }
            Button("CONTRADICTIONS") { contradictions = app.contradictions() }
                .buttonStyle(BareButtonStyle())
                .help("Find later decisions that reverse earlier ones")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
    }

    private func search() {
        results = app.memorySearch(query, since: since90Days ? Date().addingTimeInterval(-90 * 86_400) : nil)
        answer = nil
    }

    private func ask() {
        searching = true
        results = []
        answer = app.askMemory(query, since: since90Days ? Date().addingTimeInterval(-90 * 86_400) : nil)
        searching = false
        if let answer { results = answer.citations }
    }

    private func answerView(_ answer: LocalMemoryAnswer) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    MicroLabel(answer.confident ? "answer" : "no match",
                               color: answer.confident ? theme.inkTertiary : theme.signal)
                    Spacer()
                    Text("LOCAL · EXTRACTIVE")
                        .font(Theme.mono(8.5))
                        .foregroundStyle(theme.inkTertiary)
                }
                Text(answer.answer)
                    .font(Theme.body)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !answer.citations.isEmpty {
                    HStack(spacing: 5) {
                        MicroLabel("sources")
                        ForEach(Array(answer.citations.prefix(5).enumerated()), id: \.offset) { index, hit in
                            Button("[\(index + 1)] \(hit.meetingTitle)") {
                                app.openMeeting(hit.meetingID, focus: .summary)
                            }
                            .buttonStyle(BareButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func hitRow(_ hit: LocalMemoryHit) -> some View {
        Button {
            app.openMeeting(hit.meetingID,
                            focus: hit.kind == .transcript ? .transcript : .summary)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(hit.kind.label)
                    .font(Theme.mono(8.5, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(theme.inkTertiary)
                    .frame(width: 74, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.snippet)
                        .font(Theme.body)
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(hit.meetingTitle.uppercased())
                        Text("·")
                        Text(DateInput.shortLabel(hit.meetingDate))
                        if let start = hit.entry.start {
                            Text("·")
                            Text(Meeting.timecode(start)).monospacedDigit()
                        }
                    }
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var contradictionsSection: some View {
        if !contradictions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MicroLabel("possible contradictions", color: theme.signal)
                ForEach(contradictions.prefix(6)) { pair in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pair.reason)
                            .font(Theme.mono(9))
                            .foregroundStyle(theme.signal)
                        Button { app.openMeeting(pair.earlier.meetingID) } label: {
                            Text("\(DateInput.shortLabel(pair.earlier.meetingDate)) · \(pair.earlier.text)")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(theme.inkSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        Button { app.openMeeting(pair.later.meetingID) } label: {
                            Text("\(DateInput.shortLabel(pair.later.meetingDate)) · \(pair.later.text)")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(theme.ink)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                    }
                    Rule()
                }
            }
            .padding(10)
            .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
    }
}

// MARK: - Automation

struct AutomationPane: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @State private var editing: AutomationRule?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            rulesPanel
                .frame(width: 420)
            VRule()
            sidePanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { rule in
            AutomationEditor(rule: rule)
                .environment(\.theme, theme)
        }
    }

    private var rulesPanel: some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    MicroLabel("rules")
                    Spacer()
                    Button("ADD STANDARD") {
                        app.addStandardAutomation()
                    }
                    .buttonStyle(BareButtonStyle())
                    Button("+ NEW") {
                        editing = AutomationRule(name: "New rule", actions: [.summaryEmail()])
                    }
                    .buttonStyle(BareButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Rule()

                if app.store.automationRules.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No automations yet.")
                            .font(Theme.body)
                            .foregroundStyle(theme.inkSecondary)
                        Text("ADD STANDARD runs summary, follow-up, tasks and owner notifications after every meeting. Every part is editable.")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(app.store.automationRules) { rule in
                                ruleRow(rule)
                                Rule()
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { value in
                    var next = rule
                    next.enabled = value
                    app.saveAutomationRule(next)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(theme.ink)
                Text(rule.trigger.label)
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkTertiary)
                Text(rule.actions.map(\.label).joined(separator: " · "))
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !rule.conditions.isEmpty {
                    Text(conditionsSummary(rule.conditions))
                        .font(Theme.mono(8.5))
                        .foregroundStyle(theme.inkTertiary)
                }
                if let last = rule.lastRunAt {
                    Text("last run \(DateInput.shortLabel(last)) \(CalendarFormat.time(last))")
                        .font(Theme.mono(8.5))
                        .foregroundStyle(theme.inkTertiary)
                }
            }
            Spacer(minLength: 0)
            Button("EDIT") { editing = rule }
                .buttonStyle(BareButtonStyle())
            Button("DELETE") { app.deleteAutomationRule(rule.id) }
                .buttonStyle(BareButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func conditionsSummary(_ c: AutomationConditions) -> String {
        var parts: [String] = []
        if !c.titleContains.isEmpty { parts.append("title contains ‘\(c.titleContains)’") }
        if !c.participantContains.isEmpty { parts.append("with ‘\(c.participantContains)’") }
        if c.minDurationMinutes > 0 { parts.append("at least \(c.minDurationMinutes)m") }
        if c.hasActionItems { parts.append("has action items") }
        if c.hasDecisions { parts.append("has decisions") }
        return parts.joined(separator: " · ")
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            draftsPanel
            runsPanel
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var draftsPanel: some View {
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    MicroLabel("drafts & notifications")
                    Spacer()
                    MicroLabel("\(app.store.localMessages.count)")
                }
                Rule()
                if app.store.localMessages.isEmpty {
                    Text("Automations compose email drafts and in-app notes here. Nothing is sent without a mail client.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(app.store.localMessages.prefix(20)) { message in
                                messageRow(message)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 230)
                }
            }
        }
    }

    private func messageRow(_ message: LocalMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(message.kind == .email ? "EMAIL" : "NOTICE")
                    .font(Theme.mono(8.5, weight: .medium))
                    .foregroundStyle(theme.inkTertiary)
                Text(message.subject)
                    .font(Theme.mono(10))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if message.kind == .email {
                    Button("OPEN IN MAIL") { openInMail(message) }
                        .buttonStyle(BareButtonStyle())
                } else {
                    Button("COPY") { copy(message.body) }
                        .buttonStyle(BareButtonStyle())
                }
            }
            if !message.recipients.isEmpty {
                Text(message.recipients.joined(separator: ", ").uppercased())
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkTertiary)
                    .lineLimit(1)
            }
            Text(message.body)
                .font(Theme.mono(9))
                .foregroundStyle(theme.inkTertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    private var runsPanel: some View {
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                MicroLabel("recent runs")
                Rule()
                if app.store.automationRuns.isEmpty {
                    Text("A run appears here after a meeting matches a rule.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                } else {
                    ForEach(app.store.automationRuns.prefix(8)) { run in
                        HStack(alignment: .top, spacing: 7) {
                            StatusDot(run.status == .completed ? .on
                                      : run.status == .failed ? .alert : .idle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(run.ruleName)
                                    .font(Theme.mono(9.5, weight: .medium))
                                    .foregroundStyle(theme.ink)
                                Text(run.detail)
                                    .font(Theme.mono(8.5))
                                    .foregroundStyle(theme.inkTertiary)
                                    .lineLimit(2)
                                Text("\(DateInput.shortLabel(run.startedAt)) \(CalendarFormat.time(run.startedAt))")
                                    .font(Theme.mono(8.5))
                                    .foregroundStyle(theme.inkTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func openInMail(_ message: LocalMessage) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = message.recipients.first ?? ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: message.subject),
            URLQueryItem(name: "body", value: message.body)
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Editor

private struct AutomationEditor: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let rule: AutomationRule
    @State private var draft: AutomationRule
    @State private var recipients = ""
    @State private var webhookURL = ""
    @State private var externalURL = ""

    init(rule: AutomationRule) {
        self.rule = rule
        _draft = State(initialValue: rule)
        _recipients = State(initialValue: rule.actions.first(where: {
            $0.type == "email.followup" || $0.type == "email.summary"
        })?.recipients?.joined(separator: ", ") ?? "")
        _webhookURL = State(initialValue: rule.actions.first(where: { $0.type == "webhook.post" })?.url ?? "")
        _externalURL = State(initialValue: rule.actions.first(where: { $0.type == "tasks.external" })?.url ?? "")
    }

    private var exists: Bool { app.store.automationRule(rule.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(exists ? "EDIT AUTOMATION" : "NEW AUTOMATION")
                    .font(Theme.display(16, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Button("CANCEL") { dismiss() }
                    .buttonStyle(BareButtonStyle())
                Button("SAVE") { save() }
                    .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            }
            Rule()

            VStack(alignment: .leading, spacing: 8) {
                MicroLabel("name")
                field("Rule name", text: $draft.name)

                MicroLabel("when")
                Picker("", selection: $draft.trigger) {
                    ForEach(AutomationTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                MicroLabel("only for meetings whose")
                field("title contains…", text: $draft.conditions.titleContains)
                field("a participant contains…", text: $draft.conditions.participantContains)
                HStack(spacing: 6) {
                    Text("MINUTES")
                        .font(Theme.mono(9))
                        .foregroundStyle(theme.inkTertiary)
                    TextField("0", value: $draft.conditions.minDurationMinutes, format: .number)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11))
                        .frame(width: 50)
                    Toggle("has action items", isOn: $draft.conditions.hasActionItems)
                        .toggleStyle(.checkbox)
                        .font(Theme.mono(9.5))
                    Toggle("has decisions", isOn: $draft.conditions.hasDecisions)
                        .toggleStyle(.checkbox)
                        .font(Theme.mono(9.5))
                }

                MicroLabel("do")
                Toggle("Draft a summary email", isOn: actionBinding("email.summary"))
                    .toggleStyle(.checkbox)
                Toggle("Draft a follow-up email", isOn: actionBinding("email.followup"))
                    .toggleStyle(.checkbox)
                Toggle("Create board tasks from action items", isOn: actionBinding("tasks.create"))
                    .toggleStyle(.checkbox)
                Toggle("Push tasks to an external board webhook", isOn: actionBinding("tasks.external"))
                    .toggleStyle(.checkbox)
                Toggle("Notify commitment owners", isOn: actionBinding("notify.commitments"))
                    .toggleStyle(.checkbox)
                if draft.trigger == .commitmentOverdue {
                    Toggle("Remind owners once a day", isOn: actionBinding("commitments.remind"))
                        .toggleStyle(.checkbox)
                }
                Toggle("Post to a webhook", isOn: actionBinding("webhook.post"))
                    .toggleStyle(.checkbox)
                if hasAction("email.summary") || hasAction("email.followup") {
                    field("send to (comma separated)", text: $recipients)
                }
                if hasAction("webhook.post") {
                    field("webhook URL https://…", text: $webhookURL)
                }
                if hasAction("tasks.external") {
                    field("external board webhook https://…", text: $externalURL)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 480, height: 560)
        .background(theme.paper)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt)
            .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
    }

    private func hasAction(_ type: String) -> Bool {
        draft.actions.contains { $0.type == type }
    }

    private func actionBinding(_ type: String) -> Binding<Bool> {
        Binding(
            get: { hasAction(type) },
            set: { enabled in
                if enabled {
                    if !hasAction(type) { draft.actions.append(defaultAction(type)) }
                } else {
                    draft.actions.removeAll { $0.type == type }
                }
            })
    }

    private func defaultAction(_ type: String) -> AutomationAction {
        switch type {
        case "email.summary": return .summaryEmail()
        case "email.followup": return .followUpEmail()
        case "tasks.create": return .createTasks(minConfidence: 0.6)
        case "tasks.external": return .externalTasks(url: "")
        case "notify.commitments": return .notifyCommitments()
        case "commitments.remind": return .remindOwners()
        case "webhook.post": return .webhook("")
        default: return AutomationAction(type: type)
        }
    }

    private func save() {
        var next = draft
        guard !next.actions.isEmpty else {
            app.flash("ADD AT LEAST ONE ACTION")
            return
        }
        next.name = next.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Untitled rule" : next.name
        let list = recipients.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for index in next.actions.indices {
            if next.actions[index].type == "email.summary"
                || next.actions[index].type == "email.followup" {
                next.actions[index].recipients = list
            }
            if next.actions[index].type == "webhook.post" {
                next.actions[index].url = webhookURL
            }
            if next.actions[index].type == "tasks.external" {
                next.actions[index].url = externalURL
            }
        }
        app.saveAutomationRule(next)
        app.flash("AUTOMATION SAVED")
        dismiss()
    }
}
