import Foundation

/// Widget kind identifiers, shared so the app reloads exactly the timelines it owns.
public enum KanbanWidgetKind {
    public static let today = "KanbanTodayWidget"
}

/// What the widget and the menu bar read.
///
/// Small, flat and cheap to decode — the widget never opens SQLite, so a timeline
/// refresh is one ~1 KB file read.
public struct BoardSnapshot: Codable, Equatable, Sendable {

    public struct Line: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var priority: Priority
        public var status: TaskStatus
        public var dueDate: Date?
        public var isOverdue: Bool

        public init(id: UUID, title: String, priority: Priority, status: TaskStatus,
                    dueDate: Date?, isOverdue: Bool) {
            self.id = id
            self.title = title
            self.priority = priority
            self.status = status
            self.dueDate = dueDate
            self.isOverdue = isOverdue
        }
    }

    /// Present only while a recording is running, so the widget can show the clock
    /// without the app pushing an update every second.
    public struct Recording: Codable, Equatable, Sendable {
        public var title: String
        public var startedAt: Date

        public init(title: String, startedAt: Date) {
            self.title = title
            self.startedAt = startedAt
        }
    }

    public var generatedAt: Date
    public var openCount: Int
    public var activeCount: Int
    public var dueTodayCount: Int
    public var overdueCount: Int
    public var doneTodayCount: Int
    public var suggestedCount: Int
    public var agenda: [Line]
    public var recording: Recording?

    public init(
        generatedAt: Date = Date(),
        openCount: Int = 0,
        activeCount: Int = 0,
        dueTodayCount: Int = 0,
        overdueCount: Int = 0,
        doneTodayCount: Int = 0,
        suggestedCount: Int = 0,
        agenda: [Line] = [],
        recording: Recording? = nil
    ) {
        self.generatedAt = generatedAt
        self.openCount = openCount
        self.activeCount = activeCount
        self.dueTodayCount = dueTodayCount
        self.overdueCount = overdueCount
        self.doneTodayCount = doneTodayCount
        self.suggestedCount = suggestedCount
        self.agenda = agenda
        self.recording = recording
    }

    public static let empty = BoardSnapshot()

    // MARK: Build

    public static func make(from tasks: [TaskItem], recording: Recording? = nil,
                            suggestedCount: Int = 0, now: Date = Date(), limit: Int = 8) -> BoardSnapshot {
        let cal = Calendar.current
        let open = tasks.filter(\.isOpen)
        let pressing = open
            .filter { $0.dueDate != nil || $0.status == .inProgress || $0.priority >= .high }
            .agendaSorted(now: now)
        // Never show a blank widget while work exists.
        let lines = (pressing.isEmpty ? open.agendaSorted(now: now) : pressing).prefix(limit).map {
            Line(id: $0.id, title: $0.title, priority: $0.priority, status: $0.status,
                 dueDate: $0.dueDate, isOverdue: $0.isOverdue(now: now))
        }
        return BoardSnapshot(
            generatedAt: now,
            openCount: open.count,
            activeCount: open.filter { $0.status == .inProgress }.count,
            dueTodayCount: open.filter { $0.isDueToday(now: now, calendar: cal) }.count,
            overdueCount: open.filter { $0.isOverdue(now: now, calendar: cal) }.count,
            doneTodayCount: tasks.filter {
                guard let c = $0.completedAt, !$0.isArchived else { return false }
                return cal.isDate(c, inSameDayAs: now)
            }.count,
            suggestedCount: suggestedCount,
            agenda: Array(lines),
            recording: recording
        )
    }

    // MARK: Disk

    private static let coder: (JSONEncoder, JSONDecoder) = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return (e, d)
    }()

    /// Atomic write, so a widget read never sees a half-written file.
    public func write(to url: URL = KanbanPaths.snapshotURL) {
        KanbanPaths.ensureSupportDirectory()
        guard let data = try? BoardSnapshot.coder.0.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL = KanbanPaths.snapshotURL) -> BoardSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? coder.1.decode(BoardSnapshot.self, from: data)
    }
}
