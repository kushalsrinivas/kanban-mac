import Foundation

public enum ScheduledMeetingParseResult: Equatable, Sendable {
    case draft(ScheduledMeetingDraft)
    case missingDateTime
    case inThePast
}

/// Small, predictable scheduler grammar. It handles the forms people actually type
/// in the console:
///
///     schedule a meeting about onboarding with Sarah tomorrow at 2pm for 45 minutes
///     book a meeting called Design review on friday at 10:30
///
/// It deliberately does not guess. A missing day or time produces a question rather
/// than an event at an arbitrary hour.
public enum ScheduledMeetingParser {

    public static func parse(_ text: String, now: Date = Date(),
                             calendar: Calendar = .current) -> ScheduledMeetingParseResult {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = original.lowercased()

        guard let day = day(in: lower, now: now, calendar: calendar) else {
            return .missingDateTime
        }
        guard let (hour, minute) = time(in: lower) else {
            return .missingDateTime
        }
        guard let startsAt = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                           of: calendar.startOfDay(for: day)) else {
            return .missingDateTime
        }
        if startsAt <= now { return .inThePast }

        let minutes = duration(in: lower)
        let endsAt = startsAt.addingTimeInterval(TimeInterval(minutes * 60))
        let attendees = attendees(in: original)
        let title = title(in: original, attendees: attendees)

        return .draft(ScheduledMeetingDraft(
            title: title, startsAt: startsAt, endsAt: endsAt, participants: attendees))
    }

    // MARK: Day

    private static func day(in text: String, now: Date, calendar: Calendar) -> Date? {
        if let iso = firstGroup(#"\b(\d{4}-\d{2}-\d{2})\b"#, text),
           let date = DateInput.parse(iso, now: now, calendar: calendar) {
            return calendar.startOfDay(for: date)
        }
        if text.contains("tomorrow") || text.contains("tmrw") || text.contains("tmr") {
            return DateInput.parse("tomorrow", now: now, calendar: calendar)
                .map(calendar.startOfDay(for:))
        }
        if text.contains("today") {
            return calendar.startOfDay(for: now)
        }
        if let weekday = firstGroup(
            #"\b(?:next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            text
        ) {
            return DateInput.parse(weekday, now: now, calendar: calendar)
                .map(calendar.startOfDay(for:))
        }
        if let phrase = firstGroup(
            #"\b(\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*)\b"#,
            text
        ) ?? firstGroup(
            #"\b((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2})\b"#,
            text
        ) {
            return DateInput.parse(phrase, now: now, calendar: calendar)
                .map(calendar.startOfDay(for:))
        }
        return nil
    }

    // MARK: Time

    private static func time(in text: String) -> (hour: Int, minute: Int)? {
        if let groups = groups(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, text) {
            var hour = Int(groups[1]) ?? 0
            let minute = Int(groups[2]) ?? 0
            let meridiem = groups[3]
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return (hour, minute)
        }
        if let groups = groups(#"\bat\s+(\d{1,2})(?::(\d{2}))?\b"#, text) {
            let hour = Int(groups[1]) ?? 0
            let minute = Int(groups[2]) ?? 0
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return (hour, minute)
        }
        if let groups = groups(#"\b(\d{1,2}):(\d{2})\b"#, text) {
            let hour = Int(groups[1]) ?? 0
            let minute = Int(groups[2]) ?? 0
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return (hour, minute)
        }
        return nil
    }

    // MARK: Duration

    private static func duration(in text: String) -> Int {
        if text.contains("half an hour") || text.contains("half hour") { return 30 }
        if text.contains("an hour") || text.contains("one hour") { return 60 }
        if let groups = groups(#"\b(\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?)\b"#, text),
           let value = Double(groups[1]) {
            let unit = groups[2]
            let minutes = unit.hasPrefix("h") || unit.hasPrefix("hr") ? value * 60 : value
            return max(15, min(8 * 60, Int(minutes.rounded())))
        }
        return 30
    }

    // MARK: Title and attendees

    private static func title(in text: String, attendees: [String]) -> String {
        if let subject = firstGroup(
            #"(?i)\b(?:called|titled|about)\s+(.+?)(?=\s+(?:with|tomorrow|tmrw|today|on|at|for|next|this|in)\b|$)"#,
            text
        ) {
            let cleaned = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return capitalise(cleaned) }
        }
        if !attendees.isEmpty { return "Meeting with \(attendees.joined(separator: ", "))" }
        return "Meeting"
    }

    private static func attendees(in text: String) -> [String] {
        guard let captured = firstGroup(
            #"(?i)\bwith\s+(.+?)(?=\s+(?:tomorrow|tmrw|today|on|at|for|about|next|this|in)\b|$)"#,
            text
        ) else { return [] }
        let separators = CharacterSet(charactersIn: ",&")
        var names = captured
            .components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && $0.lowercased() != "me" }
        var seen = Set<String>()
        names = names.filter { seen.insert($0.lowercased()).inserted }
        return names
    }

    private static func capitalise(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Regex

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func firstGroup(_ pattern: String, _ text: String) -> String? {
        guard let groups = groups(pattern, text), groups.count > 1 else { return nil }
        let value = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
