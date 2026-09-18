import Foundation
import UserNotifications

/// Local notifications only, and only ones the user would miss otherwise.
///
/// Everything is scheduled ahead of time with calendar triggers, so the app runs no
/// timers and does no background work — the notification daemon does the waiting.
@MainActor
final class NotificationCenterBridge {

    private let center = UNUserNotificationCenter.current()
    private var scheduledSignature: Int = 0

    func requestAuthorisation(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Replaces the pending set with reminders for open, dated tasks.
    /// Called after mutations (already coalesced by the store).
    func reschedule(for tasks: [TaskItem], enabled: Bool) {
        guard enabled else {
            center.removeAllPendingNotificationRequests()
            scheduledSignature = 0
            return
        }
        let now = Date()
        let upcoming = tasks
            .filter { $0.isOpen && ($0.dueDate.map { $0 > now } ?? false) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            .prefix(32)   // a personal board never needs more pending alerts than this

        // Skip the work entirely when nothing relevant changed.
        var hasher = Hasher()
        for t in upcoming {
            hasher.combine(t.id)
            hasher.combine(t.dueDate)
            hasher.combine(t.title)
        }
        let signature = hasher.finalize()
        guard signature != scheduledSignature else { return }
        scheduledSignature = signature

        center.removeAllPendingNotificationRequests()
        let calendar = Calendar.current
        for task in upcoming {
            guard let due = task.dueDate else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = "Due \(DateInput.shortLabel(due).lowercased()) · \(task.priority.longLabel.lowercased())"
            content.sound = task.priority >= .high ? .default : nil
            content.threadIdentifier = "kanban.due"

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: "due-\(task.id.uuidString)",
                                             content: content, trigger: trigger))
        }
    }

    /// Meeting processing finishes minutes after the user walked away, so this is one
    /// of the few notifications that genuinely earns its place.
    func notifyMeetingProcessed(title: String, suggestions: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = suggestions > 0
            ? "Notes ready · \(suggestions) suggested task\(suggestions == 1 ? "" : "s") to review"
            : "Notes ready"
        content.threadIdentifier = "kanban.meeting"
        center.add(UNNotificationRequest(identifier: "meeting-\(UUID().uuidString)",
                                         content: content, trigger: nil))
    }

    func notifyAgentAction(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Agent finished"
        content.body = "\(count) change\(count == 1 ? "" : "s") applied to your board."
        content.threadIdentifier = "kanban.agent"
        center.add(UNNotificationRequest(identifier: "agent-\(UUID().uuidString)",
                                         content: content, trigger: nil))
    }

    func notifyConfirmationNeeded(summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "Agent needs confirmation"
        content.body = summary
        content.threadIdentifier = "kanban.agent"
        center.add(UNNotificationRequest(identifier: "agent-confirm-\(UUID().uuidString)",
                                         content: content, trigger: nil))
    }
}
