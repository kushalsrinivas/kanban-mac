import Foundation

/// Turns a model's proposed operation into a card the user can confirm.
///
/// This is the trust boundary between generated text and the task board: an
/// operation whose ids or values do not resolve against the local store is
/// dropped rather than guessed at.
enum LocalAgentPlan {

    /// - Parameter lookup: resolves a task id shown to the model back to a task.
    ///   Returning nil means the id was invented, so the operation is dropped.
    static func action(_ raw: LocalAgentReply.Action,
                       task lookup: (UUID) -> TaskItem?) -> AgentAction? {
        func task() -> TaskItem? {
            guard let id = raw.taskId.flatMap(UUID.init(uuidString:)) else { return nil }
            return lookup(id)
        }
        let id = UUID().uuidString

        switch raw.tool {
        case "create_task":
            guard let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let status = raw.status.flatMap(TaskStatus.parse) ?? .inbox
            if let due = raw.due, !due.isEmpty, DateInput.parse(due) == nil, !isClear(due) { return nil }
            return AgentAction(id: id, tool: raw.tool,
                               summary: "CREATE · \(title) → \(status.label)")

        case "update_task":
            guard let task = task() else { return nil }
            var changes: [String] = []
            if let v = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                changes.append("TITLE=\(brief(v))")
            }
            if let v = raw.notes { changes.append("NOTES=\(brief(v))") }
            if let v = raw.priority, Priority.parse(v) != nil { changes.append("PRIORITY=\(v.uppercased())") }
            if let v = raw.due {
                if !isClear(v), DateInput.parse(v) == nil { return nil }
                changes.append("DUE=\(v.isEmpty ? "CLEAR" : v.uppercased())")
            }
            if let v = raw.tags { changes.append("TAGS=\(v.joined(separator: ", "))") }
            guard !changes.isEmpty else { return nil }
            return AgentAction(id: id, tool: raw.tool,
                               summary: "UPDATE · \(task.title)\n" + changes.joined(separator: ", "))

        case "move_task":
            guard let task = task(), let status = raw.status.flatMap(TaskStatus.parse) else { return nil }
            return AgentAction(id: id, tool: raw.tool,
                               summary: "MOVE · \(task.title) · \(task.status.label) → \(status.label)")

        case "complete_task":
            guard let task = task() else { return nil }
            return AgentAction(id: id, tool: raw.tool, summary: "COMPLETE · \(task.title)")

        case "archive_task":
            guard let task = task() else { return nil }
            return AgentAction(id: id, tool: raw.tool, summary: "ARCHIVE · \(task.title)",
                               destructive: true)

        case "delete_task":
            guard let task = task() else { return nil }
            return AgentAction(id: id, tool: raw.tool, summary: "DELETE · \(task.title)",
                               destructive: true)

        default:
            return nil
        }
    }

    /// The model's way of saying "no due date".
    static func isClear(_ value: String) -> Bool {
        ["none", "clear", "never", "-"].contains(value.lowercased())
    }

    static func brief(_ value: String, _ limit: Int = 120) -> String {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
