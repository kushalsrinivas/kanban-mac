import Foundation

/// The one place a validated agent operation changes the board.
///
/// The session calls this after EXECUTE, and tests call the same entry point, so
/// what is tested is the code that actually runs.
public enum AgentExecutor {

    @MainActor
    public static func apply(_ operation: AgentOperation, store: LocalStore,
                             syncEnabled: Bool,
                             gmail: GmailActionExecutor? = nil) throws {
        let service = TaskService(store: store, syncEnabled: syncEnabled)
        switch operation.kind {
        case .createTask:
            guard let title = operation.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { throw APIError.badRequest("title is required") }
            _ = try service.create(CreateTaskBody(
                title: title,
                notes: operation.notes,
                status: operation.status?.rawValue,
                priority: operation.priority?.longLabel.lowercased(),
                due: operation.due,
                tags: operation.tags ?? [],
                source: TaskSource.agent.rawValue))

        case .updateTask:
            guard let taskID = operation.taskID else {
                throw APIError.badRequest("task id is required")
            }
            _ = try service.edit(taskID) { task in
                if let title = operation.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty {
                    task.title = title
                }
                if let notes = operation.notes { task.notes = notes }
                if let priority = operation.priority { task.priority = priority }
                if let due = operation.due {
                    task.dueDate = LocalAgentPlanClear.isClear(due) ? nil : DateInput.parse(due)
                }
                if let tags = operation.tags { task.tags = TaskService.normalise(tags) }
            }

        case .moveTask:
            guard let taskID = operation.taskID, let status = operation.status else {
                throw APIError.badRequest("task id and status are required")
            }
            _ = try service.move(taskID, to: status, index: 0)

        case .completeTask:
            guard let taskID = operation.taskID else { throw APIError.badRequest("task id is required") }
            _ = try service.complete(taskID)

        case .archiveTask:
            guard let taskID = operation.taskID else { throw APIError.badRequest("task id is required") }
            _ = try service.delete(taskID, hard: false)

        case .deleteTask:
            guard let taskID = operation.taskID else { throw APIError.badRequest("task id is required") }
            _ = try service.delete(taskID, hard: true)

        case .createEmailDraft:
            guard let gmail else { throw APIError.badRequest("Gmail is not connected.") }
            guard let draft = operation.emailDraft else {
                throw APIError.badRequest("draft is required")
            }
            try gmail.emailCreateDraft(draft)

        case .labelEmail:
            guard let gmail, let accountID = operation.emailAccountID,
                  let threadIDs = operation.emailThreadIDs,
                  let labels = operation.emailLabels else {
                throw APIError.badRequest("email target is required")
            }
            let add = operation.emailAddLabel ?? true
            try gmail.emailSetLabels(accountID: accountID, threadIDs: threadIDs,
                                     add: add ? labels : [],
                                     remove: add ? [] : labels)

        case .archiveEmail:
            guard let gmail, let accountID = operation.emailAccountID,
                  let threadIDs = operation.emailThreadIDs else {
                throw APIError.badRequest("email target is required")
            }
            try gmail.emailArchive(accountID: accountID, threadIDs: threadIDs)

        case .trashEmail:
            guard let gmail, let accountID = operation.emailAccountID,
                  let threadIDs = operation.emailThreadIDs else {
                throw APIError.badRequest("email target is required")
            }
            try gmail.emailTrash(accountID: accountID, threadIDs: threadIDs)

        case .markEmailRead:
            guard let gmail, let accountID = operation.emailAccountID,
                  let threadIDs = operation.emailThreadIDs else {
                throw APIError.badRequest("email target is required")
            }
            // The executor's mail protocol expresses reads as label changes, so a
            // read is "remove UNREAD" and an unread is "add UNREAD".
            let read = operation.emailRead ?? true
            try gmail.emailSetLabels(accountID: accountID, threadIDs: threadIDs,
                                     add: read ? [] : ["UNREAD"],
                                     remove: read ? ["UNREAD"] : [])
        }
    }
}

/// `LocalAgentPlan.isClear` lives in the app target; the executor is shared and
/// must not depend on it. The rule is a wire-contract detail, so it lives here.
private enum LocalAgentPlanClear {
    static func isClear(_ value: String) -> Bool {
        ["none", "clear", "never", "-"].contains(value.lowercased())
    }
}
