import SwiftUI

/// Renders an artifact without knowing what kind it is.
///
/// A new artifact type is registered here once. The transcript view iterates
/// artifacts and calls `AgentArtifactView`; it never grows another switch.
@MainActor
struct AgentArtifactRegistry {
    typealias Renderer = @MainActor (AgentArtifact) -> AnyView

    private var renderers: [AgentArtifactKind: Renderer] = [:]

    mutating func register(_ kind: AgentArtifactKind, _ renderer: @escaping Renderer) {
        renderers[kind] = renderer
    }

    func view(for artifact: AgentArtifact) -> AnyView {
        guard let renderer = renderers[artifact.kind] else {
            return AnyView(UnsupportedArtifactCard(artifact: artifact))
        }
        return renderer(artifact)
    }

    /// Every declared kind must have a renderer. A missing one would otherwise
    /// appear only when that artifact is first produced in real use.
    var unregisteredKinds: [AgentArtifactKind] {
        AgentArtifactKind.allCases.filter { renderers[$0] == nil }
    }

    static let live: AgentArtifactRegistry = {
        var registry = AgentArtifactRegistry()
        registry.register(.taskList) { artifact in
            guard case .taskList(let list) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(TaskListCard(list: list))
        }
        registry.register(.meetingList) { artifact in
            guard case .meetingList(let list) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(MeetingListCard(list: list))
        }
        registry.register(.meetingSummary) { artifact in
            guard case .meetingSummary(let summary) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(MeetingSummaryCard(summary: summary))
        }
        registry.register(.recording) { artifact in
            guard case .recording(let recording) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(RecordingCard(recording: recording))
        }
        registry.register(.transcript) { artifact in
            guard case .transcript(let transcript) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(TranscriptCard(transcript: transcript))
        }
        registry.register(.actionItems) { artifact in
            guard case .actionItems(let items) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(ActionItemsCard(items: items))
        }
        registry.register(.participants) { artifact in
            guard case .participants(let participants) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(ParticipantsCard(participants: participants))
        }
        registry.register(.scheduledMeetingList) { artifact in
            guard case .scheduledMeetingList(let list) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(ScheduledMeetingListCard(list: list))
        }
        registry.register(.scheduledMeeting) { artifact in
            guard case .scheduledMeeting(let value) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(ScheduledMeetingCard(value: value))
        }
        registry.register(.scheduledBrief) { artifact in
            guard case .scheduledBrief(let value) = artifact.payload else { return AnyView(EmptyView()) }
            return AnyView(ScheduledBriefCard(value: value))
        }
        return registry
    }()
}

struct AgentArtifactView: View {
    let artifact: AgentArtifact

    var body: some View {
        AgentArtifactRegistry.live.view(for: artifact)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(artifact.kind.label): \(artifact.title)")
    }
}

// MARK: - Navigation helpers

private extension Meeting {
    func hasPlayableAudio(backendConfigured: Bool) -> Bool {
        if let filename = audioFilename,
           FileManager.default.fileExists(atPath: KanbanPaths.recordingURL(filename: filename).path) {
            return true
        }
        return remoteID != nil && backendConfigured
    }
}

// MARK: - Shared chrome

private struct ArtifactShell<Content: View>: View {
    @Environment(\.theme) private var theme
    let kind: AgentArtifactKind
    let title: String
    var trailing: String?
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MicroLabel(kind.label, color: theme.inkSecondary)
                Text(title)
                    .font(Theme.display(12.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(Theme.mono(9.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkTertiary)
                }
            }

            if let note, !note.isEmpty {
                Text(note)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rule()
            content
        }
        .padding(Theme.Metric.cardPadding)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
    }
}

private struct EmptyArtifactRow: View {
    @Environment(\.theme) private var theme
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(.off)
            Text(message)
                .font(Theme.mono(10.5))
                .foregroundStyle(theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct ArtifactAction: View {
    @Environment(\.theme) private var theme
    let label: String
    var emphasised = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(9.5, weight: emphasised ? .semibold : .medium))
                .tracking(0.6)
                .foregroundStyle(emphasised ? theme.ink : theme.inkSecondary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct ArtifactDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.line.opacity(0.7)).frame(height: Theme.Metric.hairline)
    }
}

private struct UnsupportedArtifactCard: View {
    @Environment(\.theme) private var theme
    let artifact: AgentArtifact

