import Foundation

/// Turns a model's proposed operation into one the user can confirm.
///
/// This is the trust boundary between generated text and the task board: an
/// operation whose ids or values do not resolve against the local store is
/// dropped rather than guessed at.
enum LocalAgentPlan {

    /// The single validated form both planners produce. Execution lives in
    /// `AgentSession`, so a model proposal and a typed command cannot diverge.
    static func operation(_ raw: LocalAgentReply.Action,
                          task lookup: (UUID) -> TaskItem?) -> AgentOperation? {
        func task() -> TaskItem? {
            guard let id = raw.taskId.flatMap(UUID.init(uuidString:)) else { return nil }
            return lookup(id)
        }

        switch raw.tool {
        case "create_task":
            guard let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let status = raw.status.flatMap(TaskStatus.parse)
            if let due = raw.due, !due.isEmpty, DateInput.parse(due) == nil, !isClear(due) {
                return nil
            }
            return .create(title: title, notes: raw.notes, due: raw.due,
                           priority: raw.priority.flatMap(Priority.parse),
                           status: status, tags: raw.tags ?? [])

        case "update_task":
            guard let task = task() else { return nil }
            var changes = false
            var title: String?
            if let value = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                title = value
                changes = true
            }
            if raw.notes != nil { changes = true }
            let priority = raw.priority.flatMap(Priority.parse)
            if priority != nil { changes = true }
            if let due = raw.due {
                if !isClear(due), DateInput.parse(due) == nil { return nil }
                changes = true
            }
            let tags = raw.tags.map(TaskService.normalise)
            if tags != nil { changes = true }
            guard changes else { return nil }
            return .update(task, title: title, notes: raw.notes,
                           priority: priority, due: raw.due, tags: tags)

        case "move_task":
            guard let task = task(), let status = raw.status.flatMap(TaskStatus.parse) else { return nil }
            return .move(task, to: status)

        case "complete_task":
            guard let task = task() else { return nil }
            return .complete(task)

        case "archive_task":
            guard let task = task() else { return nil }
            return .archive(task)

        case "delete_task":
            guard let task = task() else { return nil }
            return .delete(task)

        default:
            return nil
        }
    }

    /// Kept for the model path's existing call sites and tests.
    static func action(_ raw: LocalAgentReply.Action,
                       task lookup: (UUID) -> TaskItem?) -> AgentAction? {
        operation(raw, task: lookup)?.action
    }

    /// The model's way of saying "no due date".
    static func isClear(_ value: String) -> Bool {
        ["none", "clear", "never", "-"].contains(value.lowercased())
    }

    static func brief(_ value: String, _ limit: Int = 120) -> String {
        AgentText.brief(value, limit)
    }
}
