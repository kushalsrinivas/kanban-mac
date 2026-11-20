import SwiftUI

/// The agent workspace: a command surface over the real board, meetings and
/// recordings. Answers arrive as typed cards, not a wall of generated text.
struct AgentConsoleView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState.Binding var focus: FocusTarget?

    @State private var draft = ""
    @State private var confirmingClear = false

    private let examples = [
        "What's on my todo?",
        "Show my recent meetings",
        "Find my last recording",
        "Summarize yesterday's meeting"
    ]

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
        .confirmationDialog("Clear the workspace?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear Without Executing", role: .destructive) { app.agent.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = app.agent.pending.count
            Text("\(count) proposed operation\(count == 1 ? "" : "s") \(count == 1 ? "has" : "have") not been executed. Clearing discards them.")
        }
        .onAppear {
            assert(AgentArtifactRegistry.live.unregisteredKinds.isEmpty,
                   "artifact kinds without a renderer: \(AgentArtifactRegistry.live.unregisteredKinds)")
        }
    }

    // MARK: Header

    private var header: some View {
        Panel(padding: 0) {
            HStack(spacing: 0) {
                block("STATUS", app.agent.statusLabel, width: 170)
                VRule().padding(.vertical, 12)
                block("OPEN", String(format: "%02d", app.store.counts().open))
                VRule().padding(.vertical, 12)
                block("MEETINGS", String(format: "%02d", app.store.meetings.count))
                VRule().padding(.vertical, 12)
                block("ARTIFACTS", String(format: "%02d", app.agent.artifactCount),
                      tint: app.agent.artifactCount == 0 ? nil : theme.inkSecondary)
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
                .accessibilityLabel("Clear the agent workspace")
            }
            .frame(height: 60)
        }
    }

    private func block(_ label: String, _ value: String, tint: Color? = nil,
                       width: CGFloat = 108) -> some View {
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    if app.agent.messages.isEmpty { emptyState }
                    ForEach(app.agent.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 4)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: app.agent.messages.count) { _, _ in
                scroll(proxy, animated: !reduceMotion)
            }
            .onChange(of: app.agent.artifactCount) { _, _ in
                scroll(proxy, animated: !reduceMotion)
            }
            .onChange(of: app.agent.stage) { _, _ in
                scroll(proxy, animated: false)
            }
            .onChange(of: app.agent.messages.last?.text) { _, _ in
                guard app.agent.isBusy else { return }
                scroll(proxy, animated: false)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask your workspace.")
                    .font(Theme.display(18))
                    .foregroundStyle(theme.ink)
                Text("Answers come from your real board and meetings. Safe changes apply immediately; delete and archive ask first.")
                    .font(Theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(examples, id: \.self) { example in
                    Button { app.agent.send(example) } label: {
                        HStack(spacing: 7) {
                            Text(">")
                                .font(Theme.mono(11, weight: .medium))
                                .foregroundStyle(theme.inkTertiary)
                            Text(example)
                                .font(Theme.mono(11.5))
                                .foregroundStyle(theme.inkSecondary)
                            Spacer(minLength: 0)
                            Text("ASK")
                                .font(Theme.mono(8.5, weight: .medium))
                                .tracking(0.6)
                                .foregroundStyle(theme.inkTertiary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask: \(example)")
                }
            }

            Rule()
            HStack(spacing: 8) {
                StatusDot(app.settings.hasGeminiKey ? .on : .idle)
                Text(app.agent.freeFormAvailable
                     ? "TOOLS RUN LOCALLY · OPEN-ENDED QUESTIONS USE A MODEL"
                     : "TOOLS RUN LOCALLY · ADD A MODEL FOR OPEN-ENDED QUESTIONS")
                    .font(Theme.mono(9))
                    .tracking(0.5)
                    .foregroundStyle(theme.inkTertiary)
                if !app.agent.freeFormAvailable {
                    Button("SETTINGS") { openSettings() }
                        .buttonStyle(BareButtonStyle())
                        .accessibilityLabel("Open settings to configure a model")
                }
            }
        }
        .padding(.top, 8)
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
                    .disabled(app.agent.isBusy)
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
                          prompt: Text("ask about tasks, meetings, recordings, transcripts…")
                            .font(Theme.mono(12)).foregroundStyle(theme.inkTertiary),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1...4)
                    .focused($focus, equals: .agent)
                    .onSubmit(send)
                    .disabled(app.agent.isBusy)
                    .accessibilityLabel("Ask the agent")

                if app.agent.isBusy {
                    Button("CANCEL") { app.agent.cancel() }
                        .buttonStyle(PanelButtonStyle(compact: true))
                        .accessibilityLabel("Cancel the current request")
                } else {
                    Button(action: send) { Text("SEND") }
                        .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Send")
                }
            }
            .padding(.vertical, 10)

            HStack(spacing: 10) {
                MicroLabel("⏎ SEND")
                MicroLabel("READS ARE INSTANT")
                Spacer(minLength: 0)
                if let error = app.agent.lastError, !app.agent.isBusy {
                    Text(AgentText.brief(error, 80).uppercased())
                        .font(Theme.mono(8.5, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(theme.signal)
                        .lineLimit(1)
                        .help(error)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !app.agent.isBusy else { return }
        draft = ""
        app.agent.send(text)
    }
}

// MARK: - Rows

private struct MessageRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let message: AgentSession.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                MicroLabel(label, color: labelColour)
                Spacer(minLength: 0)
                Text(message.at, style: .time)
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkTertiary.opacity(0.8))
            }

            if message.isStreaming {
                streaming
                if message.text.isEmpty {
                    AgentSkeleton()
                } else {
                    Text(message.text)
                        .font(Theme.display(12.5))
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                }
            } else if !message.text.isEmpty {
                Text(message.text)
                    .font(message.kind == .user ? Theme.display(13) : Theme.display(12.5))
                    .foregroundStyle(textColour)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .lineSpacing(2)
            }

            if !message.artifacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(message.artifacts) { artifact in
                        AgentArtifactView(artifact: artifact)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.top, 1)
            }

            if message.kind == .failure, let prompt = message.failedPrompt, app.agent.canRetry {
                Button {
                    app.agent.retry()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                        Text("RETRY")
                    }
                }
                .buttonStyle(PanelButtonStyle(compact: true))
                .accessibilityLabel("Retry: \(prompt)")
            }

            if !message.suggestions.isEmpty, !message.isStreaming {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(message.suggestions, id: \.self) { suggestion in
                            Button { app.agent.send(suggestion) } label: {
                                Text(suggestion)
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(theme.inkSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(theme.panelAlt, in: Capsule())
                                    .overlay(Capsule().strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Follow-up: \(suggestion)")
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if message.kind == .user {
                Rectangle().fill(theme.line).frame(width: 1).padding(.leading, -8)
            }
        }
    }

    private var streaming: some View {
        HStack(spacing: 7) {
            StatusDot(.idle)
            MicroLabel(message.stage?.label ?? "WORKING")
            Spacer(minLength: 0)
            Button("CANCEL") { app.agent.cancel() }
                .buttonStyle(BareButtonStyle())
                .accessibilityLabel("Cancel the current request")
        }
    }

    private var label: String {
        if message.wasCancelled { return "stopped" }
        switch message.kind {
        case .user: return "you"
        case .agent: return "agent"
        case .applied: return "executed"
        case .failure: return "failed"
        case .system: return "system"
        }
    }

    private var labelColour: Color {
        if message.wasCancelled { return theme.inkTertiary }
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
                .font(Theme.mono(10.5))
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
                .disabled(app.agent.isBusy)
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

// MARK: - Skeleton

/// A quiet placeholder while a turn is genuinely working. It never stands in for
/// data that already exists.
private struct AgentSkeleton: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar(width: nil, height: 8)
            bar(width: nil, height: 7)
            bar(width: 210, height: 7)
        }
        .padding(10)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
        .opacity(pulse ? 0.5 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                   value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(theme.panelAlt)
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
    }
}
