import SwiftUI
import WidgetKit

// MARK: - Timeline

struct BoardEntry: TimelineEntry {
    var date: Date
    var snapshot: BoardSnapshot
    /// True when no snapshot file exists yet (app never launched).
    var isPlaceholder: Bool = false
}

/// Reads one small JSON file written by the app. No SQLite, no network, no timers —
/// a refresh is a file read and a decode, which is why this is cheap to leave on screen.
struct BoardProvider: TimelineProvider {

    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(date: Date(), snapshot: .sample, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (BoardEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BoardEntry>) -> Void) {
        // The app reloads this timeline whenever data changes, so the only scheduled
        // refresh we need is the next day boundary, to keep "today" honest.
        let entry = load()
        let nextMidnight = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func load() -> BoardEntry {
        guard let snapshot = BoardSnapshot.read() else {
            return BoardEntry(date: Date(), snapshot: .empty, isPlaceholder: true)
        }
        return BoardEntry(date: Date(), snapshot: snapshot)
    }
}

// MARK: - Widget

struct KanbanTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: KanbanWidgetKind.today, provider: BoardProvider()) { entry in
            WidgetRoot(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Open tasks and what is due, as a control panel.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct KanbanWidgetBundle: WidgetBundle {
    var body: some Widget {
        KanbanTodayWidget()
    }
}

// MARK: - Views

struct WidgetRoot: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: BoardEntry

    private var theme: Theme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        Group {
            // A live recording is the only thing more urgent than today's tasks.
            if let recording = entry.snapshot.recording {
                RecordingWidget(recording: recording, family: family)
            } else {
                switch family {
                case .systemSmall: SmallWidget(entry: entry)
                case .systemLarge: LargeWidget(entry: entry)
                default: MediumWidget(entry: entry)
                }
            }
        }
        .environment(\.theme, theme)
        .widgetURL(URL(string: entry.snapshot.recording == nil ? "kanban://open" : "kanban://record"))
        .containerBackground(for: .widget) { theme.paper }
    }
}

// MARK: Recording

/// Shown instead of the agenda while a meeting is being recorded. The elapsed time
/// uses a SwiftUI timer style, so it counts up without the app pushing updates.
private struct RecordingWidget: View {
    @Environment(\.theme) private var theme
    let recording: BoardSnapshot.Recording
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(theme.signal).frame(width: 7, height: 7)
                Text("RECORDING")
                    .font(Theme.mono(10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(theme.signal)
            }
            .padding(.bottom, 4)

            Text(recording.title.uppercased())
                .font(Theme.mono(family == .systemSmall ? 10.5 : 12, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .padding(.bottom, 5)

            Rule().padding(.bottom, 5)

            Text(recording.startedAt, style: .timer)
                .font(Theme.mono(family == .systemSmall ? 24 : 30, weight: .light))
                .monospacedDigit()
                .foregroundStyle(theme.ink)

            Spacer(minLength: 0)

            MicroLabel("open to stop")
        }
    }
}

// MARK: Small

private struct SmallWidget: View {
    @Environment(\.theme) private var theme
    let entry: BoardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel("today")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%02d", entry.snapshot.dueTodayCount + entry.snapshot.overdueCount))
                    .font(Theme.mono(30, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(entry.snapshot.overdueCount > 0 ? theme.signal : theme.ink)
                Text("TASKS")
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(theme.inkSecondary)
            }
            .padding(.bottom, 5)

            Rule()
                .padding(.bottom, 5)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(entry.snapshot.agenda.prefix(3)) { line in
                    TaskLine(line: line, size: 9.5)
                }
                if entry.snapshot.agenda.isEmpty {
                    Text(entry.isPlaceholder ? "OPEN THE APP" : "CLEAR")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(theme.inkTertiary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                MicroLabel("\(entry.snapshot.openCount) OPEN")
                Spacer()
                if entry.snapshot.agenda.count > 3 {
                    MicroLabel("+\(entry.snapshot.agenda.count - 3)")
                }
            }
        }
    }
}

// MARK: Medium

private struct MediumWidget: View {
    @Environment(\.theme) private var theme
    let entry: BoardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    MicroLabel("today")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%02d", entry.snapshot.dueTodayCount + entry.snapshot.overdueCount))
                            .font(Theme.mono(26, weight: .light))
                            .monospacedDigit()
                            .foregroundStyle(entry.snapshot.overdueCount > 0 ? theme.signal : theme.ink)
                        Text("TASKS")
                            .font(Theme.mono(9.5, weight: .medium))
                            .tracking(0.9)
                            .foregroundStyle(theme.inkSecondary)
                    }
                }

                Spacer()

                HStack(spacing: 14) {
                    stat("OPEN", entry.snapshot.openCount, tint: nil)
                    stat("ACTIVE", entry.snapshot.activeCount, tint: nil)
                    stat("LATE", entry.snapshot.overdueCount,
                         tint: entry.snapshot.overdueCount > 0 ? theme.signal : nil)
                }
            }
            .padding(.bottom, 6)

            Rule().padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.snapshot.agenda.prefix(4)) { line in
                    TaskLine(line: line, size: 10.5, showMeta: true)
                }
                if entry.snapshot.agenda.isEmpty {
                    Text(entry.isPlaceholder ? "OPEN THE APP TO SYNC" : "NOTHING SCHEDULED")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(theme.inkTertiary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                if entry.snapshot.agenda.count > 4 {
                    MicroLabel("+ \(entry.snapshot.agenda.count - 4) MORE")
                }
                Spacer()
                if entry.snapshot.suggestedCount > 0 {
                    MicroLabel("\(entry.snapshot.suggestedCount) SUGGESTED", color: theme.ink)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: Int, tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel(label)
            Text(String(format: "%02d", value))
                .font(Theme.mono(15, weight: .light))
                .monospacedDigit()
                .foregroundStyle(tint ?? theme.ink)
        }
    }
}

