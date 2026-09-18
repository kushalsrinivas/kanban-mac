import Foundation

/// Inline syntax for the quick-add field, so a task can be fully specified in one line
/// without leaving the keyboard:
///
///     Fix auth bug !high #backend @friday >todo
///
///   !low !med !high !urg   priority
///   #tag                   tag (repeatable)
///   @today @fri @18sep     due date
///   >todo >active          destination column
///
/// Anything unrecognised stays in the title, so typing plain text always works.
enum QuickParse {

    struct Result {
        var title: String
        var priority: Priority?
        var tags: [String] = []
        var due: Date?
        var status: TaskStatus?
    }

    static func parse(_ input: String, now: Date = Date()) -> Result {
        var titleWords: [String] = []
        var result = Result(title: "")

        for token in input.split(separator: " ", omittingEmptySubsequences: true) {
            let word = String(token)
            guard let marker = word.first, word.count > 1 else {
                titleWords.append(word)
                continue
            }
            let value = String(word.dropFirst())
            switch marker {
            case "!":
                if let p = Priority.parse(value) { result.priority = p } else { titleWords.append(word) }
            case "#":
                let tag = value.lowercased()
                if !tag.isEmpty && !result.tags.contains(tag) { result.tags.append(tag) }
            case "@":
                if let d = DateInput.parse(value.replacingOccurrences(of: "_", with: " "), now: now) {
                    result.due = d
                } else {
                    titleWords.append(word)
                }
            case ">":
                if let c = TaskStatus.parse(value) { result.status = c } else { titleWords.append(word) }
            default:
                titleWords.append(word)
            }
        }

        result.title = titleWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// A compact preview of what will be created, shown beside the field as you type.
    static func hint(for input: String, defaultPriority: Priority, defaultStatus: TaskStatus) -> String {
        let r = parse(input)
        var parts = [(r.status ?? defaultStatus).label, (r.priority ?? defaultPriority).label]
        if let due = r.due { parts.append(DateInput.shortLabel(due)) }
        parts.append(contentsOf: r.tags.map { "#\($0)" })
        return parts.joined(separator: " · ")
    }
}
