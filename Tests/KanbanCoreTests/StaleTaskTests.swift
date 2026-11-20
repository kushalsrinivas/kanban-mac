import XCTest

/// The stale-task policy and the store timestamps it depends on.
final class StaleTaskTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20,
                                                 hour: 12, minute: 0))!
    }

    private func task(_ title: String, status: TaskStatus = .todo,
                      priority: Priority = .medium, inactiveHours: Double) -> TaskItem {
        let anchor = now.addingTimeInterval(-inactiveHours * 3_600)
        return TaskItem(title: title, status: status, priority: priority,
                        updatedAt: anchor, lastStatusUpdatedAt: anchor,
                        lastActivityAt: anchor)
    }

    func testPriorityAndStatusChangeTheThreshold() {
        let policy = StaleTaskPolicy.standard
        let urgent = task("urgent", status: .todo, priority: .urgent, inactiveHours: 0)
        let medium = task("medium", status: .todo, priority: .medium, inactiveHours: 0)
        let inbox = task("inbox", status: .inbox, priority: .medium, inactiveHours: 0)
        let active = task("active", status: .inProgress, priority: .medium, inactiveHours: 0)

        XCTAssertLessThan(policy.threshold(for: urgent), policy.threshold(for: medium))
        XCTAssertGreaterThan(policy.threshold(for: inbox), policy.threshold(for: medium))
        XCTAssertLessThan(policy.threshold(for: active), policy.threshold(for: medium))
    }

    func testStaleTaskGetsACandidateWithReason() throws {
        let stale = task("Send the proposal", status: .todo, priority: .high,
                         inactiveHours: 30)
        let candidates = StaleTaskEngine.candidates(tasks: [stale], now: now,
                                                    policy: .standard, calendar: calendar)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.task.id, stale.id)
        XCTAssertTrue(candidate.reason.contains("TODO"))
        XCTAssertTrue(candidate.reason.contains("HIGH"))
        XCTAssertTrue(candidate.reason.contains("no progress"))
        XCTAssertLessThanOrEqual(candidate.fireAt, now)
    }

    func testFutureTasksAreScheduledAhead() throws {
        // Candidate fire time is the inactivity threshold, not "now".
        let fresh = task("Fresh", status: .todo, priority: .medium, inactiveHours: 1)
        let candidate = try XCTUnwrap(StaleTaskEngine.candidates(
            tasks: [fresh], now: now, policy: .standard, calendar: calendar).first)
        XCTAssertGreaterThan(candidate.fireAt, now)
        XCTAssertEqual(candidate.fireAt.timeIntervalSince(fresh.activityAnchor),
                       StaleTaskPolicy.standard.threshold(for: fresh), accuracy: 1)
    }

    func testCompletedAndArchivedTasksAreNeverCandidates() {
        var done = task("Done", status: .done, priority: .urgent, inactiveHours: 500)
        done.completedAt = now
        var archived = task("Archived", status: .todo, priority: .urgent, inactiveHours: 500)
        archived.archivedAt = now

        let candidates = StaleTaskEngine.candidates(
            tasks: [done, archived], now: now, policy: .standard, calendar: calendar)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testAnUnchangedTaskIsNotNudgedTwice() {
        var stale = task("Stale", inactiveHours: 200)
        stale.lastStaleNoticeAt = now.addingTimeInterval(-60)
        let candidates = StaleTaskEngine.candidates(
            tasks: [stale], now: now, policy: .standard, calendar: calendar)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testActivityAfterANoticeMakesItEligibleAgain() throws {
        var task = task("Stale", inactiveHours: 200)
        task.lastStaleNoticeAt = task.activityAnchor.addingTimeInterval(60)
        // A real activity after the notice resets the anchor.
        task.lastActivityAt = task.lastStaleNoticeAt!.addingTimeInterval(120)
        let candidates = StaleTaskEngine.candidates(
            tasks: [task], now: now, policy: .standard, calendar: calendar)
        // It is eligible, but the cooldown may schedule it in the future.
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThanOrEqual(candidate.fireAt, task.lastStaleNoticeAt!)
    }

    func testQuietHoursMoveTheFireTimeToTheMorning() {
        let policy = StaleTaskPolicy(quietHoursEnabled: true, quietStartHour: 22,
                                     quietEndHour: 8)
        let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20,
                                                      hour: 23, minute: 0))!
        let adjusted = policy.nextAllowed(late, now: late, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: adjusted), 8)
        XCTAssertEqual(calendar.component(.day, from: adjusted), 21)

        let early = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20,
                                                       hour: 6, minute: 0))!
        XCTAssertEqual(calendar.component(.hour, from: policy.nextAllowed(
            early, now: early, calendar: calendar)), 8)

        let daytime = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20,
                                                         hour: 14, minute: 0))!
        XCTAssertEqual(policy.nextAllowed(daytime, now: daytime, calendar: calendar), daytime)
    }

    @MainActor
    func testStoreTracksProgressAndStatusSeparately() {
        let store = LocalStore(ephemeral: true)
        let created = store.createTask(TaskItem(title: "Draft", status: .todo))
        let createdAnchor = try? XCTUnwrap(created.lastActivityAt)
        XCTAssertNotNil(createdAnchor)

        // A pure reorder is not meaningful progress.
        store.updateTask(created.id) { $0.position = 42 }
        XCTAssertEqual(store.task(created.id)?.lastActivityAt, createdAnchor)

        // Editing the title is.
        let edited = store.updateTask(created.id) { $0.title = "Draft v2" }
        XCTAssertGreaterThan(edited?.lastActivityAt ?? .distantPast, createdAnchor ?? .distantPast)

        let beforeMove = store.task(created.id)?.lastStatusUpdatedAt
        store.moveTask(created.id, to: .inProgress)
        XCTAssertGreaterThan(store.task(created.id)?.lastStatusUpdatedAt ?? .distantPast,
                             beforeMove ?? .distantPast)
    }

    @MainActor
    func testV5DatabaseUpgradesWithoutLosingTasks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v5-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = LocalStore(url: url)
        let task = first.createTask(TaskItem(title: "Kept through upgrade", status: .todo))
        first.flush()

        let raw = try SQLiteDatabase(path: url.path)
        raw.userVersion = 5

        let upgraded = LocalStore(url: url)
        XCTAssertEqual(upgraded.task(task.id)?.title, "Kept through upgrade")
        XCTAssertEqual(upgraded.task(task.id)?.status, .todo)
        XCTAssertNotNil(upgraded.task(task.id)?.lastActivityAt)
        XCTAssertNotNil(upgraded.task(task.id)?.lastStatusUpdatedAt)
    }

    @MainActor
    func testStaleNoticeDoesNotResetInactivityAndSurvivesReopening() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = LocalStore(url: url)
        let task = first.createTask(TaskItem(title: "Old task", status: .todo))
        let anchor = try XCTUnwrap(task.lastActivityAt)
        first.markStaleNotified(task.id, at: now)
        first.flush()

        let second = LocalStore(url: url)
        let reloaded = try XCTUnwrap(second.task(task.id))
        XCTAssertEqual(reloaded.lastStaleNoticeAt?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(reloaded.lastActivityAt?.timeIntervalSince1970 ?? 0,
                       anchor.timeIntervalSince1970, accuracy: 0.001)
    }
}
