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
                    if case .awaitingDecision = app.recorder.phase {
                        MicroLabel("stopped")
                    } else {
                        MicroLabel(app.recorder.isRecording ? "live" : "ready")
                    }
                }

                Rule()

                switch app.recorder.phase {
                case .idle, .preparing:
                    idleState(recorder: recorder)
                case .recording, .paused:
                    activeState
                case .awaitingDecision(let id, let duration, let bytes):
                    decisionState(meetingID: id, duration: duration, bytes: bytes)
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

            Button {
                app.startRecording()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(theme.paper).frame(width: 7, height: 7)
                    Text("START RECORDING")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            .disabled(app.recorder.phase == .preparing || app.recorder.sources.isSilent)

            if app.recorder.sources.isSilent {
                Text("Nothing can be captured. Check microphone and screen-recording permissions in Settings.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        }
    }

    private func decisionState(meetingID: UUID, duration: TimeInterval, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROCESS MEETING?")
                .font(Theme.display(14, weight: .medium))
                .foregroundStyle(theme.ink)

            Text("Your \(Meeting.durationLabel(duration).lowercased()) recording is ready. "
                 + "Nothing leaves this Mac until you choose.")
                .font(Theme.body)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                MicroLabel("size")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file).uppercased())
                    .font(Theme.mono(10.5))
                    .foregroundStyle(theme.inkSecondary)
            }

            VStack(spacing: 6) {
                Button("PROCESS") { app.processRecording(meetingID) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .frame(maxWidth: .infinity)
                    .disabled(!app.settings.backendIsConfigured)

                Button("SAVE LOCALLY") {
                    app.recorder.keepLocal()
                    app.selectedMeeting = meetingID
                }
                .buttonStyle(PanelButtonStyle())
                .frame(maxWidth: .infinity)

                Button("DISCARD") { Task { await app.recorder.discard() } }
                    .buttonStyle(BareButtonStyle())
            }

            if !app.settings.backendIsConfigured {
                Text("No VPS configured, so processing is unavailable. The recording is kept.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !app.sync.connection.isOnline {
                Text("VPS offline. Choose PROCESS and it will upload when the connection returns.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
            Button("Delete Meeting") { app.deleteMeeting(meeting.id) }
        }
    }

    private var timeLabel: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = Calendar.current.isDateInToday(meeting.startedAt) ? "HH:mm" : "EEE"
        return df.string(from: meeting.startedAt).uppercased()
    }
}
