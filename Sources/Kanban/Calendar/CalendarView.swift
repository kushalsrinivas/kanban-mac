import SwiftUI

/// The local schedule. Every meeting here is real SQLite data; nothing is synced to
/// an external calendar. The agent creates entries, the user confirms them, and the
/// detail page shows what the Mac already knows about the participants.
struct CalendarView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    @State private var confirmingDelete: UUID?
    @State private var showPast = false

    private var upcoming: [ScheduledMeeting] { app.upcomingMeetings() }
    private var past: [ScheduledMeeting] { app.store.scheduledMeetings.past() }
    private var selected: ScheduledMeeting? { app.selectedScheduledMeeting }

    var body: some View {
        VStack(spacing: 10) {
            tabBar
            switch app.meetTab {
            case .briefs: briefs
            case .commitments: CommitmentsPane()
            case .memory: MemoryPane()
            case .automation: AutomationPane()
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .confirmationDialog("Remove this scheduled meeting?",
                            isPresented: Binding(
                                get: { confirmingDelete != nil },
                                set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Meeting", role: .destructive) {
                if let id = confirmingDelete {
                    app.deleteScheduledMeeting(id)
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("This removes the schedule entry on this Mac. Recordings and tasks are not affected.")
        }
        .task {
            await app.refreshCalendar()
            app.sweepCommitments()
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: app.store.scheduledMeetings) { _, _ in selectFirstIfNeeded() }
        .onChange(of: app.calendar.events) { _, _ in selectFirstIfNeeded() }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppModel.MeetTab.allCases, id: \.self) { item in
                let active = app.meetTab == item
                Button { app.meetTab = item } label: {
                    Text(item.rawValue)
                        .font(Theme.mono(10.5, weight: active ? .semibold : .regular))
                        .tracking(1)
                        .foregroundStyle(active ? theme.paper : theme.inkSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(active ? theme.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if app.meetTab == .automation, !app.store.automationRules.isEmpty {
                Text("\(app.store.automationRules.filter(\.enabled).count) ACTIVE")
                    .font(Theme.mono(9))
                    .foregroundStyle(theme.inkTertiary)
                    .padding(.trailing, 10)
            }
        }
        .background(theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(theme.lineStrong, lineWidth: Theme.Metric.hairline))
    }

    @ViewBuilder
    private var briefs: some View {
        HStack(alignment: .top, spacing: 10) {
            schedulePanel
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .top)

            VRule()

            Group {
                if let selected {
                    CalendarDetailView(meeting: selected, confirmingDelete: $confirmingDelete)
                        .id(selected.id)
                } else {
                    emptyDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func selectFirstIfNeeded() {
        if let selected = app.selectedScheduledMeetingID,
           app.scheduledMeeting(selected) != nil { return }
        app.selectedScheduledMeetingID = upcoming.first?.id
    }

    // MARK: List

    private var schedulePanel: some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    MicroLabel("schedule")
                    Spacer()
                    MicroLabel("\(String(format: "%02d", upcoming.count)) upcoming")
                    Button {
                        Task { await app.refreshCalendar() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9))
                    }
                    .buttonStyle(BareButtonStyle())
                    .help("Refresh Google/Outlook calendars")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)

                Rule()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if upcoming.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Nothing scheduled.")
                                    .font(Theme.body)
                                    .foregroundStyle(theme.inkSecondary)
                                Text("Ask the agent: “schedule a meeting about onboarding with Sarah tomorrow at 2pm”.")
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(theme.inkTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                        } else {
                            ForEach(upcoming) { meeting in
                                ScheduleRow(meeting: meeting, selected: meeting.id == app.selectedScheduledMeetingID)
                                    .contentShape(Rectangle())
                                    .onTapGesture { app.selectedScheduledMeetingID = meeting.id }
                            }
                        }

                        if !past.isEmpty {
                            Rule().padding(.vertical, 4)
                            Button {
                                showPast.toggle()
                            } label: {
                                HStack {
                                    MicroLabel("past")
                                    Spacer()
                                    Text(showPast ? "HIDE" : "SHOW")
                                        .font(Theme.mono(9))
                                        .tracking(0.5)
                                        .foregroundStyle(theme.inkTertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showPast {
                                ForEach(past) { meeting in
                                    ScheduleRow(meeting: meeting,
                                                selected: meeting.id == app.selectedScheduledMeetingID)
                                        .contentShape(Rectangle())
                                        .onTapGesture { app.selectedScheduledMeetingID = meeting.id }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)

                Rule()
                HStack(spacing: 6) {
                    if app.calendar.isAuthorized {
                        StatusDot(.on)
                        Text("GOOGLE / OUTLOOK VIA MACOS")
                            .font(Theme.mono(8.5))
                            .tracking(0.4)
                            .foregroundStyle(theme.inkTertiary)
                    } else if app.calendar.isDenied {
                        StatusDot(.alert)
                        Text("CALENDAR ACCESS DENIED")
                            .font(Theme.mono(8.5))
                            .tracking(0.4)
                            .foregroundStyle(theme.signal)
                    } else {
                        Button("CONNECT CALENDAR") {
                            Task { await app.connectCalendar() }
                        }
                        .buttonStyle(BareButtonStyle())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Spacer()
            MicroLabel("no meeting selected")
            Text("Schedule one from the agent, or pick a meeting from the list.")
                .font(Theme.body)
                .foregroundStyle(theme.inkTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

private struct ScheduleRow: View {
    @Environment(\.theme) private var theme
    let meeting: ScheduledMeeting
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(CalendarFormat.day(meeting.startsAt))
                    .font(Theme.mono(9, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(theme.inkTertiary)
                Text(CalendarFormat.time(meeting.startsAt))
                    .font(Theme.mono(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.inkSecondary)
                Spacer(minLength: 0)
                if meeting.meetingID != nil {
                    Circle().fill(theme.inkSecondary).frame(width: 5, height: 5)
                        .accessibilityLabel("Recording linked")
                }
            }
            Text(meeting.title)
                .font(Theme.cardTitle)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
            if !meeting.participants.isEmpty {
                Text(meeting.participants.joined(separator: ", ").uppercased())
                    .font(Theme.mono(8.5))
                    .foregroundStyle(theme.inkTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? theme.selectionFill : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(theme.ink).frame(width: 2) }
        }
    }
}

// MARK: - Detail

private struct CalendarDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let meeting: ScheduledMeeting
    @Binding var confirmingDelete: UUID?

    private var brief: ScheduledMeetingBrief { app.brief(for: meeting) }
    private var isExternal: Bool { app.isExternalScheduledMeeting(meeting.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                actions
                people
                briefBody
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title.uppercased())
                    .font(Theme.display(19, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(theme.ink)
                Spacer()
                Menu {
                    if !isExternal {
                        Button("Remove Meeting", role: .destructive) { confirmingDelete = meeting.id }
                    } else {
                        Button("Refresh Calendar") { Task { await app.refreshCalendar() } }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Scheduled meeting actions")
            }

            HStack(spacing: 6) {
                Text(CalendarFormat.day(meeting.startsAt))
                Text("·")
                Text(CalendarFormat.range(meeting.startsAt, meeting.endsAt))
                Text("·")
                Text(Meeting.durationLabel(meeting.duration))
                Text("·")
                Text(status)
                    .foregroundStyle(meeting.isPast() ? theme.inkTertiary : theme.inkSecondary)
            }
            .font(Theme.mono(10.5))
            .tracking(0.6)
            .foregroundStyle(theme.inkTertiary)

            if !meeting.location.isEmpty {
                HStack(spacing: 5) {
                    MicroLabel("where")
                    Text(meeting.location.uppercased())
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.inkSecondary)
                }
            }

            Rule()
        }
        .padding(.top, 2)
    }

    private var status: String {
        if meeting.meetingID != nil { return "RECORDED" }
        if meeting.isLive() { return "LIVE" }
        if meeting.isPast() { return "PAST" }
        return "SCHEDULED"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let recording = meeting.meetingID {
                Button("OPEN RECORDING") { app.openMeeting(recording) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
            } else if !meeting.isPast() {
                Button("RECORD THIS MEETING") { app.startRecording(forScheduled: meeting.id) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
            }
            Spacer(minLength: 0)
            Text(isExternal ? "EXTERNAL CALENDAR · READ ONLY" : "LOCAL · NOT SYNCED TO AN EXTERNAL CALENDAR")
                .font(Theme.mono(8.5))
                .tracking(0.4)
                .foregroundStyle(theme.inkTertiary)
        }
    }

    @ViewBuilder
    private var people: some View {
        if !meeting.participants.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                MicroLabel("people")
                HStack(spacing: 6) {
                    ForEach(meeting.participants, id: \.self) { name in
                        HStack(spacing: 5) {
                            Text(initials(name))
                                .font(Theme.mono(8.5, weight: .medium))
                                .foregroundStyle(theme.inkSecondary)
                                .frame(width: 20, height: 20)
                                .background(theme.panelAlt, in: Circle())
                                .overlay(Circle().strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
                            Text(name.uppercased())
                                .font(Theme.mono(9))
                                .foregroundStyle(theme.inkSecondary)
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
        }
    }

    private var briefBody: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !brief.summary.isEmpty {
                Text(brief.summary)
                    .font(Theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !meeting.notes.isEmpty {
                Text(meeting.notes)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
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
                    if !brief.suggestedSlots.isEmpty {
                        MicroLabel("better times")
                        ForEach(Array(brief.suggestedSlots.prefix(3).enumerated()), id: \.offset) { _, slot in
                            Text(CalendarFormat.range(slot.start, slot.end))
                                .font(Theme.mono(9.5))
                                .foregroundStyle(theme.inkSecondary)
                        }
                    }
                }
            }

            if !brief.relatedMeetings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    MicroLabel("related conversations")
                    ForEach(brief.relatedMeetings) { related in
                        Button { app.openMeeting(related.meetingID) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(CalendarFormat.day(related.date))
                                    .font(Theme.mono(9))
                                    .foregroundStyle(theme.inkTertiary)
                                    .frame(width: 48, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(related.title)
                                        .font(Theme.body)
                                        .foregroundStyle(theme.ink)
                                    if !related.summary.isEmpty {
                                        Text(AgentText.brief(related.summary, 160))
                                            .font(Theme.mono(9.5))
                                            .foregroundStyle(theme.inkTertiary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !brief.openActions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    MicroLabel("open items")
                    ForEach(brief.openActions.prefix(10)) { action in
                        HStack(alignment: .top, spacing: 7) {
                            Text(action.state == .added ? "✓" : "○")
                                .font(Theme.mono(9))
                                .foregroundStyle(theme.inkTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title)
                                    .font(Theme.body)
                                    .foregroundStyle(theme.ink)
                                if let quote = action.quote {
                                    Text("\"\(quote)\"")
                                        .font(Theme.mono(9))
                                        .foregroundStyle(theme.inkTertiary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 6) {
                                    if let assignee = action.assignee, !assignee.isEmpty {
                                        Text(assignee.uppercased())
                                            .font(Theme.mono(8.5))
                                            .foregroundStyle(theme.inkTertiary)
                                    }
                                    if let due = action.dueDate {
                                        Text(DateInput.shortLabel(due))
                                            .font(Theme.mono(8.5))
                                            .foregroundStyle(action.overdue ? theme.signal : theme.inkTertiary)
                                    }
                                    if let start = action.sourceStart {
                                        Text(Meeting.timecode(start))
                                            .font(Theme.mono(8.5))
                                            .monospacedDigit()
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
                                Button("OPEN TASK") { app.openInspector(for: taskID) }
                                    .buttonStyle(BareButtonStyle())
                            } else {
                                Button("TASK") {
                                    if let found = app.store.commitment(action.itemID) {
                                        app.beginAdding(found.item)
                                    }
                                }
                                .buttonStyle(BareButtonStyle())
                            }
                            Button("DONE") {
                                if let found = app.store.commitment(action.itemID) {
                                    app.setCommitment(found.item, in: found.meeting, to: .done)
                                }
                            }
                            .buttonStyle(BareButtonStyle())
                        }
                    }
                }
            }

            if !brief.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    MicroLabel("decisions")
                    ForEach(brief.decisions.prefix(8)) { decision in
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

            if !brief.unresolvedQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    MicroLabel("unresolved questions")
                    ForEach(brief.unresolvedQuestions.prefix(6)) { question in
                        HStack(alignment: .top, spacing: 6) {
                            Text("?").font(Theme.mono(10)).foregroundStyle(theme.inkTertiary)
                            Text(question.text)
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
                Text("No prior conversations with these participants yet.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
            }
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.joined().uppercased()
    }
}
