import SwiftUI

/// The meetings section: recorder on the left, library on the right, detail below.
struct MeetingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                RecordingPanel()
                MeetingListPanel()
            }
            .frame(width: 300)

            VRule()

            Group {
                if let id = app.selectedMeeting, let meeting = app.store.meeting(id) {
                    MeetingDetailView(meeting: meeting)
                        .id(id)
                } else {
                    emptyDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Theme.Metric.gutter)
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Spacer()
            MicroLabel("no meeting selected")
            Text("Record a meeting, or pick one from the list.")
                .font(Theme.body)
                .foregroundStyle(theme.inkTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Recorder

/// Deliberately plain. Recording state has to be unmissable, and everything else
/// about this panel gets out of the way.
struct RecordingPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        let recorder = Bindable(app.recorder)

        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    MicroLabel("meeting")
                    Spacer()
                    MicroLabel(app.recorder.isRecording ? "live" : "ready")
                }

                Rule()

                switch app.recorder.phase {
                case .idle, .preparing:
                    idleState(recorder: recorder)
                case .recording, .paused:
                    activeState
                }

                if let finished = app.recorder.lastFinished, !app.recorder.isRecording {
                    Rule()
                    lastRecording(finished)
                }

                Rule()
                sourceRows

                if let error = app.recorder.lastError {
                    Text(error)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: States

    private func idleState(recorder: Bindable<MeetingRecorder>) -> some View {
        VStack(spacing: 10) {
            TextField("", text: recorder.title,
                      prompt: Text("meeting name (optional)")
                        .font(Theme.mono(11)).foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))

            Text("00:00:00")
                .font(Theme.mono(30, weight: .light))
                .monospacedDigit()
                .foregroundStyle(theme.inkTertiary)

            if app.recorder.needsPermission {
                // Asking here is what registers the app with macOS; until it has
                // asked once it does not appear under Privacy & Security at all.
                Button("GRANT ACCESS") {
                    Task { await app.recorder.requestPermissions() }
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .frame(maxWidth: .infinity)

                Text(app.recorder.sources.isSilent
                     ? "Kanban needs permission before it can capture anything."
                     : "Some audio would be missed. Grant the rest, or record with what is available.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                app.startRecording()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(theme.paper).frame(width: 7, height: 7)
                    Text("START RECORDING")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle(prominent: !app.recorder.needsPermission))
            .disabled(app.recorder.phase == .preparing || app.recorder.sources.isSilent)
        }
    }

    private var activeState: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                // The one piece of motion in the app: a recording indicator must read
                // as live, so it pulses. Everything else is static.
                RecordingDot(isPaused: app.recorder.phase == .paused)
                Text(app.recorder.phase == .paused ? "PAUSED" : "RECORDING")
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(app.recorder.phase == .paused ? theme.inkSecondary : theme.signal)
                Spacer()
                LevelMeter(level: app.recorder.level)
            }

            Text(Meeting.timecode(app.recorder.elapsed))
                .font(Theme.mono(30, weight: .light))
                .monospacedDigit()
                .foregroundStyle(theme.ink)
                .contentTransition(.identity)

            if let hint = app.recorder.noSignalHint {
                Text(hint)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button(app.recorder.phase == .paused ? "RESUME" : "PAUSE") {
                    app.recorder.phase == .paused ? app.recorder.resume() : app.recorder.pause()
                }
                .buttonStyle(PanelButtonStyle())

                Button {
                    app.stopRecording()
                } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(theme.paper).frame(width: 7, height: 7)
                        Text("STOP")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
            }

            Button("FORCE STOP") { Task { await app.recorder.forceStop() } }
                .buttonStyle(BareButtonStyle())
        }
    }

    /// What happened to the recording that just stopped. It is already saved and,
    /// unless that was turned off, already on its way to the VPS — so this reports
    /// rather than asks, and offers the one thing still worth deciding: keeping it.
    private func lastRecording(_ finished: MeetingRecorder.Finished) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                MicroLabel("last recording")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: finished.bytes, countStyle: .file)
                    .uppercased())
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
            }

            Text(summary(for: finished))
                .font(Theme.mono(10))
                .foregroundStyle(finished.wasSilent ? theme.signal : theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button("OPEN") { app.openMeeting(finished.meetingID) }
                    .buttonStyle(PanelButtonStyle(compact: true))
                if app.store.meeting(finished.meetingID)?.awaitsUpload == true,
                   app.settings.backendIsConfigured {
                    Button("PROCESS") { app.processRecording(finished.meetingID) }
                        .buttonStyle(PanelButtonStyle(compact: true))
                }
                Spacer()
                Button("DELETE") { app.deleteMeeting(finished.meetingID) }
                    .buttonStyle(BareButtonStyle())
            }
        }
    }

    private func summary(for finished: MeetingRecorder.Finished) -> String {
        let length = Meeting.durationLabel(finished.duration)
        if finished.wasSilent {
            return "\(length) recorded, but no audio was detected. Saved anyway."
        }
        guard app.settings.autoUpload, app.settings.backendIsConfigured else {
            return "\(length) saved to this Mac."
        }
        return app.sync.connection.isOnline
            ? "\(length) saved and sent for transcription."
            : "\(length) saved. It uploads when the VPS is reachable."
    }

    // MARK: Sources

    private var sourceRows: some View {
        VStack(spacing: 4) {
            sourceRow("MICROPHONE", app.recorder.sources.microphone)
            sourceRow("SYSTEM AUDIO", app.recorder.sources.systemAudio)
        }
    }

    private func sourceRow(_ label: String, _ state: CaptureSources.State) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                MicroLabel(label)
                Spacer()
                Text(state.label)
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(colour(for: state))
            }
            if let detail = state.detail {
                Text(detail)
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func colour(for state: CaptureSources.State) -> Color {
        switch state {
        case .active: return theme.ink
        case .ready: return theme.inkSecondary
        case .denied, .unavailable: return theme.signal
        case .disabled: return theme.inkTertiary
        }
    }
}

