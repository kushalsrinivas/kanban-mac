#if DEBUG
import Foundation

@MainActor

/// Deterministic board content for UI/screenshot runs.
///
/// Enabled only when `KANBAN_DEMO_DATA=1` and the store is empty. It never runs in
/// release builds and never touches a real board.
enum DemoSeed {

    private static func id(_ suffix: String) -> UUID {
        UUID(uuidString: "A0000000-0000-4000-8000-\(suffix)")!
    }

    private static func meetingID(_ suffix: String) -> UUID {
        UUID(uuidString: "B0000000-0000-4000-8000-\(suffix)")!
    }

    private static func actionID(_ suffix: String) -> UUID {
        UUID(uuidString: "C0000000-0000-4000-8000-\(suffix)")!
    }

    static func seedIfNeeded(_ store: LocalStore, now: Date = Date()) {
        guard store.tasks.isEmpty, store.meetings.isEmpty else { return }
        let cal = Calendar.current
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: now)! }

        let deployID = id("000000000005")
        let syncID = meetingID("000000000001")

        var inbox = TaskItem(id: id("000000000001"), title: "Review Q4 pricing model",
                             notes: "Compare the three tiers against support cost.\nBring a recommendation to Thursday's sync.",
                             status: .inbox, priority: .high, dueDate: day(0),
                             tags: ["pricing", "q4"],
                             subtasks: [Subtask(title: "Pull last quarter's numbers", position: 0),
                                        Subtask(title: "Model the support load", position: 1)],
                             position: -3)
        inbox.source = .manual
        store.createTask(inbox)

        store.createTask(TaskItem(id: id("000000000002"), title: "Fix webhook retry bug",
                                  notes: "Retries stop after the first 409.",
                                  status: .inbox, priority: .urgent, dueDate: day(-1),
                                  tags: ["backend"], position: -2))

        store.createTask(TaskItem(id: id("000000000003"), title: "Draft onboarding email",
                                  notes: "", status: .inbox, priority: .medium, dueDate: day(3),
                                  tags: ["growth"],
                                  subtasks: [Subtask(title: "Outline", isDone: true, position: 0),
                                             Subtask(title: "Write", position: 1)],
                                  position: -1))

        store.createTask(TaskItem(id: id("000000000004"), title: "Ship agent console copy",
                                  notes: "Say what the operation will change, not just the field name.",
                                  status: .todo, priority: .high, dueDate: day(1),
                                  tags: ["agent"], position: -2, source: .agent))

        store.createTask(TaskItem(id: id("000000000006"), title: "Book offsite venue",
                                  notes: "", status: .todo, priority: .low, dueDate: nil,
                                  tags: ["ops"], position: -1))

        store.createTask(TaskItem(id: deployID, title: "Deploy API v1.4",
                                  notes: "Ship the agent bridge after the migration.",
                                  status: .inProgress, priority: .urgent, dueDate: day(0),
                                  tags: ["ops", "release"],
                                  subtasks: [Subtask(title: "build image", isDone: true, position: 0),
                                             Subtask(title: "run migrations", position: 1)],
                                  position: -2, source: .meeting, meetingID: syncID,
                                  actionItemID: actionID("000000000002")))

        store.createTask(TaskItem(id: id("000000000007"), title: "Design meeting report",
                                  notes: "", status: .inProgress, priority: .medium,
                                  dueDate: day(2), tags: ["design"], position: -1))

        store.createTask(TaskItem(id: id("000000000008"), title: "Migrate Postgres schema",
                                  notes: "", status: .done, priority: .high, dueDate: nil,
                                  tags: ["backend"], position: -1))

        store.createTask(TaskItem(id: id("000000000009"), title: "Old roadmap review",
                                  notes: "", status: .done, priority: .low, dueDate: nil,
                                  tags: [], position: -2))
        store.archiveTask(id("000000000009"))

        // One finished meeting with results and suggestions.
        let syncItems = [
            ActionItem(id: actionID("000000000001"), meetingID: syncID,
                       title: "Send revised onboarding copy", assignee: "Sarah",
                       dueDate: day(-1), confidence: 0.92, state: .suggested, position: 0,
                       quote: "Sarah sends the revised copy by Friday.",
                       sourceStart: 31, sourceEnd: 42),
            ActionItem(id: actionID("000000000002"), meetingID: syncID,
                       title: "Deploy API v1.4", assignee: "Kushal", dueDate: day(0),
                       confidence: 0.97, state: .added, taskID: deployID, position: 1,
                       quote: "we ship API v1.4 after the migration",
                       sourceStart: 31, sourceEnd: 42),
            ActionItem(id: actionID("000000000003"), meetingID: syncID,
                       title: "Book the offsite", assignee: nil, dueDate: nil,
                       confidence: 0.61, state: .dismissed, position: 2)
        ]
        store.upsertMeeting(Meeting(
            id: syncID, title: "Product Sync", startedAt: now.addingTimeInterval(-3_600),
            duration: 2_532, status: .completed,
            summary: "The team settled the Q4 pricing direction and agreed the API v1.4 release can ship once the schema migration lands. Onboarding copy is the remaining blocker for the launch email.",
            keyPoints: ["Q4 pricing keeps three tiers, with usage overage moved to the middle tier.",
                        "API v1.4 ships after the migration, not before.",
                        "Onboarding copy needs a shorter first paragraph."],
            decisions: ["Keep three pricing tiers for Q4.",
                        "Reject the usage-based pricing model.",
                        "Ship API v1.4 after the schema migration."],
            questions: ["Who signs off the final onboarding copy?"],
            topics: ["pricing", "release", "onboarding"],
            participants: ["Kushal", "Sarah", "Alex"],
            actionItems: syncItems))

        // An older decision the current one reverses. Organizational memory should
        // be able to explain the change, not just list both rows.
        store.upsertMeeting(Meeting(
            id: meetingID("000000000003"), title: "Pricing strategy offsite",
            startedAt: day(-40), duration: 5_400, status: .completed,
            summary: "The team approved usage-based pricing for enterprise and parked the three-tier model.",
            keyPoints: ["Usage-based pricing matches enterprise support cost."],
            decisions: ["We approved the usage-based pricing model."],
            questions: ["How do we explain overage to finance?"],
            topics: ["pricing", "enterprise"],
            participants: ["Kushal", "Alex", "Priya"],
            actionItems: []))

        store.saveTranscript([
            TranscriptSegment(start: 0, end: 8, speaker: "Alex",
                              text: "Let's start with pricing. The support cost on the middle tier is the part that keeps surprising us."),
            TranscriptSegment(start: 8, end: 19, speaker: "Kushal",
                              text: "Agreed. I'd keep three tiers and move the overage into the middle one, so the entry price stays where it is."),
            TranscriptSegment(start: 19, end: 31, speaker: "Sarah",
                              text: "The onboarding copy is still the blocker. The first paragraph tries to explain the whole product before anyone has seen the board."),
            TranscriptSegment(start: 31, end: 42, speaker: "Alex",
                              text: "Then we ship API v1.4 after the migration, and Sarah sends the revised copy by Friday.")
        ], for: syncID)

        // A failure state so its panel is reviewable too. The audio is a short,
        // silent WAV generated at seed time: playback is real, and the failure is
        // analysis rather than a missing file.
        let olderID = meetingID("000000000002")
        let audioName = "demo-design-review.wav"
        writeDemoAudio(named: audioName, seconds: 20)
        store.upsertMeeting(Meeting(
            id: olderID, title: "Design Review", startedAt: day(-1).addingTimeInterval(3_600),
            duration: 20, status: .failed, audioFilename: audioName,
            failureReason: "Analysis failed after transcription. The recording is intact and can be processed again."))

        // Local schedule. The two meetings overlap so the pre-meeting brief has a
        // real conflict to surface.
        store.upsertScheduledMeeting(ScheduledMeeting(
            title: "Design review",
            notes: "Walk through the new board states and agree the empty-state copy.",
            location: "Studio",
            startsAt: now.addingTimeInterval(3_600),
            endsAt: now.addingTimeInterval(5_400),
            participants: ["Kushal", "Sarah"]))
        store.upsertScheduledMeeting(ScheduledMeeting(
            title: "Vendor sync",
            notes: "Renewal pricing and the Q1 rollout window.",
            location: "Zoom",
            startsAt: now.addingTimeInterval(4_500),
            endsAt: now.addingTimeInterval(6_300),
            participants: ["Alex", "Priya"]))

        // A configured rule, a composed draft and a run make the automation surface
        // reviewable instead of an empty state.
        if store.automationRules.isEmpty {
            store.upsertAutomationRule(AutomationRule.standardFollowUp())
        }
        if store.localMessages.isEmpty, let sync = store.meeting(syncID) {
            store.addLocalMessage(FollowUpComposer.summary(meeting: sync))
            store.recordAutomationRun(AutomationRun(
                ruleID: store.automationRules.first?.id, ruleName: "Meeting follow-up",
                meetingID: syncID, status: .completed,
                detail: "drafted summary · created 2 tasks · notified 2 owners",
                startedAt: now.addingTimeInterval(-3_500), finishedAt: now.addingTimeInterval(-3_400)))
        }
    }

    /// 8 kHz, 16-bit mono silence. Small, valid and playable by AVFoundation.
    private static func writeDemoAudio(named name: String, seconds: Int) {
        let url = KanbanPaths.ensureRecordingsDirectory().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let frames = Int(sampleRate) * seconds
        let dataBytes = UInt32(frames * Int(channels) * Int(bits) / 8)

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(sampleRate)
        append(sampleRate * UInt32(channels) * UInt32(bits) / 8)
        append(channels * bits / 8)
        append(bits)
        data.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        data.append(Data(repeating: 0, count: Int(dataBytes)))
        try? data.write(to: url)
    }
}
#endif