    var body: some View {
        ArtifactShell(kind: artifact.kind, title: artifact.title, trailing: nil,
                      note: "This artifact type has no renderer yet.") {
            EmptyView()
        }
    }
}

// MARK: - Task list

private struct TaskListCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let list: TaskListArtifact

    var body: some View {
        ArtifactShell(kind: .taskList, title: list.title,
                      trailing: "\(String(format: "%02d", list.tasks.count))",
                      note: list.note) {
            if list.tasks.isEmpty {
                EmptyArtifactRow(message: list.emptyMessage)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { ArtifactDivider().padding(.vertical, 7) }
                        TaskRow(snapshot: task)
                    }
                }
            }
        }
    }
}

private struct TaskRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let snapshot: TaskItem

    /// The card follows the live row: completing it elsewhere updates the card
    /// instead of leaving a stale COMPLETE button on a done task.
    private var task: TaskItem { app.store.task(snapshot.id) ?? snapshot }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PriorityMark(task.priority)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button { app.openInspector(for: task.id) } label: {
                        Text(task.title)
                            .font(Theme.cardTitle)
                            .foregroundStyle(task.isDone ? theme.inkTertiary : theme.ink)
                            .strikethrough(task.isDone, color: theme.inkTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("Open task")

                    if task.isOverdue() {
                        Text("OVERDUE")
                            .font(Theme.mono(8.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(theme.signal)
                    }
                }

                if !task.notes.isEmpty {
                    Text(AgentText.brief(task.notes, 110))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    Text(task.status.label)
                        .font(Theme.mono(9))
                        .tracking(0.5)
                        .foregroundStyle(theme.inkSecondary)
                    if let due = task.dueDate {
                        Text(DateInput.shortLabel(due))
                            .font(Theme.mono(9))
                            .monospacedDigit()
                            .foregroundStyle(task.isOverdue() ? theme.signal : theme.inkTertiary)
                    }
                    ForEach(task.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(Theme.mono(9))
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                ArtifactAction(label: "OPEN") { app.openInspector(for: task.id) }
                if !task.isDone {
                    ArtifactAction(label: "COMPLETE") { app.agent.proposeComplete(task.id) }
                }
                if let meetingID = task.meetingID {
                    ArtifactAction(label: "MEETING") { app.openMeeting(meetingID) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Meeting list

private struct MeetingListCard: View {
    @Environment(\.theme) private var theme
    let list: MeetingListArtifact

    var body: some View {
        ArtifactShell(kind: .meetingList, title: list.title,
                      trailing: "\(String(format: "%02d", list.meetings.count))",
                      note: list.note) {
            if list.meetings.isEmpty {
                EmptyArtifactRow(message: list.emptyMessage)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.meetings.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { ArtifactDivider().padding(.vertical, 7) }
                        MeetingRow(snapshot: meeting)
                    }
                }
            }
        }
    }
}

private struct MeetingRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let snapshot: Meeting

    private var meeting: Meeting { app.store.meeting(snapshot.id) ?? snapshot }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DateInput.shortLabel(meeting.startedAt))
                    .font(Theme.mono(9.5, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(theme.inkSecondary)
                Text(meeting.durationLabel)
                    .font(Theme.mono(9))
                    .monospacedDigit()
                    .foregroundStyle(theme.inkTertiary)
            }
            .frame(width: 54, alignment: .leading)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Button { app.openMeeting(meeting.id) } label: {
                    Text(meeting.title)
                        .font(Theme.cardTitle)
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Open meeting")

                if !meeting.summary.isEmpty {
                    Text(AgentText.brief(meeting.summary, 150))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    Text(meeting.status.label)
                        .font(Theme.mono(9))
                        .tracking(0.5)
                        .foregroundStyle(meeting.status == .failed ? theme.signal : theme.inkSecondary)
                    if !meeting.participants.isEmpty {
                        Text("\(meeting.participants.count) PEOPLE")
                            .font(Theme.mono(9))
                            .foregroundStyle(theme.inkTertiary)
                    }
                    if meeting.suggestedCount > 0 {
                        Text("\(meeting.suggestedCount) TO REVIEW")
                            .font(Theme.mono(9, weight: .medium))
                            .foregroundStyle(theme.signal)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                ArtifactAction(label: "OPEN", emphasised: true) { app.openMeeting(meeting.id) }
                ArtifactAction(label: "SUMMARY") { app.agent.summarize(meeting.id) }
                if canPlay {
                    ArtifactAction(label: "PLAY") { app.agent.play(meeting) }
                }
            }
        }
    }

    private var canPlay: Bool {
        meeting.hasPlayableAudio(backendConfigured: app.settings.backendIsConfigured)
    }
}

// MARK: - Recording

private struct RecordingCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let recording: RecordingArtifact

    @State private var wasPlayingBeforeScrub = false

    private var player: RecordingPlayer { app.agent.player }
    private var isCurrent: Bool { player.meetingID == recording.meeting.id }

    var body: some View {
        ArtifactShell(kind: .recording, title: recording.meeting.title,
                      trailing: recording.meeting.durationLabel,
                      note: "\(DateInput.shortLabel(recording.meeting.startedAt)) · \(sourceLabel)") {
            if !recording.isPlayable {
                EmptyArtifactRow(message: recording.unavailableReason ?? "No audio is available for this meeting.")
                footer
            } else {
                controls
                footer
            }
        }
        .onDisappear {
            // The panel keeps one player; leaving the card should not leave audio
            // running behind another section.
            if isCurrent, player.isPlaying { player.pause() }
        }
    }

    private var sourceLabel: String {
        if !isCurrent { return recording.localAudio != nil ? "ON THIS MAC" : "ON THE VPS" }
        return player.sourceLabel.isEmpty ? "READY" : player.sourceLabel
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    app.agent.togglePlayback(recording.meeting)
                } label: {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.paper)
                        .frame(width: 30, height: 30)
                        .background(theme.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .help(isCurrent && player.isPlaying ? "Pause" : "Play recording")
                .accessibilityLabel(isCurrent && player.isPlaying ? "Pause recording" : "Play recording")

                VStack(alignment: .leading, spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { isCurrent ? player.currentTime : 0 },
                            set: { value in if isCurrent { player.seek(to: value) } }
                        ),
                        in: 0...max(isCurrent ? player.duration : recording.meeting.duration, 1),
                        onEditingChanged: { editing in
                            guard isCurrent else { return }
                            if editing {
                                wasPlayingBeforeScrub = player.isPlaying
                                player.pause()
                            } else if wasPlayingBeforeScrub {
                                player.play()
                            }
                        }
                    )
                    .tint(theme.ink)
                    .controlSize(.mini)
                    .disabled(!isCurrent)
                    .accessibilityLabel("Recording position")

                    HStack {
                        Text(isCurrent ? player.timeLabel : "00:00 / \(Meeting.timecode(recording.meeting.duration))")
                            .font(Theme.mono(9))
                            .monospacedDigit()
                            .foregroundStyle(theme.inkTertiary)
                        Spacer()
                        if player.isLoading, isCurrent {
                            MicroLabel("buffering")
                        } else if isCurrent, player.isPlaying {
                            MicroLabel("playing", color: theme.inkSecondary)
                        }
                    }
                }
            }

            if isCurrent, let error = player.error {
                Text(error)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ArtifactAction(label: "OPEN MEETING") { app.openMeeting(recording.meeting.id) }
            ArtifactAction(label: "SUMMARY") { app.agent.summarize(recording.meeting.id) }
            if !recording.meeting.transcript.isEmpty || !app.store.transcript(for: recording.meeting.id).isEmpty {
                ArtifactAction(label: "TRANSCRIPT") { app.agent.showTranscript(recording.meeting.id) }
            }
            if isCurrent, player.isPlaying {
                ArtifactAction(label: "PAUSE") { player.pause() }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Summary

private struct MeetingSummaryCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let summary: MeetingSummaryArtifact

    private var meeting: Meeting { summary.meeting }

    var body: some View {
        ArtifactShell(kind: .meetingSummary, title: meeting.title,
                      trailing: "\(DateInput.shortLabel(meeting.startedAt)) · \(meeting.durationLabel)",
                      note: summary.note) {
            VStack(alignment: .leading, spacing: 10) {
                if meeting.summary.isEmpty {
                    Text(summary.highlights.isEmpty
                         ? "No summary or transcript has been stored for this meeting yet."
                         : "No written summary yet. The timestamps below come from the stored transcript.")
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(meeting.summary)
                        .font(Theme.display(12))
                        .foregroundStyle(theme.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if !meeting.keyPoints.isEmpty {
                    bullets("KEY POINTS", meeting.keyPoints)
                }
                if !meeting.decisions.isEmpty {
                    bullets("DECISIONS", meeting.decisions)
                }

                if !meeting.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("action items")
                        ForEach(meeting.actionItems.prefix(6)) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.state == .added ? "✓" : item.state == .dismissed ? "×" : "○")
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(item.state == .added ? theme.inkSecondary : theme.inkTertiary)
                                    .frame(width: 9)
                                Text(item.title)
                                    .font(Theme.body)
                                    .foregroundStyle(theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let assignee = item.assignee, !assignee.isEmpty {
                                    Text(assignee.uppercased())
                                        .font(Theme.mono(8.5))
                                        .foregroundStyle(theme.inkTertiary)
                                }
                            }
                        }
                    }
                }

                if !summary.relatedTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("tasks from this meeting")
                        ForEach(summary.relatedTasks.prefix(5)) { task in
                            Button { app.openInspector(for: task.id) } label: {
                                HStack(spacing: 6) {
                                    Text(task.isDone ? "✓" : "○")
                                        .font(Theme.mono(9))
                                        .foregroundStyle(theme.inkTertiary)
                                    Text(task.title)
                                        .font(Theme.body)
                                        .foregroundStyle(task.isDone ? theme.inkTertiary : theme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(task.status.label)
                                        .font(Theme.mono(8.5))
                                        .foregroundStyle(theme.inkTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !summary.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("transcript timestamps")
                        ForEach(summary.highlights) { segment in
                            Button {
                                app.agent.play(meeting, at: segment.start)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("▶")
                                        .font(Theme.mono(8))
                                        .foregroundStyle(theme.inkTertiary)
                                        .padding(.top, 1)
                                    Text(segment.timecode)
                                        .font(Theme.mono(9))
                                        .monospacedDigit()
                                        .foregroundStyle(theme.inkSecondary)
                                        .frame(width: 40, alignment: .leading)
                                    Text(AgentText.brief(segment.text, 160))
                                        .font(Theme.mono(9.5))
                                        .foregroundStyle(theme.inkSecondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Play from this timestamp")
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                ArtifactAction(label: "OPEN MEETING", emphasised: true) { app.openMeeting(meeting.id) }
                ArtifactAction(label: "TRANSCRIPT") { app.openMeeting(meeting.id, focus: .transcript) }
                if meeting.hasPlayableAudio(backendConfigured: app.settings.backendIsConfigured) {
                    ArtifactAction(label: "PLAY") { app.agent.play(meeting) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func bullets(_ label: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            MicroLabel(label)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(Theme.mono(10)).foregroundStyle(theme.inkTertiary)
                    Text(item)
                        .font(Theme.body)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Transcript

private struct TranscriptCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let transcript: TranscriptArtifact

    private var meeting: Meeting { transcript.meeting }

    var body: some View {
        ArtifactShell(kind: .transcript, title: meeting.title,
                      trailing: "\(transcript.segments.count) / \(transcript.totalCount)",
                      note: transcript.note) {
            if transcript.segments.isEmpty {
                EmptyArtifactRow(message: transcript.isFiltered
                                 ? "No segment mentions “\(transcript.query ?? "")”."
                                 : "No transcript was stored for this meeting.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 { ArtifactDivider().padding(.vertical, 6) }
                        Button {
                            app.agent.play(meeting, at: segment.start)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("▶")
                                    .font(Theme.mono(8))
                                    .foregroundStyle(theme.inkTertiary)
                                    .padding(.top, 1)
                                Text(segment.timecode)
                                    .font(Theme.mono(9))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.inkTertiary)
                                    .frame(width: 42, alignment: .leading)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    if let speaker = segment.speaker, !speaker.isEmpty {
                                        Text(speaker.uppercased())
                                            .font(Theme.mono(8.5, weight: .medium))
                                            .tracking(0.6)
                                            .foregroundStyle(theme.inkSecondary)
                                    }
                                    highlighted(segment.text)
                                        .font(Theme.body)
                                        .foregroundStyle(theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Play from \(segment.timecode)")
                    }
                }
            }

            HStack(spacing: 12) {
                ArtifactAction(label: "OPEN MEETING", emphasised: true) {
                    app.openMeeting(meeting.id, focus: .transcript)
                }
                ArtifactAction(label: "SUMMARY") { app.agent.summarize(meeting.id) }
                if meeting.hasPlayableAudio(backendConfigured: app.settings.backendIsConfigured) {
                    ArtifactAction(label: "PLAY") { app.agent.play(meeting) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Keeps the search term visible in the row that matched it.
    private func highlighted(_ text: String) -> Text {
        guard let query = transcript.query, !query.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = theme.ink.opacity(0.14)
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return Text(attributed)
    }
}

// MARK: - Action items

private struct ActionItemsCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let items: ActionItemsArtifact

    var body: some View {
        ArtifactShell(kind: .actionItems,
                      title: items.meeting?.title ?? "RECENT MEETINGS",
                      trailing: "\(items.cards.count) · \(items.suggestedCount) TO REVIEW",
                      note: items.note) {
            if items.cards.isEmpty {
                EmptyArtifactRow(message: items.emptyMessage)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.cards.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { ArtifactDivider().padding(.vertical, 7) }
                        ActionItemRow(card: card, showMeeting: items.meeting == nil)
                    }
                }
            }

            if let meeting = items.meeting {
                HStack(spacing: 12) {
                    ArtifactAction(label: "OPEN MEETING", emphasised: true) {
                        app.openMeeting(meeting.id, focus: .actionItems)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct ActionItemRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let card: ActionItemCard
    let showMeeting: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(stateGlyph)
                .font(Theme.mono(10))
                .foregroundStyle(card.item.state == .added ? theme.inkSecondary : theme.inkTertiary)
                .frame(width: 10)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.item.title)
                    .font(Theme.body)
                    .foregroundStyle(card.item.state == .dismissed ? theme.inkTertiary : theme.ink)
                    .strikethrough(card.item.state == .dismissed, color: theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    Text(card.item.state.rawValue.uppercased())
                        .font(Theme.mono(8.5))
                        .tracking(0.5)
                        .foregroundStyle(theme.inkTertiary)
                    if let assignee = card.item.assignee, !assignee.isEmpty {
                        Text(assignee.uppercased())
                            .font(Theme.mono(8.5))
                            .foregroundStyle(theme.inkSecondary)
                    }
                    if let due = card.item.dueDate {
                        Text(DateInput.shortLabel(due))
                            .font(Theme.mono(8.5))
                            .monospacedDigit()
                            .foregroundStyle(theme.inkTertiary)
                    }
                    if showMeeting {
                        Text(card.meetingTitle.uppercased())
                            .font(Theme.mono(8.5))
                            .foregroundStyle(theme.inkTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                if let task = card.linkedTask {
                    ArtifactAction(label: "OPEN TASK") { app.openInspector(for: task.id) }
                } else if card.item.isSuggested {
                    ArtifactAction(label: "ADD TASK", emphasised: true) {
                        app.beginAdding(card.item)
                    }
                }
                if showMeeting || card.item.state == .dismissed {
                    ArtifactAction(label: "MEETING") { app.openMeeting(card.meetingID) }
                }
                if card.item.state == .dismissed {
                    ArtifactAction(label: "RESTORE") { app.restoreSuggestion(card.item) }
                }
            }
        }
    }

    private var stateGlyph: String {
        switch card.item.state {
        case .suggested: return "○"
        case .added: return "✓"
        case .dismissed: return "×"
        }
    }
}

// MARK: - Schedule

private struct ScheduledMeetingListCard: View {
    @Environment(\.theme) private var theme
    let list: ScheduledMeetingListArtifact

    var body: some View {
        ArtifactShell(kind: .scheduledMeetingList, title: list.title,
                      trailing: "\(String(format: "%02d", list.meetings.count))",
                      note: list.note) {
            if list.meetings.isEmpty {
                EmptyArtifactRow(message: list.emptyMessage)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.meetings.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { ArtifactDivider().padding(.vertical, 7) }
                        ScheduledMeetingRow(meeting: meeting)
                    }
                }
            }
        }
    }
}

private struct ScheduledMeetingRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let meeting: ScheduledMeeting

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(CalendarFormat.day(meeting.startsAt))
                    .font(Theme.mono(9.5, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(theme.inkSecondary)
                Text(CalendarFormat.time(meeting.startsAt))
                    .font(Theme.mono(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.ink)
                Text(meeting.durationMinutes < 60 ? "\(meeting.durationMinutes) MIN" : Meeting.durationLabel(meeting.duration))
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkTertiary)
            }
            .frame(width: 54, alignment: .leading)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Button { app.openCalendar(meeting.id) } label: {
                    Text(meeting.title)
                        .font(Theme.cardTitle)
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Open in Calendar")

                if !meeting.participants.isEmpty {
                    Text(meeting.participants.joined(separator: ", ").uppercased())
                        .font(Theme.mono(9))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(1)
                }
                if !meeting.location.isEmpty {
                    Text(meeting.location.uppercased())
                        .font(Theme.mono(9))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(1)
                }
                if meeting.meetingID != nil {
                    Text("RECORDING LINKED")
                        .font(Theme.mono(8.5, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(theme.inkSecondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                ArtifactAction(label: "OPEN", emphasised: true) { app.openCalendar(meeting.id) }
                ArtifactAction(label: "BRIEF") { app.agent.showScheduledBrief(meeting.id) }
                if let recording = meeting.meetingID {
                    ArtifactAction(label: "RECORDING") { app.openMeeting(recording) }
                }
            }
        }
    }
}

private struct ScheduledMeetingCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let value: ScheduledMeetingArtifact

    private var meeting: ScheduledMeeting { value.meeting }

    var body: some View {
        ArtifactShell(kind: .scheduledMeeting, title: meeting.title,
                      trailing: CalendarFormat.line(meeting), note: value.note) {
            VStack(alignment: .leading, spacing: 5) {
                if !meeting.participants.isEmpty {
                    MicroLabel("with")
                    Text(meeting.participants.joined(separator: ", ").uppercased())
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.inkSecondary)
                }
                if !meeting.location.isEmpty {
                    MicroLabel("where")
                    Text(meeting.location.uppercased())
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.inkSecondary)
                }
                if !meeting.notes.isEmpty {
                    Text(meeting.notes)
                        .font(Theme.body)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("LOCAL · NOT SYNCED TO AN EXTERNAL CALENDAR")
                    .font(Theme.mono(8.5))
                    .tracking(0.4)
                    .foregroundStyle(theme.inkTertiary)
            }

            HStack(spacing: 12) {
                ArtifactAction(label: "OPEN CALENDAR", emphasised: true) { app.openCalendar(meeting.id) }
                ArtifactAction(label: "BRIEF") { app.agent.showScheduledBrief(meeting.id) }
                if let recording = meeting.meetingID {
                    ArtifactAction(label: "OPEN RECORDING") { app.openMeeting(recording) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ScheduledBriefCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let value: ScheduledBriefArtifact

    private var brief: ScheduledMeetingBrief { value.brief }

    var body: some View {
        ArtifactShell(kind: .scheduledBrief, title: brief.scheduled.title,
                      trailing: CalendarFormat.line(brief.scheduled), note: value.note) {
            VStack(alignment: .leading, spacing: 10) {
                if !brief.summary.isEmpty {
                    Text(brief.summary)
                        .font(Theme.display(12))
                        .foregroundStyle(theme.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !brief.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("conflicts", color: theme.signal)
                        ForEach(brief.conflicts) { conflict in
                            Text("\(conflict.other.title) · \(CalendarFormat.line(conflict.other))")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(theme.signal)
                        }
                    }
                }
                if !brief.suggestedSlots.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        MicroLabel("better times")
                        ForEach(Array(brief.suggestedSlots.enumerated()), id: \.offset) { _, slot in
                            Text(CalendarFormat.dateTime(slot.start))
                                .font(Theme.mono(9.5))
                                .foregroundStyle(theme.inkSecondary)
                        }
                    }
                }
                if !brief.relatedMeetings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("related conversations")
                        ForEach(brief.relatedMeetings) { related in
                            Button { app.openMeeting(related.meetingID) } label: {
                                HStack(alignment: .top, spacing: 7) {
                                    Text(CalendarFormat.day(related.date))
                                        .font(Theme.mono(9))
                                        .foregroundStyle(theme.inkTertiary)
                                        .frame(width: 48, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(related.title)
                                            .font(Theme.body)
                                            .foregroundStyle(theme.ink)
                                        if !related.summary.isEmpty {
                                            Text(AgentText.brief(related.summary, 120))
                                                .font(Theme.mono(9))
                                                .foregroundStyle(theme.inkTertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open the recorded meeting")
                        }
                    }
                }
                if !brief.openActions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("open items")
                        ForEach(brief.openActions.prefix(8)) { action in
                            HStack(alignment: .top, spacing: 6) {
                                Text(action.state == .added ? "✓" : "○")
                                    .font(Theme.mono(9))
                                    .foregroundStyle(theme.inkTertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(action.title)
                                        .font(Theme.body)
                                        .foregroundStyle(theme.ink)
                                    HStack(spacing: 6) {
                                        if let assignee = action.assignee, !assignee.isEmpty {
                                            Text(assignee.uppercased())
                                                .font(Theme.mono(8.5))
                                                .foregroundStyle(theme.inkTertiary)
                                        }
                                        if let due = action.dueDate {
                                            Text(DateInput.shortLabel(due))
                                                .font(Theme.mono(8.5))
                                                .foregroundStyle(theme.inkTertiary)
                                        }
                                        Text(action.meetingTitle.uppercased())
                                            .font(Theme.mono(8.5))
                                            .foregroundStyle(theme.inkTertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if let taskID = action.taskID {
                                    ArtifactAction(label: "TASK") { app.openInspector(for: taskID) }
                                }
                            }
                        }
                    }
                }
                if !brief.unresolvedQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("unresolved questions")
                        ForEach(brief.unresolvedQuestions.prefix(5)) { question in
                            HStack(alignment: .top, spacing: 6) {
                                Text("?").font(Theme.mono(9)).foregroundStyle(theme.inkTertiary)
                                Text(question.text)
                                    .font(Theme.body)
                                    .foregroundStyle(theme.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !brief.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("decisions")
                        ForEach(brief.decisions.prefix(6)) { decision in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").font(Theme.mono(10)).foregroundStyle(theme.inkTertiary)
                                Text(decision.text)
                                    .font(Theme.body)
                                    .foregroundStyle(theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if brief.relatedMeetings.isEmpty && brief.openActions.isEmpty
                    && brief.decisions.isEmpty && brief.conflicts.isEmpty
                    && brief.unresolvedQuestions.isEmpty {
                    EmptyArtifactRow(message: "No prior conversations with these participants yet.")
                }
            }

            HStack(spacing: 12) {
                ArtifactAction(label: "OPEN CALENDAR", emphasised: true) { app.openCalendar(brief.scheduled.id) }
                ArtifactAction(label: "SCHEDULE ANOTHER") { app.section = .agent }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Participants

private struct ParticipantsCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let participants: ParticipantsArtifact

    var body: some View {
        ArtifactShell(kind: .participants, title: participants.meeting.title,
                      trailing: "\(participants.participants.count)",
                      note: participants.note) {
            if participants.participants.isEmpty {
                EmptyArtifactRow(message: participants.emptyMessage)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(participants.participants.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { ArtifactDivider().padding(.vertical, 6) }
                        HStack(spacing: 8) {
                            Text(card.initials)
                                .font(Theme.mono(9, weight: .medium))
                                .foregroundStyle(theme.inkSecondary)
                                .frame(width: 24, height: 24)
                                .background(theme.panelAlt, in: Circle())
                                .overlay(Circle().strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.name)
                                    .font(Theme.cardTitle)
                                    .foregroundStyle(theme.ink)
                                if !card.assignedItems.isEmpty {
                                    Text("\(card.assignedItems.count) ACTION ITEM\(card.assignedItems.count == 1 ? "" : "S") · \(card.linkedTasks.count) TASK\(card.linkedTasks.count == 1 ? "" : "S")")
                                        .font(Theme.mono(8.5))
                                        .foregroundStyle(theme.inkTertiary)
                                    if let first = card.assignedItems.first {
                                        Text(first.title)
                                            .font(Theme.mono(9.5))
                                            .foregroundStyle(theme.inkSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                ArtifactAction(label: "OPEN MEETING", emphasised: true) {
                    app.openMeeting(participants.meeting.id)
                }
                ArtifactAction(label: "SUMMARY") { app.agent.summarize(participants.meeting.id) }
                Spacer(minLength: 0)
            }
        }
    }
}
