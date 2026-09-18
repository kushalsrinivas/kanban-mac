import Foundation

/// Small, predictable date parser. Deliberately not a natural-language engine —
/// it handles the handful of forms that are actually typed into a todo box.
public enum DateInput {

    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        // Relative keywords
        switch s {
        case "today", "tod": return endOfDay(now, calendar)
        case "tomorrow", "tmr", "tom": return endOfDay(calendar.date(byAdding: .day, value: 1, to: now)!, calendar)
        case "yesterday": return endOfDay(calendar.date(byAdding: .day, value: -1, to: now)!, calendar)
        case "next week", "nextweek": return endOfDay(calendar.date(byAdding: .day, value: 7, to: now)!, calendar)
        case "none", "never", "clear", "-": return nil
        default: break
        }

        // +3d / +2w / 3d
        if let m = matchOffset(s), let d = calendar.date(byAdding: m.unit, value: m.value, to: now) {
            return endOfDay(d, calendar)
        }

        // Weekday names -> the next occurrence
        if let weekday = weekdayIndex(s) {
            var comps = DateComponents()
            comps.weekday = weekday
            if let next = calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) {
                return endOfDay(next, calendar)
            }
        }

        // ISO-8601 (what the agent/API will send)
        if let d = isoFormatter.date(from: raw) { return d }
        if let d = isoPlain.date(from: raw) { return d }
        if let d = isoDateOnly.date(from: s) { return endOfDay(d, calendar) }

        // Epoch seconds
        if let secs = Double(s), secs > 100_000_000 { return Date(timeIntervalSince1970: secs) }

        // 18 sep / sep 18 / 18/09 / 18-09-2026
        for fmt in looseFormats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            df.calendar = calendar
            if var d = df.date(from: s) {
                // Year-less formats default to 1970; pull them into the current year (or the next).
                let year = calendar.component(.year, from: d)
                if year < 2000 {
                    var c = calendar.dateComponents([.month, .day], from: d)
                    c.year = calendar.component(.year, from: now)
                    guard let candidate = calendar.date(from: c) else { continue }
                    d = candidate < calendar.startOfDay(for: now)
                        ? calendar.date(byAdding: .year, value: 1, to: candidate)!
                        : candidate
                }
                return endOfDay(d, calendar)
            }
        }
        return nil
    }

    /// Serialises for the API. Always ISO-8601 with timezone.
    public static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    // MARK: Display

    /// "TODAY" / "TMRW" / "18 SEP" / "18 SEP 27" — the compact metadata form used on cards.
    public static func shortLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return "TMRW" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "YSTDY" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "d MMM" : "d MMM yy"
        return df.string(from: date).uppercased()
    }

    // MARK: Internals

    private static func endOfDay(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date) ?? date
    }

    private static func matchOffset(_ s: String) -> (value: Int, unit: Calendar.Component)? {
        var body = s
        if body.hasPrefix("+") { body.removeFirst() }
        guard let last = body.last, let value = Int(body.dropLast()) else { return nil }
        switch last {
        case "d": return (value, .day)
        case "w": return (value, .weekOfYear)
        case "m": return (value, .month)
        default: return nil
        }
    }

    private static func weekdayIndex(_ s: String) -> Int? {
        let names = ["sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
                     "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thurs": 5,
                     "friday": 6, "fri": 6, "saturday": 7, "sat": 7]
        return names[s]
    }

    private static let looseFormats = ["d MMM yyyy", "d MMM", "MMM d", "d/M/yyyy", "d/M", "d-M-yyyy", "yyyy/M/d"]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Tolerant ISO parsing for API input (with or without fractional seconds, or date-only).
public extension DateInput {
    static func parseAPI(_ raw: String) -> Date? { parse(raw) }
}
