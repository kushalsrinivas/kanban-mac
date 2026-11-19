import Foundation

// MARK: - Free time

public enum FreeTimeFinder {
    /// Finds open working-hour slots around a set of already-committed intervals.
    /// Used by the brief to answer "when could this move to?".
    public static func slots(duration: TimeInterval, after: Date, days: Int = 7,
                             busy: [DateInterval], limit: Int = 5,
                             calendar: Calendar = .current) -> [DateInterval] {
        guard duration > 0, limit > 0 else { return [] }
        var out: [DateInterval] = []
        var day = calendar.startOfDay(for: after)
        let end = calendar.date(byAdding: .day, value: max(1, min(days, 30)), to: day) ?? day
        while day < end && out.count < limit {
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 {
                var cursor = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
                if cursor < after { cursor = after }
                let close = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
                while cursor.addingTimeInterval(duration) <= close && out.count < limit {
                    let candidateEnd = cursor.addingTimeInterval(duration)
                    if let conflict = busy.first(where: {
                        $0.start < candidateEnd && cursor < $0.end
                    }) {
                        cursor = max(conflict.end, cursor.addingTimeInterval(1800))
                    } else {
                        out.append(DateInterval(start: cursor, end: candidateEnd))
                        cursor = candidateEnd.addingTimeInterval(1800)
                    }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
        }
        return out
    }
}