// MARK: Large

private struct LargeWidget: View {
    @Environment(\.theme) private var theme
    let entry: BoardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("TASKS")
                    .font(Theme.display(17, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer()
                Text("\(entry.snapshot.openCount) OPEN")
                    .font(Theme.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(theme.inkSecondary)
            }
            .padding(.bottom, 7)

            Rule().padding(.bottom, 7)

            HStack(spacing: 0) {
                block("DUE TODAY", entry.snapshot.dueTodayCount, nil)
                VRule().frame(height: 30)
                block("ACTIVE", entry.snapshot.activeCount, nil)
                VRule().frame(height: 30)
                block("OVERDUE", entry.snapshot.overdueCount,
                      entry.snapshot.overdueCount > 0 ? theme.signal : nil)
                VRule().frame(height: 30)
                block("DONE", entry.snapshot.doneTodayCount, nil)
            }
            .padding(.bottom, 7)

            Rule().padding(.bottom, 7)

            MicroLabel("agenda")
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(entry.snapshot.agenda.prefix(8)) { line in
                    TaskLine(line: line, size: 11, showMeta: true)
                }
                if entry.snapshot.agenda.isEmpty {
                    Text(entry.isPlaceholder ? "OPEN THE APP TO SYNC" : "NOTHING SCHEDULED")
                        .font(Theme.mono(11))
                        .foregroundStyle(theme.inkTertiary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func block(_ label: String, _ value: Int, _ tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel(label)
            Text(String(format: "%02d", value))
                .font(Theme.mono(19, weight: .light))
                .monospacedDigit()
                .foregroundStyle(tint ?? theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Shared row

private struct TaskLine: View {
    @Environment(\.theme) private var theme
    @Environment(\.widgetFamily) private var family
    let line: BoardSnapshot.Line
    var size: CGFloat = 10.5
    var showMeta: Bool = false

    var body: some View {
        // Small widgets only support a single whole-widget tap target, so rows are
        // plain there and deep-linked on the larger families.
        if family == .systemSmall {
            row
        } else {
            Link(destination: URL(string: "kanban://task/\(line.id.uuidString)")!) { row }
        }
    }

    private var row: some View {
        HStack(spacing: 5) {
            Text("→")
                .font(Theme.mono(size - 1))
                .foregroundStyle(line.isOverdue ? theme.signal : theme.inkTertiary)
            Text(line.title)
                .font(Theme.mono(size))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showMeta {
                if let due = line.dueDate {
                    Text(DateInput.shortLabel(due))
                        .font(Theme.mono(size - 1.5))
                        .foregroundStyle(line.isOverdue ? theme.signal : theme.inkTertiary)
                } else if line.status == .inProgress {
                    Text("ACTIVE")
                        .font(Theme.mono(size - 1.5))
                        .foregroundStyle(theme.inkTertiary)
                }
            }
        }
    }
}

// MARK: - Sample data for the gallery

extension BoardSnapshot {
    static var sample: BoardSnapshot {
        BoardSnapshot(
            generatedAt: Date(),
            openCount: 12,
            activeCount: 3,
            dueTodayCount: 3,
            overdueCount: 1,
            doneTodayCount: 2,
            agenda: [
                .init(id: UUID(), title: "Finish CAD model", priority: .high, status: .inProgress,
                      dueDate: Date(), isOverdue: false),
                .init(id: UUID(), title: "Deploy API", priority: .urgent, status: .todo,
                      dueDate: Date(), isOverdue: true),
                .init(id: UUID(), title: "Call client", priority: .medium, status: .todo,
                      dueDate: Date(), isOverdue: false),
                .init(id: UUID(), title: "Review pull request", priority: .medium, status: .todo,
                      dueDate: nil, isOverdue: false)
            ]
        )
    }
}
