import SwiftUI

/// A task rendered as an instrument module: title block, hairline, metadata strip.
/// No colour coding, no shadow, no hover animation beyond a 1px border change.
struct TaskCardView: View {
    @Environment(\.theme) private var theme

    let task: TaskItem
    let isSelected: Bool
    let onOpen: () -> Void
    let onToggleComplete: () -> Void

    @State private var isHovering = false

    private var isOverdue: Bool { task.isOverdue() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                CompletionBox(isDone: task.isDone, title: task.title, action: onToggleComplete)
                    .padding(.top, 1)

                Text(task.title)
                    .font(Theme.cardTitle)
                    .foregroundStyle(task.isDone ? theme.inkTertiary : theme.ink)
                    .strikethrough(task.isDone, color: theme.inkTertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                // Provenance: a task that came out of a meeting or the agent is
                // marked, so the board never hides where something came from.
                if task.source != .manual {
                    Text(task.source == .meeting ? "MTG" : "AGT")
                        .font(Theme.mono(9.5, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(theme.inkSecondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(theme.line, lineWidth: Theme.Metric.hairline))
                        .help(task.source == .meeting ? "Came from a meeting" : "Created by the agent")
                }
            }

            if !task.tags.isEmpty {
                Text(task.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(theme.inkTertiary)
                    .lineLimit(1)
            }

            Rule()

            HStack(spacing: 6) {
                PriorityMark(task.priority)
                Text(task.priority.label)
                    .font(Theme.mono(9.5, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(theme.inkSecondary)

                if let due = task.dueDate {
                    Text("·").font(Theme.mono(9.5)).foregroundStyle(theme.line)
                    Text(DateInput.shortLabel(due))
                        .font(Theme.mono(9.5, weight: isOverdue ? .semibold : .regular))
                        .tracking(0.6)
                        .foregroundStyle(isOverdue ? theme.signal : theme.inkSecondary)
                }

                Spacer(minLength: 0)

                if !task.subtasks.isEmpty {
                    Text("\(task.doneSubtaskCount)/\(task.subtasks.count)")
                        .font(Theme.mono(9.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.inkTertiary)
                }
                if !task.notes.isEmpty {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundStyle(theme.inkTertiary)
                }
            }
        }
        .padding(Theme.Metric.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            // Selection reads as a machined notch on the left edge, not a highlight.
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.accent)
                    .frame(width: 2.5)
                    .padding(.vertical, 8)
                    .padding(.leading, 1)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? theme.ink
                              : isHovering ? theme.inkSecondary : theme.lineStrong,
                              lineWidth: Theme.Metric.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .transition(.opacity)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .help("Double-click to open")
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open") { onOpen() }
    }
}

/// Square checkbox with a hairline border — matches the control-panel language.
private struct CompletionBox: View {
    @Environment(\.theme) private var theme
    let isDone: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(isDone ? theme.ink : Color.clear)
                .frame(width: 11, height: 11)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(isDone ? theme.ink : theme.lineStrong, lineWidth: 1)
                )
                .overlay {
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(theme.panel)
                    }
                }
                // The glyph stays 11pt; the hit region grows by 5pt on each side
                // without changing the card's layout.
                .contentShape(Rectangle().inset(by: -5))
        }
        .buttonStyle(.plain)
        .help(isDone ? "Reopen" : "Complete")
        .accessibilityLabel(isDone ? "Reopen \(title)" : "Complete \(title)")
    }
}
