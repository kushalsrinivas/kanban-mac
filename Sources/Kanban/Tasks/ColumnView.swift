import SwiftUI
import UniformTypeIdentifiers

/// One board column. Header block, hairline, then the card stack with explicit
/// drop gaps between cards so a drag lands at a precise index rather than "somewhere".
struct ColumnView: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    let status: TaskStatus
    let tasks: [TaskItem]

    @State private var isColumnTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rule()
                .padding(.bottom, 2)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DropGap(status: status, index: 0)
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        card(for: task)
                        DropGap(status: status, index: index + 1)
                    }

                    if tasks.isEmpty { emptyState }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Theme.Metric.columnWidth)
        .background(theme.panelAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(isColumnTargeted ? theme.lineStrong : theme.line,
                              lineWidth: Theme.Metric.hairline)
        )
        // Fallback: dropping anywhere in the status appends to the end.
        .dropDestination(for: TaskTransfer.self) { items, _ in
            guard let id = items.first?.uuid else { return false }
            try? app.taskService.move(id, to: status, index: tasks.count)
            app.selection = id
            app.focusedStatus = status
            return true
        } isTargeted: { isColumnTargeted = $0 }
    }

    /// Extracted so the column body stays cheap to type-check.
    @ViewBuilder
    private func card(for task: TaskItem) -> some View {
        TaskCardView(
            task: task,
            isSelected: app.selection == task.id,
            onOpen: { app.openInspector(for: task.id) },
            onToggleComplete: {
                app.selection = task.id
                app.completeSelection()
            }
        )
        .onTapGesture {
            app.selection = task.id
            app.focusedStatus = status
            if case .task = app.inspector { app.inspector = .task(task.id) }
        }
        .draggable(TaskTransfer(id: task.id.uuidString)) {
            DragPreview(title: task.title)
        }
        .contextMenu { TaskContextMenu(task: task) }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(status.label)
                .font(Theme.mono(10.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(app.focusedStatus == status ? theme.ink : theme.inkSecondary)

            Text(String(format: "%02d", tasks.count))
                .font(Theme.mono(10.5))
                .monospacedDigit()
                .foregroundStyle(theme.inkTertiary)

            Spacer(minLength: 0)

            Button {
                app.focusedStatus = status
                app.newTask()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.inkSecondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add to \(status.label)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            // Focused status gets a 2px cap rule, like a selected channel on a mixer.
            if app.focusedStatus == status {
                Rectangle().fill(theme.ink).frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.top, 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.focusedStatus = status }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("—")
                .font(Theme.mono(14))
                .foregroundStyle(theme.line)
            MicroLabel(app.isSearchActive && !app.searchText.isEmpty ? "no matches" : "empty")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

// MARK: - Drop gap

/// A thin, precise insertion target between two cards. Doubles as the card spacing.
private struct DropGap: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let status: TaskStatus
    let index: Int

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Color.clear
            if isTargeted {
                Rectangle()
                    .fill(theme.ink)
                    .frame(height: 2)
                    .padding(.horizontal, 2)
            }
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .dropDestination(for: TaskTransfer.self) { items, _ in
            guard let id = items.first?.uuid else { return false }
            try? app.taskService.move(id, to: status, index: index)
            app.selection = id
            app.focusedStatus = status
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

// MARK: - Drag payload

/// Transfers the task id only. The store is the single source of truth, so a drag
/// never carries a stale copy of the task.
struct TaskTransfer: Codable, Transferable {
    var id: String
    var uuid: UUID? { UUID(uuidString: id) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kanbanTask)
        ProxyRepresentation(exporting: \.id)
    }
}

extension UTType {
    static let kanbanTask = UTType(exportedAs: "com.kanban.task")
}

private struct DragPreview: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.mono(11, weight: .medium))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: 1))
    }
}

// MARK: - Context menu

struct TaskContextMenu: View {
    @Environment(AppModel.self) private var app
    let task: TaskItem

    var body: some View {
        Button("Open") { app.openInspector(for: task.id) }
        Button(task.isDone ? "Reopen" : "Complete") {
            app.selection = task.id
            app.completeSelection()
        }
        Divider()
        Menu("Move to") {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button(status.label.capitalized) { try? app.taskService.move(task.id, to: status, index: 0) }
                    .disabled(status == task.status)
            }
        }
        Menu("Priority") {
            ForEach(Priority.allCases.reversed(), id: \.self) { priority in
                Button(priority.longLabel.capitalized) {
                    try? app.taskService.edit(task.id) { $0.priority = priority }
                }
                .disabled(priority == task.priority)
            }
        }
        Menu("Due") {
            Button("Today") { try? app.taskService.edit(task.id) { $0.dueDate = DateInput.parse("today") } }
            Button("Tomorrow") { try? app.taskService.edit(task.id) { $0.dueDate = DateInput.parse("tomorrow") } }
            Button("Next week") { try? app.taskService.edit(task.id) { $0.dueDate = DateInput.parse("+7d") } }
            Divider()
            Button("Clear") { try? app.taskService.edit(task.id) { $0.dueDate = nil } }
        }
        Divider()
        Button("Archive") {
            app.selection = task.id
            app.archiveSelection()
        }
        Button("Delete") {
            app.selection = task.id
            app.deleteSelection()
        }
    }
}
