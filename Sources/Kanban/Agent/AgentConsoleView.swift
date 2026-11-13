import SwiftUI

/// The agent as a command console, not a chat app.
///
/// Queries are answered inline. Mutations arrive as structured operations the server
/// has already validated, and sit there until the user presses EXECUTE.
struct AgentConsoleView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @FocusState.Binding var focus: FocusTarget?

    @State private var draft = ""
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                transcript
                if !app.agent.pending.isEmpty {
                    VRule()
                    operations.frame(width: 300)
                }
            }
            .frame(maxHeight: .infinity)
            composer
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .confirmationDialog("Clear the console?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear Without Executing", role: .destructive) { app.agent.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = app.agent.pending.count
            Text("\(count) proposed operation\(count == 1 ? "" : "s") \(count == 1 ? "has" : "have") not been executed. Clearing discards them.")
        }
    }

    // MARK: Header

    private var header: some View {
        Panel(padding: 0) {
            HStack(spacing: 0) {
                block("STATUS", app.agent.statusLabel,
                      tint: app.agent.isAvailable ? nil : theme.inkTertiary, width: 170)
                VRule().padding(.vertical, 12)
                block("OPEN", String(format: "%02d", app.store.counts().open))
                VRule().padding(.vertical, 12)
                block("MEETINGS", String(format: "%02d", app.store.meetings.count))
                VRule().padding(.vertical, 12)
                block("PENDING OPS", String(format: "%02d", app.agent.pending.count),
                      tint: app.agent.pending.isEmpty ? nil : theme.signal)
                Spacer(minLength: 8)
                Button("CLEAR") {
                    if app.agent.pending.isEmpty {
                        app.agent.clear()
                    } else {
                        confirmingClear = true
                    }
                }
                .buttonStyle(BareButtonStyle())
                .padding(.trailing, 14)
            }
            .frame(height: 60)
        }
    }

    private func block(_ label: String, _ value: String, tint: Color? = nil,
                       width: CGFloat = 118) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel(label)
            Text(value)
                .font(Theme.mono(15, weight: .light))
                .monospacedDigit()
                .foregroundStyle(tint ?? theme.ink)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, 14)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if app.agent.messages.isEmpty { emptyState }
                    ForEach(app.agent.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if app.agent.isBusy {
                        HStack(spacing: 6) {
                            StatusDot(.idle)
                            MicroLabel("thinking on the vps")
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: app.agent.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.agent.isAvailable {
                Text("What do you want to do?")
                    .font(Theme.display(15))
                    .foregroundStyle(theme.inkSecondary)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(["What do I need to finish today?",
                             "Move my API task into progress",
                             "What did we decide about onboarding?",
                             "Show me action items from this week's meetings"], id: \.self) { example in
                        Button {
                            draft = example
                            focus = .agent
                        } label: {
                            Text("> \(example)")
                                .font(Theme.mono(11))
                                .foregroundStyle(theme.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Ask about your board and meetings once the VPS is connected.")
                    .font(Theme.display(15))
                    .foregroundStyle(theme.inkSecondary)
            }

            if !app.settings.backendIsConfigured {
                Rule().padding(.vertical, 4)
                Text("The agent runs on your VPS. Set the server URL in Settings. Tasks and recording work without it.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("OPEN SETTINGS") { openSettings() }
                    .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            } else if !app.agent.isAvailable {
                Rule().padding(.vertical, 4)
                Text("The VPS is configured but unreachable, so the agent cannot answer right now.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Pending operations

    private var operations: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MicroLabel("proposed operations")
                Spacer()
                Button("DISMISS ALL") { app.agent.dismissAll() }
                    .buttonStyle(BareButtonStyle())
            }
            Rule()

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(app.agent.pending) { action in
                        OperationCard(action: action)
                    }
                }
            }
            .scrollIndicators(.never)

            if app.agent.bulkExecutableCount > 1 {
                Button("EXECUTE ALL") { Task { await app.agent.executeAll() } }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .frame(maxWidth: .infinity)
            }
            if app.settings.confirmDestructiveAgentActions {
                let destructive = app.agent.pending.filter(\.destructive).count
                if destructive > 0 {
                    MicroLabel("\(destructive) DESTRUCTIVE · CONFIRM SEPARATELY")
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 8) {
                Text(">")
                    .font(Theme.mono(13, weight: .medium))
                    .foregroundStyle(theme.inkTertiary)

                TextField("", text: $draft,
                          prompt: Text(app.settings.backendIsConfigured
                                       ? "ask the agent" : "agent unavailable — set a VPS URL in settings")
                            .font(Theme.mono(12)).foregroundStyle(theme.inkTertiary),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1...4)
                    .focused($focus, equals: .agent)
                    .onSubmit(send)

                Button(action: send) { Text("SEND") }
                    .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                              || app.agent.isBusy || !app.agent.isAvailable)
            }
            .padding(.vertical, 10)
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft = ""
        Task { await app.agent.send(text) }
    }
}

// MARK: - Rows

private struct MessageRow: View {
    @Environment(\.theme) private var theme
    let message: AgentSession.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MicroLabel(label, color: labelColour)
            Text(message.text)
                .font(message.kind == .user ? Theme.display(13) : Theme.mono(11.5))
                .foregroundStyle(textColour)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if message.kind == .user {
                Rectangle().fill(theme.line).frame(width: 1).padding(.leading, -8)
            }
        }
    }

    private var label: String {
        switch message.kind {
        case .user: return "you"
        case .agent: return "agent"
        case .applied: return "executed"
        case .failure: return "failed"
        case .system: return "system"
        }
    }

    private var labelColour: Color {
        switch message.kind {
        case .failure: return theme.signal
        case .applied: return theme.inkSecondary
        default: return theme.inkTertiary
        }
    }

    private var textColour: Color {
        switch message.kind {
        case .failure: return theme.signal
        case .system: return theme.inkSecondary
        default: return theme.ink
        }
    }
}

/// One proposed operation, with its confirmation.
private struct OperationCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let action: AgentAction

    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MicroLabel(action.tool.replacingOccurrences(of: "_", with: " "),
                           color: action.destructive ? theme.signal : theme.inkTertiary)
                Spacer()
                if action.destructive {
                    Text("DESTRUCTIVE")
                        .font(Theme.mono(9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.signal)
                }
            }

            Text(action.summary)
                .font(Theme.mono(11))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rule()

            HStack(spacing: 6) {
                Spacer()
                Button("DISMISS") { app.agent.dismiss(action) }
                    .buttonStyle(PanelButtonStyle(compact: true))
                Button("EXECUTE") {
                    if action.destructive && app.settings.confirmDestructiveAgentActions {
                        confirming = true
                    } else {
                        Task { await app.agent.execute(action) }
                    }
                }
                .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
            }
        }
        .padding(11)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(action.destructive ? theme.signal.opacity(0.5) : theme.line,
                          lineWidth: Theme.Metric.hairline))
        .confirmationDialog("Run this destructive operation?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Execute", role: .destructive) { Task { await app.agent.execute(action) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(action.summary)
        }
    }
}
