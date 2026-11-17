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

            app.section = .agent
            await pause()
            await capture("07-agent-light")

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
}
#endif
