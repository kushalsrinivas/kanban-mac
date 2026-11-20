import Foundation

/// The policy behind an inactivity nudge. Kept independent of UserDefaults so it can
/// be unit-tested and reused by the notification bridge.
public struct StaleTaskPolicy: Equatable, Sendable {
    public var enabled: Bool
    public var urgentHours: Double
    public var highHours: Double
    public var mediumHours: Double
    public var lowHours: Double
    public var inboxFactor: Double
    public var inProgressFactor: Double
    public var quietHoursEnabled: Bool
    public var quietStartHour: Int
    public var quietEndHour: Int
    public var cooldownHours: Double
    public var maxPerDay: Int
    public var minimumSpacingMinutes: Int
    public var maxScheduled: Int

    public init(
        enabled: Bool = true,
        urgentHours: Double = 4,
        highHours: Double = 24,
        mediumHours: Double = 72,
        lowHours: Double = 168,
        inboxFactor: Double = 1.5,
        inProgressFactor: Double = 0.75,
        quietHoursEnabled: Bool = true,
        quietStartHour: Int = 22,
        quietEndHour: Int = 8,
        cooldownHours: Double = 12,
        maxPerDay: Int = 2,
        minimumSpacingMinutes: Int = 30,
        maxScheduled: Int = 8
    ) {
        self.enabled = enabled
        self.urgentHours = urgentHours
        self.highHours = highHours
        self.mediumHours = mediumHours
        self.lowHours = lowHours
        self.inboxFactor = inboxFactor
        self.inProgressFactor = inProgressFactor
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartHour = quietStartHour
        self.quietEndHour = quietEndHour
        self.cooldownHours = cooldownHours
        self.maxPerDay = maxPerDay
        self.minimumSpacingMinutes = minimumSpacingMinutes
        self.maxScheduled = maxScheduled
    }

    public static let standard = StaleTaskPolicy()

    /// Base priority threshold, shortened for work already in progress and lengthened
    /// for a task still sitting in the inbox.
    public func thresholdHours(for task: TaskItem) -> Double {
        let base: Double
        switch task.priority {
        case .urgent: base = urgentHours
        case .high: base = highHours
        case .medium: base = mediumHours
        case .low: base = lowHours
        }
        let factor: Double
        switch task.status {
        case .inProgress: factor = inProgressFactor
        case .inbox: factor = inboxFactor
        default: factor = 1
        }
        return max(0.25, base * factor)
    }

    public func threshold(for task: TaskItem) -> TimeInterval {
        thresholdHours(for: task) * 3_600
    }

    /// Quiet hours may cross midnight. A notification due at 02:00 waits until 08:00.
    public func nextAllowed(_ date: Date, now: Date = Date(),
                            calendar: Calendar = .current) -> Date {
        guard quietHoursEnabled else { return max(date, now) }
        var candidate = max(date, now)
        let start = ((quietStartHour % 24) + 24) % 24
        let end = ((quietEndHour % 24) + 24) % 24
        guard start != end else { return candidate }

        func hour(_ value: Date) -> Int { calendar.component(.hour, from: value) }
        func isQuiet(_ value: Date) -> Bool {
            let h = hour(value)
            return start < end ? (h >= start && h < end) : (h >= start || h < end)
        }
        if !isQuiet(candidate) { return candidate }

        let day = calendar.startOfDay(for: candidate)
        var endToday = calendar.date(bySettingHour: end, minute: 0, second: 0, of: day) ?? candidate
        if endToday <= candidate {
            endToday = calendar.date(byAdding: .day, value: 1, to: endToday) ?? endToday
        }
        candidate = endToday
        // A DST transition or a bad clock must not leave us in the quiet window.
        if isQuiet(candidate) {
            candidate = calendar.date(byAdding: .hour, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }
}

public struct StaleTaskCandidate: Identifiable, Equatable, Sendable {
    public var task: TaskItem
    public var fireAt: Date
    public var inactivity: TimeInterval
    public var threshold: TimeInterval
    public var reason: String

    public var id: UUID { task.id }

    public init(task: TaskItem, fireAt: Date, inactivity: TimeInterval,
                threshold: TimeInterval, reason: String) {
        self.task = task
        self.fireAt = fireAt
        self.inactivity = inactivity
        self.threshold = threshold
        self.reason = reason
    }
}

public enum StaleTaskEngine {
    /// Returns open tasks that are stale now or will become stale. Future candidates
    /// are included so the notification daemon can fire while the app is closed.
    public static func candidates(tasks: [TaskItem], now: Date = Date(),
                                  policy: StaleTaskPolicy = .standard,
                                  calendar: Calendar = .current) -> [StaleTaskCandidate] {
        guard policy.enabled else { return [] }
        var out: [StaleTaskCandidate] = []

        for task in tasks where task.isOpen {
            let anchor = task.activityAnchor
            let threshold = policy.threshold(for: task)
            let naturalFire = anchor.addingTimeInterval(threshold)
            let notice = task.lastStaleNoticeAt

            // Already nudged since the last real activity: no second notice.
            if let notice, notice >= anchor { continue }

            var fireAt = naturalFire
            if let notice {
                // Cooldown is measured from the previous nudge when the task was
                // touched again before it became stale a second time.
                fireAt = max(fireAt, notice.addingTimeInterval(policy.cooldownHours * 3_600))
            }
            fireAt = policy.nextAllowed(fireAt, now: now, calendar: calendar)
            let inactivity = max(0, now.timeIntervalSince(anchor))
            out.append(StaleTaskCandidate(
                task: task,
                fireAt: fireAt,
                inactivity: inactivity,
                threshold: threshold,
                reason: reason(task: task, threshold: threshold, inactivity: inactivity)))
        }

        // The most urgent task gets the next slot; a task already past its threshold
        // sorts before one that only becomes stale later.
        out.sort { a, b in
            let aDue = a.fireAt <= now, bDue = b.fireAt <= now
            if aDue != bDue { return aDue }
            if a.task.priority != b.task.priority {
                return a.task.priority.rawValue > b.task.priority.rawValue
            }
            if a.fireAt != b.fireAt { return a.fireAt < b.fireAt }
            return a.task.title.localizedCaseInsensitiveCompare(b.task.title) == .orderedAscending
        }
        return out
    }

    public static func reason(task: TaskItem, threshold: TimeInterval,
                              inactivity: TimeInterval = 0) -> String {
        if inactivity >= threshold {
            return "\(task.status.label) · \(task.priority.longLabel) · no progress for \(durationLabel(inactivity))"
        }
        return "\(task.status.label) · \(task.priority.longLabel) · no progress for at least \(durationLabel(threshold))"
    }

    public static func durationLabel(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3_600)
        if hours < 24 {
            return "\(max(1, hours)) hour\(hours == 1 ? "" : "s")"
        }
        let days = hours / 24
        let remainder = hours % 24
        if remainder == 0 { return "\(days) day\(days == 1 ? "" : "s")" }
        return "\(days)d \(remainder)h"
    }
}
