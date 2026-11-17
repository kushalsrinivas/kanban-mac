import SwiftUI

/// Meeting results with progressive disclosure: summary open, everything else behind
/// a header you can expand. The transcript never dominates the page.
struct MeetingDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    let meeting: Meeting

    @State private var expanded: Set<Section> = [.summary, .actionItems]
    @State private var transcript: [TranscriptSegment] = []
    @State private var transcriptQuery = ""
    @State private var confirmingDelete = false

    private enum Section: String, CaseIterable {
        case summary = "SUMMARY"
        case actionItems = "ACTION ITEMS"
        case decisions = "DECISIONS"
        case questions = "OPEN QUESTIONS"
        case transcript = "TRANSCRIPT"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let progress = app.processor.progress(for: meeting.id) {
                    ProcessingPanel(progress: progress, meeting: meeting)
                } else if meeting.status == .failed {
                    failurePanel
                } else if [.queued, .uploading, .transcribing, .analyzing].contains(meeting.status) {
                    interruptedPanel
                } else if meeting.status == .readyToProcess || meeting.status == .localOnly {
                    unprocessedPanel
                }

                if meeting.hasResults {
                    section(.summary) { summaryBody }
                    section(.actionItems, badge: badge) { SuggestionsSection(meeting: meeting) }
                    if !meeting.decisions.isEmpty {
                        section(.decisions, badge: String(format: "%02d", meeting.decisions.count)) {
                            bulletList(meeting.decisions)
                        }
                    }
                    if !meeting.questions.isEmpty {
                        section(.questions, badge: String(format: "%02d", meeting.questions.count)) {
                            bulletList(meeting.questions)
                        }
                    }
                }

                if meeting.status == .completed, meeting.summary.isEmpty {
                    Text("Transcribed on this Mac. Add a Gemini key in Settings → Local AI for a summary and action items.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // A transcript-only meeting has no summary, and the list loads
                // meetings without segments — so the gate has to see the
                // transcript this view loaded, not just `meeting.hasResults`.
                if meeting.hasResults || !transcript.isEmpty {
                    section(.transcript, badge: meeting.durationLabel) { transcriptBody }
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
        .deleteMeetingConfirmation(meeting, isPresented: $confirmingDelete)
        .onAppear(perform: loadTranscript)
        .onChange(of: meeting.id) { _, _ in loadTranscript() }
        .onChange(of: meeting.status) { _, new in if new == .completed { loadTranscript() } }
    }

    private var badge: String {
        let suggested = meeting.suggestedCount
        let added = meeting.addedCount
        if suggested == 0 && added == 0 { return "" }
        return added > 0 ? "\(suggested) SUGGESTED · \(added) ADDED" : "\(suggested) SUGGESTED"
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title.uppercased())
                    .font(Theme.display(19, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(theme.ink)
                Spacer()
                Menu {
                    MeetingActions(meeting: meeting, confirmingDelete: $confirmingDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Meeting actions")
            }

            HStack(spacing: 6) {
                Text(DateInput.shortLabel(meeting.startedAt))
                Text("·")
                Text(meeting.durationLabel)
                if meeting.status != .completed {
                    Text("·")
                    Text(meeting.status.label)
                        .foregroundStyle(meeting.status == .failed ? theme.signal : theme.inkSecondary)
                }
            }
            .font(Theme.mono(10.5))
            .tracking(0.6)
            .foregroundStyle(theme.inkTertiary)

            Rule()
        }
        .padding(.top, 2)
    }

    // MARK: Section chrome

    @ViewBuilder
    private func section<Content: View>(_ kind: Section, badge: String = "",
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(kind) { expanded.remove(kind) } else { expanded.insert(kind) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.contains(kind) ? "minus" : "plus")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(theme.inkTertiary)
                        .frame(width: 10)
                    MicroLabel(kind.rawValue, color: theme.inkSecondary)
                    Spacer()
                    if !badge.isEmpty {
                        Text(badge)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rule()

            if expanded.contains(kind) {
                content()
                    .padding(.top, 9)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: Bodies

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if meeting.summary.isEmpty {
                Text("No summary yet.")
                    .font(Theme.body)
                    .foregroundStyle(theme.inkTertiary)
            } else {
                Text(meeting.summary)
                    .font(Theme.display(13))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: 640, alignment: .leading)
            }

            if !meeting.keyPoints.isEmpty {
                MicroLabel("key points")
                bulletList(meeting.keyPoints)
            }

            if !meeting.participants.isEmpty || !meeting.topics.isEmpty {
                Rule()
                HStack(alignment: .top, spacing: 18) {
                    if !meeting.participants.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            MicroLabel("people")
                            Text(meeting.participants.joined(separator: ", ").uppercased())
                                .font(Theme.mono(10))
                                .foregroundStyle(theme.inkSecondary)
                        }
                    }
                    if !meeting.topics.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            MicroLabel("topics")
                            Text(meeting.topics.joined(separator: ", ").uppercased())
                                .font(Theme.mono(10))
                                .foregroundStyle(theme.inkSecondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 7) {
                    Text("•")
                        .font(Theme.mono(11))
                        .foregroundStyle(theme.inkTertiary)
                    Text(item)
                        .font(Theme.body)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if transcript.isEmpty {
                Text("No transcript.")
                    .font(Theme.body)
                    .foregroundStyle(theme.inkTertiary)
            } else {
                HStack(spacing: 8) {
                    MicroLabel("find")
                    TextField("", text: $transcriptQuery,
                              prompt: Text("search transcript")
                                .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(theme.ink)
                        .accessibilityLabel("Search transcript")
                    Text("\(filteredTranscript.count) / \(transcript.count)")
                        .font(Theme.mono(9.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))

                if filteredTranscript.isEmpty {
                    Text("No segments match “\(transcriptQuery)”.")
                        .font(Theme.body)
                        .foregroundStyle(theme.inkTertiary)
                        .padding(.top, 2)
                } else {
                // Capped so an hour-long meeting cannot make this view expensive.
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(filteredTranscript.prefix(400)) { segment in
                        TranscriptRow(segment: segment)
                    }
                }
                if filteredTranscript.count > 400 {
                    MicroLabel("+ \(filteredTranscript.count - 400) more segments")
                }
                }
            }
        }
    }

    private var filteredTranscript: [TranscriptSegment] {
        let q = transcriptQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return transcript }
        return transcript.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: Status panels

    private var unprocessedPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                MicroLabel(meeting.status == .localOnly ? "saved locally" : "ready to process")
                if let reason = meeting.failureReason, !reason.isEmpty {
                    Text(reason)
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(meeting.status == .localOnly
                     ? "This recording is kept on this Mac and will not be uploaded."
                     : "This recording is saved on this Mac and has not been transcribed yet.")
                    .font(Theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if app.settings.canProcessMeetings {
                    if meeting.status == .localOnly {
                        // Respect the earlier decision, but leave an explicit way back.
                        Button("UPLOAD ANYWAY") { app.processRecording(meeting.id) }
                            .buttonStyle(PanelButtonStyle())
                    } else {
                        HStack(spacing: 6) {
                            Button(app.sync.connection.isOnline ? "PROCESS" : "PROCESS WHEN ONLINE") {
                                app.processRecording(meeting.id)
                            }
                            .buttonStyle(PanelButtonStyle(prominent: true))
                            if !app.sync.connection.isOnline {
                                MicroLabel("vps offline")
                            }
                        }
                    }
                } else {
                    Text("Add a Gemini API key and download a speech model in Settings → Local AI to process this recording on this Mac.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                }
            }
        }
    }

    /// A job that was in flight when the app closed: the local processor no longer has
    /// its progress, but the recording is still here and can be sent again.
    private var interruptedPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                MicroLabel("processing interrupted")
                Text("This meeting was being processed when the app last closed. You can send it again.")
                    .font(Theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if meeting.audioFilename != nil, app.settings.canProcessMeetings {
                    Button("RESUME PROCESSING") { app.processRecording(meeting.id) }
                        .buttonStyle(PanelButtonStyle(prominent: true))
                } else if meeting.audioFilename == nil {
                    Text("The recording is no longer on this Mac, so it cannot be resumed.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                }
            }
        }
    }

    private var failurePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                MicroLabel("failed", color: theme.signal)
                Text(meeting.failureReason ?? "Processing failed.")
                    .font(Theme.body)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if meeting.audioFilename != nil {
                    Button("RETRY") { app.processRecording(meeting.id) }
                        .buttonStyle(PanelButtonStyle())
                } else {
                    Text("The recording was already removed, so this cannot be retried.")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                }
            }
        }
    }

    private func loadTranscript() {
        transcript = meeting.transcript.isEmpty
            ? app.store.transcript(for: meeting.id)
            : meeting.transcript
        // A meeting without a summary is being read for its transcript; open it
        // rather than making the only content a folded row.
        if meeting.summary.isEmpty, !transcript.isEmpty {
            expanded.insert(.transcript)
        }
    }
}

// MARK: - Transcript row

private struct TranscriptRow: View {
    @Environment(\.theme) private var theme
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(segment.timecode)
                .font(Theme.mono(9.5))
                .monospacedDigit()
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                if let speaker = segment.speaker, !speaker.isEmpty {
                    Text(speaker.uppercased())
                        .font(Theme.mono(9.5, weight: .medium))
                        .tracking(0.7)
                        .foregroundStyle(theme.inkSecondary)
                }
                Text(segment.text)
                    .font(Theme.body)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Processing

/// The pipeline checklist. Steps are ticked as the server reports them; the running
/// stage is the only one in full ink and the rest stay dim until reached.
struct ProcessingPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let progress: MeetingProcessor.Progress
    let meeting: Meeting

    private struct Stage: Identifiable {
        let status: MeetingStatus
        let label: String
        var id: MeetingStatus { status }
    }

    private var stages: [Stage] {
        [Stage(status: .queued, label: "QUEUE"),
         Stage(status: .uploading, label: "UPLOAD"),
         Stage(status: .transcribing, label: "TRANSCRIPTION"),
         Stage(status: .analyzing, label: "ANALYSIS"),
         Stage(status: .completed, label: "ACTION ITEMS")]
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    MicroLabel("processing")
                    Spacer()
                    Text(progress.status.label)
                        .font(Theme.mono(10, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(theme.ink)
                    if progress.status.isProcessing {
                        Button("CANCEL") { app.processor.cancel(meeting.id) }
                            .buttonStyle(PanelButtonStyle(compact: true))
                    }
                }

                Rule()

                ForEach(stages) { stage in
                    step(stage.label, stage.status,
                         trailing: progress.uploadFraction > 0 && progress.uploadFraction < 1
                            && stage.status == progress.status
                            ? "\(Int(progress.uploadFraction * 100))%" : nil)
                }

                if let detail = progress.detail {
                    Text(detail)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// ✓ done · ● running · ○ pending
    private func step(_ label: String, _ stage: MeetingStatus, trailing: String? = nil) -> some View {
        let state = state(for: stage)
        return HStack(spacing: 8) {
            Text(state.glyph)
                .font(Theme.mono(11))
                .foregroundStyle(state == .done ? theme.inkSecondary
                                 : state == .running ? theme.ink : theme.inkTertiary)
                .frame(width: 10)
            Text(label)
                .font(Theme.mono(10.5, weight: state == .running ? .medium : .regular))
                .tracking(0.6)
                .foregroundStyle(state == .pending ? theme.inkTertiary : theme.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.mono(9.5))
                    .monospacedDigit()
                    .foregroundStyle(theme.inkSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(state.label)")
    }

    private enum StepState {
        case done, running, pending
        var glyph: String {
            switch self {
            case .done: return "✓"
            case .running: return "●"
            case .pending: return "○"
            }
        }
        var label: String {
            switch self {
            case .done: return "done"
            case .running: return "running"
            case .pending: return "waiting"
            }
        }
    }

    private func state(for stage: MeetingStatus) -> StepState {
        if progress.status == .completed { return .done }
        let order: [MeetingStatus] = stages.map(\.status)
        let currentIndex = order.firstIndex(of: progress.status) ?? 0
        guard let stageIndex = order.firstIndex(of: stage) else { return .pending }
        if stageIndex < currentIndex { return .done }
        if stageIndex == currentIndex { return .running }
        return .pending
    }
}
