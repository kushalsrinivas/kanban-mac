import SwiftUI

enum KanbanWindow {
    static let board = "board"
}

@main
struct KanbanApp: App {
    @State private var app = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Tasks", id: KanbanWindow.board) {
            RootView()
                .environment(app)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear {
                    app.start()
                    delegate.model = app
                }
                .onOpenURL { url in app.handle(url: url) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1160, height: 760)
        .commands { KanbanCommands(app: app) }

        MenuBarExtra {
            MenuBarView().environment(app)
        } label: {
            // A drawn glyph rather than an asset: three stacked bars, one filled —
            // reads as a board at 16pt and costs nothing to render.
            Image(nsImage: MenuBarIcon.image(recording: app.recorder.isRecording))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(app)
        }
    }
}

// MARK: - Menus and shortcuts

struct KanbanCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { app.newTask() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("Command Palette") { app.isPaletteOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Search") { app.toggleSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button(app.recorder.isRecording ? "Stop Recording" : "Record Meeting") {
                app.recorder.isRecording ? app.stopRecording() : app.startRecording()
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Ask Agent") { app.section = .agent }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Compose Mail") { app.composeMail() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            Button("Tasks") { app.section = .tasks }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Meetings") { app.section = .meetings }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Mail") { app.section = .mail }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Meet") { app.section = .calendar }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Button("Agent") { app.section = .agent }
                .keyboardShortcut("5", modifiers: [.command, .option])
            Divider()
            Button("Sync Now") { Task { await app.connect() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Board") {
            ForEach(Array(TaskStatus.allCases.enumerated()), id: \.element) { index, column in
                Button("Go to \(column.label.capitalized)") { app.focus(status: column) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            ForEach(Array(TaskStatus.allCases.enumerated()), id: \.element) { index, column in
                Button("Move Task to \(column.label.capitalized)") { app.moveSelection(to: column) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .shift])
                    .disabled(app.selection == nil)
            }
            Divider()
            Button("Complete Task") { app.completeSelection() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(app.selection == nil)
            Button("Archive Task") { app.archiveSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(app.selection == nil)
            Button(app.undoLabel) { app.undoLast() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!app.canUndo)
            Divider()
            Button("Move Up") { app.shiftSelection(up: true) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(app.selection == nil)
            Button("Move Down") { app.shiftSelection(up: false) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(app.selection == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Kanban Help") {
                app.isPaletteOpen = true
            }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting while a meeting is being recorded needs to wait: the audio file's
    /// trailing frames are only flushed when the engine stops, and a detached Task
    /// from `applicationWillTerminate` never gets to run before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = MainActor.assumeIsolated { self.model }
        guard let model, model.recorder.isRecording else { return .terminateNow }
        // A second ⌘Q while the first stop is unwinding must not reply twice.
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        Task { @MainActor in
            // A task group would still wait for the stop task at scope exit, which
            // is the hang this watchdog exists to break. Race a continuation instead.
            let once = Once()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let stop = Task { @MainActor in
                    await model.shutdownAndWait()
                    once.run { continuation.resume() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    once.run {
                        stop.cancel()
                        continuation.resume()
                    }
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Make sure the widget and menu bar see the latest state when we go to the background.
        MainActor.assumeIsolated { model?.store.flush() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // One connectivity check per activation, rather than a background poll.
        MainActor.assumeIsolated { model?.applicationDidActivate() }
    }
}

// MARK: - One-shot

/// Runs a continuation exactly once, whichever of the stop or timeout wins.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { body() }
    }
}

// MARK: - Menu bar icon

enum MenuBarIcon {
    /// Cached: MenuBarExtra re-evaluates its label on every state change, and there
    /// are only two icons to draw.
    private static var cache: [Bool: NSImage] = [:]

    @MainActor
    static func image(recording: Bool) -> NSImage {
        if let cached = cache[recording] { return cached }

        let size = NSSize(width: 15, height: 13)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            if recording {
                // A filled dot while recording: unmistakable in the menu bar.
                let d: CGFloat = 9
                NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2,
                                            width: d, height: d)).fill()
            } else {
                let columnWidth: CGFloat = 3
                let gap: CGFloat = 3
                let heights: [CGFloat] = [11, 8, 5]
                for (index, height) in heights.enumerated() {
                    let x = rect.minX + CGFloat(index) * (columnWidth + gap)
                    let bar = NSRect(x: x, y: rect.minY + 1, width: columnWidth, height: height)
                    NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true   // follows the menu bar's own appearance
        cache[recording] = image
        return image
    }
}
