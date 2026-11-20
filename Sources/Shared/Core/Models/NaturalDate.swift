import Foundation

/// Pulls a due date and time out of ordinary task phrasing.
///
/// The quick-add field and the agent both accept "call Sarah tomorrow at 5pm"
/// without requiring `@tomorrow` markers. Whatever is removed from the title is
/// returned as a real Date, including the time of day, so a reminder notification
/// can fire at 17:00 instead of at the end of the day.
enum NaturalDate {

    struct Extracted: Equatable {
        var text: String
        var due: Date
    }

    private struct Match {
        var range: Range<String.Index>
        var day: String?
        var hour: Int?
        var minute: Int?
        var meridiem: String?
        var relative: (Int, Calendar.Component)?
    }

    private struct Pattern {
        var regex: NSRegularExpression
        var dayGroup: Int?
        var hourGroup: Int?
        var minuteGroup: Int?
        var meridiemGroup: Int?
        var relativeGroup: Int?
        var unitGroup: Int?
    }

    private static let patterns: [Pattern] = {
        func make(_ source: String, day: Int? = nil, hour: Int? = nil,
                  minute: Int? = nil, meridiem: Int? = nil,
                  relative: Int? = nil, unit: Int? = nil) -> Pattern? {
            guard let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) else {
                return nil
            }
            return Pattern(regex: regex, dayGroup: day, hourGroup: hour,
                           minuteGroup: minute, meridiemGroup: meridiem,
                           relativeGroup: relative, unitGroup: unit)
        }

        return [
            // "by friday", "due tomorrow at 5pm", "on 21 nov"
            make(#"\b(?:by|before|due(?:\s+on)?|on)\s+(today|tomorrow|tonight|next\s+week|next\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|this\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\d{4}-\d{2}-\d{2}|\d{1,2}\s+[a-z]{3,9}|[a-z]{3,9}\s+\d{1,2})(?!['’]s)(?:\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?"#,
                 day: 1, hour: 2, minute: 3, meridiem: 4),
            // "tomorrow at 5pm", "on friday" without a preposition
            make(#"\b(today|tomorrow|tonight|next\s+week|next\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|this\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))(?!['’]s)(?:\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?"#,
                 day: 1, hour: 2, minute: 3, meridiem: 4),
            // "in 30 minutes", "in 2 hours"
            make(#"\bin\s+(\d+)\s+(minutes?|hours?|days?|weeks?)\b"#,
                 relative: 1, unit: 2),
            // "at 5pm" at the end of a phrase
            make(#"\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#,
                 hour: 1, minute: 2, meridiem: 3),
            // A bare "at 5" only when it ends the sentence, so "look at 5 files" is safe.
            make(#"\bat\s+(\d{1,2})(?::(\d{2}))?(?=\s*$)"#,
                 hour: 1, minute: 2),
        ].compactMap { $0 }
    }()

    static func extract(from text: String, now: Date = Date(),
                        calendar: Calendar = .current) -> Extracted? {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: text, range: full),
                  let range = Range(match.range, in: text) else { continue }
            // Quick-add markers such as @tomorrow are parsed by QuickParse itself.
            if range.lowerBound > text.startIndex {
                let previous = text[text.index(before: range.lowerBound)]
                if "@!#>".contains(previous) { continue }
            }

            func group(_ index: Int?) -> String? {
                guard let index, index < match.numberOfRanges,
                      let value = Range(match.range(at: index), in: text) else { return nil }
                let trimmed = String(text[value]).trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }

            let day = group(pattern.dayGroup)
            let hour = group(pattern.hourGroup).flatMap(Int.init)
            let minute = group(pattern.minuteGroup).flatMap(Int.init)
            let meridiem = group(pattern.meridiemGroup)?.lowercased()
            var relative: (Int, Calendar.Component)?
            if let amount = group(pattern.relativeGroup).flatMap(Int.init),
               let unit = group(pattern.unitGroup)?.lowercased() {
                let component: Calendar.Component
                switch unit {
                case "minute", "minutes": component = .minute
                case "hour", "hours": component = .hour
                case "day", "days": component = .day
                default: component = .weekOfYear
                }
                relative = (amount, component)
            }

            guard let due = makeDate(day: day, hour: hour, minute: minute,
                                     meridiem: meridiem, relative: relative,
                                     now: now, calendar: calendar) else { continue }

            var remaining = text
            remaining.removeSubrange(range)
            remaining = remaining
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
            guard !remaining.isEmpty else { continue }
            return Extracted(text: remaining, due: due)
        }
        return nil
    }

    private static func makeDate(day: String?, hour: Int?, minute: Int?,
                                 meridiem: String?, relative: (Int, Calendar.Component)?,
                                 now: Date, calendar: Calendar) -> Date? {
        if let relative {
            return calendar.date(byAdding: relative.1, value: relative.0, to: now)
        }

        var base: Date
        let dayLabel = day?.lowercased()
        if let dayLabel {
            var phrase = dayLabel
            if phrase == "tonight" {
                phrase = "today"
            } else if phrase.hasPrefix("next "), phrase != "next week" {
                phrase = String(phrase.dropFirst(5))
            } else if phrase.hasPrefix("this ") {
                phrase = String(phrase.dropFirst(5))
            }
            guard let parsed = DateInput.parse(phrase, now: now, calendar: calendar) else {
                return nil
            }
            base = parsed
        } else {
            base = now
        }

        if let hour {
            var resolved = hour
            switch meridiem {
            case "am": resolved = hour % 12
            case "pm": resolved = (hour % 12) + 12
            case .none:
                // "at 5" after lunch, "at 9" in the morning.
                if hour > 0 && hour < 7 { resolved = hour + 12 }
            default: break
            }
            guard let adjusted = calendar.date(bySettingHour: resolved,
                                               minute: minute ?? 0, second: 0, of: base)
            else { return nil }
            base = adjusted
        } else if dayLabel == "tonight" {
            base = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: base) ?? base
        }

        // A time-only request that has passed means the next occurrence.
        if day == nil, base <= now {
            base = calendar.date(byAdding: .day, value: 1, to: base) ?? base
        }
        // "remind me today" after the day's default time should still be useful.
        if let dayLabel, ["today", "tonight"].contains(dayLabel), base <= now {
            base = now.addingTimeInterval(3_600)
        }
        return base
    }
}
