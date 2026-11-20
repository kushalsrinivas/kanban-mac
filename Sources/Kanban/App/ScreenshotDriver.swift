#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Deterministic window capture for visual evidence.
///
/// Enabled only when `KANBAN_SCREENSHOT_DIR` is set in a Debug build. It drives the
/// real app through its main screens, renders each window's own view hierarchy to a
/// PNG (no screen-recording or automation permission needed), and optionally quits.
@MainActor
enum ScreenshotDriver {

    static func runIfRequested(_ app: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["KANBAN_SCREENSHOT_DIR"],
              !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let quit = ProcessInfo.processInfo.environment["KANBAN_AUTO_QUIT"] == "1"

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            NSApp.activate(ignoringOtherApps: true)
            if ProcessInfo.processInfo.environment["KANBAN_SCREENSHOT_GATE"] == "1" {
                if let account = seedGmail(app) {
                    app.mail.setAccount(account)
                    app.mail.refreshStorageSecurity()
                }
                app.section = .mail
                await pause()
                await capture("48-mail-filevault-locked")
                if quit { NSApp.terminate(nil) }
                return
            }
            await capture("01-board-light")
            await pause()

            if let window = mainWindow() {
                window.setContentSize(NSSize(width: 780, height: 520))
                await pause()
                await capture("14-board-compact-light")
                window.setContentSize(NSSize(width: 1440, height: 900))
                await pause()
                await capture("15-board-wide-light")
                window.setContentSize(NSSize(width: 1160, height: 760))
                await pause()
            }

            app.quickAddText = "Fix auth bug !high #backend @friday >todo"
            await pause()
            await capture("02-quick-add-light")
            app.quickAddText = ""

            app.isSearchActive = true
            app.searchText = "pricing"
            await pause()
            await capture("03-search-light")
            app.isSearchActive = false
            app.searchText = ""

            app.isPaletteOpen = true
            await pause()
            await capture("04-palette-light")
            app.isPaletteOpen = false

            app.section = .meetings
            await pause()
            await capture("05-meetings-light")
            app.selectedMeeting = app.store.meetings.first { $0.status == .completed }?.id
            await pause()
            await capture("06-meeting-detail-light")

            app.section = .calendar
            app.selectedScheduledMeetingID = app.store.scheduledMeetings.upcoming().first?.id
            await pause()
            await capture("08-meet-briefs-light")
            app.meetTab = .commitments
            await pause()
            await capture("09-meet-commitments-light")
            app.meetTab = .memory
            await pause()
            await capture("10-meet-memory-light")
            app.meetTab = .automation
            await pause()
            await capture("11-meet-automation-light")
            app.meetTab = .briefs

            app.section = .agent
            await pause()
            await capture("07-agent-light")

            // Drive the workspace through the same prompts a person would use, so
            // the evidence includes real artifacts rather than an empty panel.
            app.agent.send("What's on my todo?")
            await pause()
            await capture("20-agent-tasks-light")

            app.agent.send("Show my recent meetings")
            await pause()
            await capture("21-agent-meetings-light")

            app.agent.send("Summarize it")
            await pause()
            await capture("22-agent-summary-light")

            app.agent.send("who was in it?")
            await pause()
            await capture("23-agent-participants-light")

            app.agent.send("show the transcript of product sync")
            await pause()
            await capture("24-agent-transcript-light")

            app.agent.send("What tasks came out of it?")
            await pause()
            await capture("25-agent-action-items-light")

            app.agent.send("Find my last recording")
            await pause()
            await capture("26-agent-recording-light")

            app.agent.send("Play its recording")
            await pause()
            try? await Task.sleep(nanoseconds: 900_000_000)
            await capture("27-agent-playing-light")
            app.agent.player.pause()

            app.agent.send("open the design review meeting")
            await pause()
            await capture("28-agent-opened-meeting-light")
            app.section = .agent
            await pause()

            app.agent.send("create task Review agent output @tomorrow !high #agent >todo")
            await pause()
            await capture("29-agent-proposal-light")

            if let window = mainWindow() {
                window.setContentSize(NSSize(width: 780, height: 600))
                await pause()
                await capture("30-agent-compact-light")
                window.setContentSize(NSSize(width: 1160, height: 760))
                await pause()
            }

            if let action = app.agent.pending.first {
                await app.agent.execute(action)
            }
            await pause()
            await capture("31-agent-executed-light")

            app.agent.send("What's on my todo?")
            await pause()
            await capture("32-agent-after-execute-light")

            app.settings.appearance = .dark
            await pause()
            await capture("33-agent-dark")
            app.settings.appearance = .light
            await pause()

            // Local schedule: list, brief, proposal, confirmation, result.
            app.section = .calendar
            app.selectedScheduledMeetingID = app.store.scheduledMeetings.upcoming().first?.id
            await pause()
            await capture("34-calendar-light")

            app.section = .agent
            app.agent.send("what's on my calendar?")
            await pause()
            await capture("35-agent-calendar-light")

            app.agent.send("prepare me for my next meeting")
            await pause()
            await capture("36-agent-brief-light")

            app.agent.send("schedule a meeting about onboarding with Sarah tomorrow at 2pm for 45 minutes")
            await pause()
            await capture("37-agent-schedule-proposal-light")
            if let action = app.agent.pending.first {
                await app.agent.execute(action)
            }
            await pause()
            await capture("38-agent-scheduled-light")

            if let created = app.store.scheduledMeetings.first(where: { $0.title == "Onboarding" }) {
                app.openCalendar(created.id)
            } else {
                app.openCalendar()
            }
            await pause()
            await capture("39-calendar-scheduled-light")

            app.settings.appearance = .dark
            await pause()
            await capture("40-calendar-dark")
            app.settings.appearance = .light
            await pause()

            // Mail: the same harness seeds a throwaway local Gmail cache.
            if let gmailAccount = seedGmail(app) {
                app.mail.setAccount(gmailAccount)
                app.section = .mail
                await pause()
                await capture("41-mail-inbox-light")

                if let thread = app.mail.threads.first(where: { $0.messageCount > 1 })
                    ?? app.mail.threads.first {
                    app.mail.select(accountID: thread.accountID, threadID: thread.id)
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    await capture("42-mail-thread-light")
                    renderComposer(app: app, accountID: gmailAccount)
                }

                app.section = .agent
                app.agent.send("summarize my unread emails")
                await pause()
                await capture("45-agent-email-unread-light")

                app.agent.send("find the email where we discussed pricing")
                await pause()
                await capture("46-agent-email-search-light")

                app.agent.send("which emails need my attention?")
                await pause()
                await capture("47-agent-email-attention-light")

                app.section = .mail
                app.settings.appearance = .dark
                await pause()
                await capture("43-mail-dark")
                app.settings.appearance = .light
                await pause()
            }

            app.section = .tasks
            await pause()
            if let first = app.store.tasks(in: .inbox).first {
                app.openInspector(for: first.id)
            }
            await pause()
            await capture("08-inspector-light")
            app.closeInspector()

            // The Settings scene cannot be opened reliably from a headless launch;
            // render the real view offscreen instead.
            renderSettings(app: app, named: "09-settings-light", dark: false)
            renderSettings(app: app, named: "19-settings-full-light", dark: false, height: 1180)
            renderDictation(app: app, dark: false)

            app.settings.appearance = .dark
            app.section = .tasks
            await pause()
            await capture("10-board-dark")

            app.section = .meetings
            app.selectedMeeting = app.store.meetings.first { $0.status == .completed }?.id
            await pause()
            await capture("11-meeting-detail-dark")

            app.section = .tasks
            if let first = app.store.tasks(in: .inbox).first {
                app.openInspector(for: first.id)
            }
            await pause()
            await capture("12-inspector-dark")
            app.closeInspector()
            renderSettings(app: app, named: "13-settings-dark", dark: true)
            app.settings.appearance = .light

            if quit { NSApp.terminate(nil) }
        }