// MARK: - Indicators

private struct RecordingDot: View {
    @Environment(\.theme) private var theme
    let isPaused: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(isPaused ? theme.inkTertiary : theme.signal)
            .frame(width: 9, height: 9)
            .opacity(dim && !isPaused ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// Eight bars, updated ~10×/second. Enough to prove audio is arriving, cheap enough
/// to leave running for an hour.
private struct LevelMeter: View {
    @Environment(\.theme) private var theme
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                Rectangle()
                    .fill(Float(index) / 8 < level ? theme.ink : theme.line)
                    .frame(width: 2, height: 4 + CGFloat(index))
            }
        }
        .frame(height: 12, alignment: .bottom)
        .accessibilityLabel("Input level")
    }
}

// MARK: - Library

private struct MeetingListPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MicroLabel("meetings")
                    Spacer()
                    Text(String(format: "%02d", app.store.meetings.count))
                        .font(Theme.mono(10.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, 8)

                Rule()

                if app.store.meetings.isEmpty {
                    VStack(spacing: 4) {
                        Text("—").font(Theme.mono(14)).foregroundStyle(theme.line)
                        MicroLabel("nothing recorded")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(app.store.meetings.grouped(), id: \.0) { group, meetings in
                                Section {
                                    ForEach(meetings) { meeting in
                                        MeetingRow(meeting: meeting)
                                    }
                                } header: {
                                    HStack {
                                        MicroLabel(group)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(theme.panel)
                                    .overlay(alignment: .bottom) { Rule() }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 340)
                }
            }
        }
    }
}

private struct MeetingRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let meeting: Meeting

    @State private var hovering = false
    @State private var confirmingDelete = false

    private var isSelected: Bool { app.selectedMeeting == meeting.id }

    var body: some View {
        Button { app.openMeeting(meeting.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Text(timeLabel)
                    .font(Theme.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(theme.inkTertiary)
                    .frame(width: 34, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title.uppercased())
                        .font(Theme.mono(11, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(meeting.durationLabel)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(theme.inkTertiary)

                        if meeting.status != .completed {
                            Text("·").font(Theme.mono(9.5)).foregroundStyle(theme.line)
                            Text(meeting.status.label)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(meeting.status == .failed ? theme.signal : theme.inkSecondary)
                        }
                        if meeting.suggestedCount > 0 {
                            Text("·").font(Theme.mono(9.5)).foregroundStyle(theme.line)
                            Text("\(meeting.suggestedCount) SUGGESTED")
                                .font(Theme.mono(9.5, weight: .medium))
                                .foregroundStyle(theme.ink)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? theme.selectionFill : (hovering ? theme.panelAlt : .clear))
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(theme.ink).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            MeetingActions(meeting: meeting, confirmingDelete: $confirmingDelete)
        }
        .deleteMeetingConfirmation(meeting, isPresented: $confirmingDelete)
    }

    private var timeLabel: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = Calendar.current.isDateInToday(meeting.startedAt) ? "HH:mm" : "EEE"
        return df.string(from: meeting.startedAt).uppercased()
    }
}

// MARK: - Meeting actions

/// The same menu wherever a meeting can be acted on: the list and the detail header.
struct MeetingActions: View {
    @Environment(AppModel.self) private var app
    let meeting: Meeting
    @Binding var confirmingDelete: Bool

    var body: some View {
        if meeting.awaitsUpload && app.settings.backendIsConfigured {
            Button("Process Now") { app.processRecording(meeting.id) }
        }
        if meeting.status == .readyToProcess {
            Button("Keep Local Only") { app.keepMeetingLocal(meeting.id) }
        }
        if meeting.audioFilename != nil {
            Button("Reveal Recording in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [KanbanPaths.recordingURL(filename: meeting.audioFilename!)])
            }
            // Useful once the notes are back: the audio is the bulky part, and the
            // meeting itself is worth keeping.
            Button("Delete Recording File") { app.deleteRecordingAudio(meeting.id) }
                .disabled(meeting.awaitsUpload)
        }
        Divider()
        Button("Delete Meeting", role: .destructive) { confirmingDelete = true }
    }
}

extension View {
    /// Deleting a meeting takes the audio and the VPS copy with it, so it asks first.
    func deleteMeetingConfirmation(_ meeting: Meeting, isPresented: Binding<Bool>) -> some View {
        modifier(DeleteMeetingConfirmation(meeting: meeting, isPresented: isPresented))
    }
}

private struct DeleteMeetingConfirmation: ViewModifier {
    @Environment(AppModel.self) private var app
    let meeting: Meeting
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete \(meeting.title)?",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Everywhere", role: .destructive) { app.deleteMeeting(meeting.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(detail)
        }
    }

    private var detail: String {
        var parts = ["The notes and transcript go with it."]
        if meeting.audioFilename != nil { parts.append("The recording is deleted from this Mac.") }
        if meeting.remoteID != nil && app.settings.backendIsConfigured {
            parts.append("The copy on the VPS is deleted too.")
        }
        parts.append("This cannot be undone.")
        return parts.joined(separator: " ")
    }
}
