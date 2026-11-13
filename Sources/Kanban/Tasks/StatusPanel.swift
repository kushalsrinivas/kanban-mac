import SwiftUI

/// The instrument cluster above the board: counts as large monospace values separated
/// by vertical rules, with a compact system module on the right.
struct StatusPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        let counts = app.store.counts()

        Panel(padding: 0) {
            HStack(spacing: 0) {
                metric("OPEN", counts.open)
                VRule().padding(.vertical, 12)
                metric("ACTIVE", counts.active)
                VRule().padding(.vertical, 12)
                metric("DUE TODAY", counts.dueToday)
                VRule().padding(.vertical, 12)
                metric("OVERDUE", counts.overdue, tint: counts.overdue > 0 ? theme.signal : nil)

                Spacer(minLength: 8)

                VRule().padding(.vertical, 12)
                SystemModule()
            }
            .frame(height: 68)
        }
    }

    private func metric(_ label: String, _ value: Int, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel(label)
            Text(String(format: "%02d", value))
                .font(Theme.mono(26, weight: .light))
                .monospacedDigit()
                .foregroundStyle(tint ?? theme.ink)
        }
        .frame(width: 84, alignment: .leading)
        .padding(.leading, 14)
        .accessibilityElement(children: .combine)
    }
}

/// Backend state plus anything waiting on the user — present, never dominant.
struct SystemModule: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    var body: some View {
        let reviewCount = app.openSuggestionCount
        Button {
            if let meeting = app.store.meetings.first(where: { $0.suggestedCount > 0 }) {
                app.openMeeting(meeting.id)
            } else {
                app.section = .agent
            }
        } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    MicroLabel(reviewCount > 0 ? "review" : "agent")
                    HStack(spacing: 5) {
                        StatusDot(reviewCount > 0 ? .alert : dotState)
                        Text(reviewCount > 0
                             ? "\(reviewCount) TASK\(reviewCount == 1 ? "" : "S")"
                             : app.agent.statusLabel)
                            .font(Theme.mono(11, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(theme.ink)
                    }
                    Text(reviewCount > 0 ? "FROM MEETINGS" : subtitle)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(1)
                }
                .frame(width: 118, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.inkTertiary)
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reviewCount > 0 ? "Review suggested tasks" : "Open the agent console")
    }

    private var dotState: StatusDot.State {
        if app.agent.isBusy { return .idle }
        switch app.sync.connection {
        case .online: return .on
        case .offline: return .alert
        case .checking: return .idle
        case .unconfigured: return .off
        }
    }

    private var subtitle: String {
        if !app.agent.pending.isEmpty { return "\(app.agent.pending.count) TO CONFIRM" }
        if app.openSuggestionCount > 0 {
            let count = app.openSuggestionCount
            return "\(count) SUGGESTED TASK\(count == 1 ? "" : "S")"
        }
        if app.sync.pendingCount > 0 { return "\(app.sync.pendingCount) QUEUED" }
        switch app.sync.connection {
        case .unconfigured: return "NO VPS SET"
        case .offline: return "VPS UNREACHABLE"
        case .checking: return "PROBING"
        case .online: return "READY"
        }
    }
}