        func capture(_ name: String) async {
            write(window: mainWindow(), named: name, into: directory)
        }


        func renderSettings(app: AppModel, named name: String, dark: Bool, height: CGFloat = 660) {
            let view = SettingsView()
                .environment(app)
                .environment(\.theme, Theme.resolved(dark: dark, accent: app.settings.accent))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 580, height: height)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }

        func renderComposer(app: AppModel, accountID: UUID) {
            let draft = GmailDraft(
                accountID: accountID,
                to: [GmailAddress(name: "Priya Sharma", email: "priya@client.com")],
                cc: [GmailAddress(name: "Sam", email: "sam@example.com")],
                subject: "Re: Q1 pricing proposal",
                bodyText: "Hi Priya,\n\nHere is the revised pricing for Q1. The annual plan stays at the agreed discount, and onboarding is included.\n\nBest,\nYou",
                bodyHTML: "<p>Hi Priya,</p><p>Here is the revised <b>pricing</b> for Q1. The annual plan stays at the agreed discount, and onboarding is included.</p><p>Best,<br>You</p>")
            let view = MailComposerView(model: app.mail, draft: draft)
                .environment(app)
                .environment(\.theme, Theme.resolved(dark: false, accent: app.settings.accent))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 680)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: directory.appendingPathComponent("44-mail-compose-light.png"))
        }

        func renderDictation(app: AppModel, dark: Bool) {
            let states: [(String, DictationPanelModel.State)] = [
                ("16-dictation-listening", .listening),
                ("17-dictation-transcribing", .transcribing),
                ("18-dictation-copied", .copied),
            ]
            for (name, state) in states {
                let model = DictationPanelModel()
                model.state = state
                model.level = 0.7
                let view = DictationPanelView(model: model)
                    .environment(\.theme, Theme.resolved(dark: dark, accent: app.settings.accent))
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 330, height: 68)
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                try? data.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }

        func mainWindow() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.title == "Tasks" }
                ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        }

        func pause() async {
            // Long enough for the 0.15–0.2s section/inspector transitions to settle.
            try? await Task.sleep(nanoseconds: 550_000_000)
        }
    }

    private static func write(window: NSWindow?, named name: String, into directory: URL) {
        guard let view = window?.contentView, view.bounds.width > 100, view.bounds.height > 100,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }
    /// A deterministic local Gmail cache for screenshots. It never connects to
    /// Google: the messages are values written straight into the throwaway store.
    private static func seedGmail(_ app: AppModel) -> UUID? {
        if let existing = app.gmailStore.accounts.first { return existing.id }
        let account = app.gmailStore.upsertAccount(
            GmailAccount(email: "you@example.com", displayName: "You",
                         lastSyncAt: Date()))
        let now = Date()
        func address(_ name: String, _ email: String) -> GmailAddress {
            GmailAddress(name: name, email: email)
        }
        func add(_ id: String, _ thread: String, from: GmailAddress,
                 subject: String, body: String, html: String? = nil,
                 daysAgo: Double = 0, labels: [String], attachments: [GmailAttachment] = []) {
            let message = GmailMessage(
                id: id, threadID: thread, accountID: account.id,
                labelIDs: labels, internalDate: now.addingTimeInterval(-daysAgo * 86_400),
                from: from, to: [address("You", "you@example.com")],
                subject: subject, snippet: body, bodyText: body, bodyHTML: html,
                attachments: attachments,
                rfcMessageID: "<\(id)@example.com>")
            app.gmailStore.cacheMessage(message)
        }
        add("g1", "gt1", from: address("Priya Sharma", "priya@client.com"),
            subject: "Q1 pricing proposal",
            body: "We discussed the Q1 pricing proposal and the annual discount. Can you confirm by Thursday?",
            html: "<p>We discussed the <b>Q1 pricing proposal</b> and the annual discount. Can you confirm by Thursday?</p><p>— Priya</p>",
            daysAgo: 0.2, labels: ["INBOX", "IMPORTANT"])
        add("g2", "gt1", from: address("You", "you@example.com"),
            subject: "Re: Q1 pricing proposal",
            body: "I will send the revised numbers today.",
            html: "<p>I will send the revised numbers today.</p>",
            daysAgo: 0.1, labels: ["SENT"])
        add("g3", "gt2", from: address("Sam Rivera", "sam@vendor.io"),
            subject: "Contract signature",
            body: "The contract is due tomorrow. The legal review is still blocked on the redlines.",
            daysAgo: 1.1, labels: ["INBOX", "UNREAD", "STARRED"],
            attachments: [GmailAttachment(id: "ga1", messageID: "g3", accountID: account.id,
                                          filename: "MSA.pdf", mimeType: "application/pdf",
                                          size: 184_320)])
        add("g4", "gt3", from: address("Maya Chen", "maya@team.co"),
            subject: "Onboarding follow-up",
            body: "Thanks for the onboarding meeting. I will prepare the checklist and share it by Friday.",
            daysAgo: 2.4, labels: ["INBOX", "UNREAD"])
        add("g5", "gt4", from: address("Product Digest", "noreply@digest.example"),
            subject: "Weekly product digest",
            body: "Ten links on design systems, research and local-first software.",
            daysAgo: 3.2, labels: ["INBOX"])
        add("g6", "gt5", from: address("Priya Sharma", "priya@client.com"),
            subject: "Re: Pilot scope",
            body: "The pilot scope looks good. We can start on the 1st.",
            daysAgo: 5.5, labels: ["INBOX"])
        app.gmailStore.replaceLabels([
            GmailLabel(id: "INBOX", name: "Inbox", type: "system", unreadCount: 4, totalCount: 6),
            GmailLabel(id: "SENT", name: "Sent", type: "system", totalCount: 1),
            GmailLabel(id: "Label_client", name: "Client", type: "user", unreadCount: 2, totalCount: 2),
            GmailLabel(id: "Label_finance", name: "Finance", type: "user", unreadCount: 1, totalCount: 1)
        ], accountID: account.id)
        app.mail.reload(reset: true)
        return account.id
    }

}
#endif
