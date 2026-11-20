import Foundation
import UserNotifications

/// Local notifications only, and only ones the user would miss otherwise.
///
/// Everything is scheduled ahead of time with calendar triggers, so the app runs no
/// timers and does no background work — the notification daemon does the waiting.
@MainActor
final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {

    private let center = UNUserNotificationCenter.current()
    private var scheduledSignature: Int = 0
    /// Identifiers we added, so each reschedule removes only its own category and
    /// task reminders cannot wipe commitment or brief alerts.
    private var taskIDs: [String] = []
    private var commitmentIDs: [String] = []
    private var briefIDs: [String] = []
    private var staleIDs: [String] = []
    private var staleGeneration = 0
    /// A notification tap can arrive before the window has wired its handler.
    private var pendingOpenTaskID: UUID?

    var onOpenTask: ((UUID) -> Void)? {
        didSet {
            guard let id = pendingOpenTaskID else { return }
            pendingOpenTaskID = nil
            onOpenTask?(id)
        }
    }

    override init() {
        super.init()
        center.delegate = self
    }

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

    /// Schedules the next stale-task nudges. The engine includes future thresholds;
    /// the system keeps the request after the app quits, so an untouched task can
    /// still raise its hand hours later. Existing requests are kept when the task is
    /// unchanged, which is what prevents a store update from re-notifying it.
    func rescheduleStale(tasks: [TaskItem], policy: StaleTaskPolicy, enabled: Bool,
                         onScheduled: @escaping (UUID, Date) -> Void) {
        staleGeneration += 1
        let generation = staleGeneration
        guard enabled else {
            // Pending requests survive relaunches and are not in `staleIDs` until
            // this process has seen them. Remove by prefix, not by memory.
            Task { @MainActor in
                let pending = await center.pendingNotificationRequests()
                guard generation == self.staleGeneration else { return }
                let stale = pending.map(\.identifier).filter { $0.hasPrefix("stale-") }
                center.removePendingNotificationRequests(withIdentifiers: stale)
                self.staleIDs.removeAll()
            }
            return
        }

        Task { @MainActor in
            let authorization = await center.notificationSettings().authorizationStatus
            guard authorization == .authorized || authorization == .provisional else { return }
            let pending = await center.pendingNotificationRequests()
            guard generation == self.staleGeneration else { return }
            let existing = Set(pending.map(\.identifier).filter { $0.hasPrefix("stale-") })
            let now = Date()
            let candidates = StaleTaskEngine.candidates(tasks: tasks, now: now, policy: policy)
            let noticesToday = tasks.filter {
                guard let notice = $0.lastStaleNoticeAt else { return false }
                return now.timeIntervalSince(notice) < 86_400
            }.count
            var budget = max(0, policy.maxPerDay - noticesToday)
            var keep: Set<String> = []
            var lastFire: Date?

            for candidate in candidates {
                let identifier = "stale-\(candidate.task.id.uuidString)"
                if let notice = candidate.task.lastStaleNoticeAt,
                   notice >= candidate.task.activityAnchor {
                    // Already scheduled or already delivered. Keep a pending request;
                    // never enqueue a second one for the same unchanged task.
                    if existing.contains(identifier) { keep.insert(identifier) }
                    continue
                }
                guard budget > 0, keep.count < policy.maxScheduled else { continue }

                var fireAt = max(candidate.fireAt, now.addingTimeInterval(60))
                if let lastFire {
                    fireAt = max(fireAt, lastFire.addingTimeInterval(
                        TimeInterval(max(0, policy.minimumSpacingMinutes)) * 60))
                }
                fireAt = policy.nextAllowed(fireAt, now: now)

                let content = UNMutableNotificationContent()
                content.title = candidate.task.title
                content.subtitle = "\(candidate.task.status.label) · \(candidate.task.priority.longLabel)"
                content.body = candidate.reason
                content.userInfo = ["taskID": candidate.task.id.uuidString]
                content.threadIdentifier = "kanban.stale"
                content.sound = candidate.task.priority >= .high ? .default : nil

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: fireAt)
                let request = UNNotificationRequest(
                    identifier: identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components,
                                                          repeats: false))
                do {
                    try await center.add(request)
                    keep.insert(identifier)
                    lastFire = fireAt
                    budget -= 1
                    onScheduled(candidate.task.id, now)
                } catch {
                    // Permission or system refusal: leave it out; the next deliberate
                    // reschedule will try again.
                    continue
                }
            }

            let remove = existing.subtracting(keep)
            if !remove.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(remove))
            }
            self.staleIDs = Array(keep)
        }
    }

    // MARK: - Notification taps

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["taskID"] as? String
        if let raw, let id = UUID(uuidString: raw) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let handler = self.onOpenTask {
                    handler(id)
                } else {
                    self.pendingOpenTaskID = id
                }
            }
        }
        completionHandler()
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
