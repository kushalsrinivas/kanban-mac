import EventKit
import Foundation
import Observation

/// Read-only access to the calendars macOS already has: Google and Outlook accounts
/// added in System Settings → Internet Accounts appear here without OAuth, redirect
/// URIs or store refresh tokens. The app never writes to the calendar.
@Observable
@MainActor
final class CalendarBridge {

    struct FeedEvent: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var externalID: String
        public var title: String
        public var notes: String
        public var location: String
        public var startsAt: Date
        public var endsAt: Date
        public var participants: [String]

        /// The brief builder works on scheduled meetings; an external event is one
        /// that just happens to live in another app.
        public var scheduledMeeting: ScheduledMeeting {
            ScheduledMeeting(id: id, title: title, notes: notes, location: location,
                             startsAt: startsAt, endsAt: endsAt, participants: participants)
        }
    }

    private(set) var events: [FeedEvent] = []
    private(set) var authorization: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?
    private let store = EKEventStore()

    var isAuthorized: Bool { authorization == .fullAccess }

    var needsPermission: Bool {
        authorization == .notDetermined
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorization = EKEventStore.authorizationStatus(for: .event)
            if granted {
                await refresh()
            } else {
                lastError = "Calendar access was declined. Enable it in System Settings → Privacy & Security → Calendars."
            }
        } catch {
            authorization = EKEventStore.authorizationStatus(for: .event)
            lastError = error.localizedDescription
        }
    }

    /// Loads the next `days` of timed events. All-day events are skipped: they are
    /// usually reminders, not meetings that need a brief.
    func refresh(days: Int = 14, now: Date = Date()) async {
        authorization = EKEventStore.authorizationStatus(for: .event)
        guard isAuthorized else { return }
        let end = now.addingTimeInterval(TimeInterval(max(1, days)) * 86_400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let loaded = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }

        events = loaded.compactMap { event in
            guard let start = event.startDate, let finish = event.endDate, finish > start else {
                return nil
            }
            let external = event.eventIdentifier
                ?? "\(event.title ?? "")|\(start.timeIntervalSince1970)"
            var people: [String] = []
            if let attendees = event.attendees {
                for attendee in attendees {
                    let name = attendee.name?.trimmingCharacters(in: .whitespaces)
                    let address = attendee.url.absoluteString
                        .replacingOccurrences(of: "mailto:", with: "")
                    let label = (name?.isEmpty == false ? name! : address)
                    if !label.isEmpty, !people.contains(label) { people.append(label) }
                }
            }
            if let organizer = event.organizer,
               let name = organizer.name ?? organizer.url.absoluteString as String?,
               !name.isEmpty, !people.contains(name) {
                people.append(name)
            }
            return FeedEvent(
                id: UUID.stable(from: "calendar:\(external)"),
                externalID: external,
                title: event.title ?? "Untitled event",
                notes: event.notes ?? "",
                location: event.location ?? "",
                startsAt: start, endsAt: finish,
                participants: people)
        }
        lastRefresh = Date()
        lastError = nil
    }

    /// Events that start in the next `minutes`, used for pre-meeting notifications.
    func startingSoon(within minutes: Int = 60, now: Date = Date()) -> [FeedEvent] {
        let cutoff = now.addingTimeInterval(TimeInterval(minutes) * 60)
        return events.filter { $0.startsAt >= now && $0.startsAt <= cutoff }
    }
}
