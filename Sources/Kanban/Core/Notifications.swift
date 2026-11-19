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
    /// Identifiers we added, so each reschedule removes only its own category and
    /// task reminders cannot wipe commitment or brief alerts.
    private var taskIDs: [String] = []
    private var commitmentIDs: [String] = []
    private var briefIDs: [String] = []

    func requestAuthorisation(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Replaces the pending set with reminders for open, dated tasks.
    /// Called after mutations (already coalesced by the store).
    func reschedule(for tasks: [TaskItem], enabled: Bool) {
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: taskIDs)
            taskIDs.removeAll()
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

        center.removePendingNotificationRequests(withIdentifiers: taskIDs)
        taskIDs.removeAll()
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
            let identifier = "due-\(task.id.uuidString)"
            taskIDs.append(identifier)
            center.add(UNNotificationRequest(identifier: identifier,
                                             content: content, trigger: trigger))
        }
    }

    /// Commitments are promises, not tasks; they get their own identifier prefix so a
    /// board edit cannot remove them.
    func rescheduleCommitments(_ commitments: [(item: ActionItem, meeting: Meeting)],
                               enabled: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: commitmentIDs)
        commitmentIDs.removeAll()
        guard enabled else { return }
        let now = Date()
        let calendar = Calendar.current
        for (item, meeting) in commitments.prefix(32) {
            guard item.isOpen, let due = item.dueDate, due > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Commitment: \(item.title)"
            content.body = "From \(meeting.title) · due \(DateInput.shortLabel(due).lowercased())"
            content.threadIdentifier = "kanban.commitment"
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "commit-\(item.id.uuidString)"
            commitmentIDs.append(identifier)
            center.add(UNNotificationRequest(identifier: identifier,
                                             content: content, trigger: trigger))
        }
    }

    /// A pre-meeting brief is useful only if it arrives before the meeting.
    func scheduleBriefs(_ briefs: [(meeting: ScheduledMeeting, summary: String)],
                        enabled: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: briefIDs)
        briefIDs.removeAll()
        guard enabled else { return }
        let now = Date()
        for (meeting, summary) in briefs.prefix(24) {
            let fireAt = meeting.startsAt.addingTimeInterval(-15 * 60)
            guard fireAt > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Brief: \(meeting.title)"
            content.body = String(summary.prefix(220))
            content.threadIdentifier = "kanban.brief"
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "brief-\(meeting.id.uuidString)"
            briefIDs.append(identifier)
            center.add(UNNotificationRequest(identifier: identifier,
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
}
