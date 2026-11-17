import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import OSLog

/// Handy's dictation flow, reduced to this app: a global hotkey opens a small
/// floating card, the mic is captured, the same whisper engine transcribes it,
/// and the text lands on the clipboard.
///
/// It toggles rather than holding to talk: the permission-free Carbon hotkey has
/// no key-up, so the take ends on two seconds of silence or on a second press.
/// Capture reuses the meeting recorder's mic engine, so there is one audio graph,
/// one writer and one permission path in the app.
@MainActor
@Observable
final class DictationController {

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
    }

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    /// False when another app already owns the shortcut.
    private(set) var hotKeyAvailable = true

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: TranscriptionEngine
    @ObservationIgnored private let catalog: ModelCatalog?
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private let capture = SystemAudioCaptureEngine()
    @ObservationIgnored private let panel = DictationPanel()
    @ObservationIgnored private var silence = DictationSilenceDetector(threshold: 0.05)
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var hideWork: Task<Void, Never>?
    @ObservationIgnored private var active: (entry: ModelCatalog.Entry, model: URL, take: URL)?
    @ObservationIgnored private var lastElapsed: TimeInterval = 0
    @ObservationIgnored private var captureFailure: String?
    @ObservationIgnored private let log = Logger(subsystem: "com.kanban.app", category: "dictation")

    /// ⌃⌥Space: unused by macOS, safe to take system-wide, and one hand.
    let hotKeyLabel = "⌃⌥SPACE"

    init(settings: AppSettings, engine: TranscriptionEngine, catalog: ModelCatalog?) {
        self.settings = settings
        self.engine = engine
        self.catalog = catalog
        capture.delegate = self
    }

    // MARK: Hotkey

    func setEnabled(_ enabled: Bool) {
        hideWork?.cancel()
        if enabled {
            hotKeyAvailable = hotKey.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey | optionKey)) { [weak self] in
                    self?.toggle()
                }
            if !hotKeyAvailable {
                lastError = "⌃⌥Space is already used by another app."
                log.error("dictation hotkey is unavailable")
            }
        } else {
            hotKey.unregister()
            hotKeyAvailable = true
            if phase != .idle { cancel() }
        }
    }

    /// Hotkey and the Settings TRY button both land here.
    func toggle() {
        switch phase {
        case .idle: start()
        case .listening: finish()
        case .transcribing: break
        }
    }

    // MARK: Recording

    private func start() {
        guard phase == .idle else { return }
        guard let resolved = catalog.flatMap({
            ModelStorage.resolve(in: $0, preferred: settings.transcriptionModelID)
        }) else {
            fail("Download a speech model in Settings → Local AI.")
            return
        }
        work = Task { [weak self] in
            guard let self else { return }
            let request = CaptureRequest(microphone: true, systemAudio: false)
            let sources = await self.capture.requestPermissions(request)
            guard sources.microphone.isWorking else {
                self.fail(sources.microphone.detail
                          ?? "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.")
                return
            }
            self.begin(resolved)
        }
    }

    private func begin(_ resolved: (entry: ModelCatalog.Entry, url: URL)) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-dictation-\(UUID().uuidString).m4a")
        silence = DictationSilenceDetector(threshold: 0.05)
        lastError = nil
        lastElapsed = 0
        captureFailure = nil
        active = (resolved.entry, resolved.url, file)
        phase = .listening
        panel.show(.listening, level: 0, theme: theme)
        log.info("dictation began")

        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start(
                    to: file,
                    request: CaptureRequest(microphone: true, systemAudio: false))
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func finish() {
        guard phase == .listening, let active else { return }
        // Whisper invents a sentence from room noise. Only run it when the take
        // actually crossed the speech threshold.
        guard silence.speech >= silence.minimumSpeech else {
            try? FileManager.default.removeItem(at: active.take)
            self.active = nil
            fail("Nothing was heard.")
            return
        }
        phase = .transcribing
        panel.show(.transcribing, level: 0, theme: theme)
        let vocabulary = settings.vocabularyList
        let failureBeforeStop = captureFailure
        self.work = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: active.take) }
            do {
                let captured = try await self.capture.stop()
                if let failureBeforeStop {
                    throw TranscriptionError.engine(failureBeforeStop)
                }
                guard captured.peakLevel > 0 else {
                    throw TranscriptionError.engine(
                        "No audio was captured. Check the microphone in Settings.")
                }
                let pcm = try await Task.detached(priority: .userInitiated) {
                    try AudioPCM.decode(url: captured.fileURL)
                }.value
                let result = try await self.engine.transcribe(
                    pcm: pcm,
                    entry: active.entry,
                    modelURL: active.model,
                    vadModelURL: nil,
                    vocabulary: vocabulary)
                guard !Task.isCancelled else { return }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.fail("Nothing was heard.")
                    return
                }
                self.copy(text)
                self.log.info("dictation copied \(text.count, privacy: .public) characters")
                self.active = nil
                self.phase = .idle
                self.panel.show(.copied, level: 0, theme: self.theme)
                self.scheduleHide(after: 1.4)
            } catch let error as TranscriptionError where error == .cancelled {
                self.phase = .idle
                self.panel.hide()
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if let active {
            Task { await capture.cancel() }
            try? FileManager.default.removeItem(at: active.take)
        }
        active = nil
        phase = .idle
        panel.hide()
    }

    // MARK: Output

    private func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func fail(_ message: String) {
        lastError = message
        log.error("dictation failed: \(message, privacy: .public)")
        if let active {
            try? FileManager.default.removeItem(at: active.take)
        }
        active = nil
        phase = .idle
        // A failed start can leave capture running; stop it without offering a file.
        Task { await capture.cancel() }
        panel.show(.failed(message), level: 0, theme: theme)
        scheduleHide(after: 3.5)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        hideWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.panel.hide()
        }
    }

    private var theme: Theme {
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Theme.resolved(dark: settings.isDark(systemIsDark: systemDark),
                              accent: settings.accent)
    }
}

// MARK: - Capture callbacks

extension DictationController: AudioCaptureDelegate {

    func captureDidUpdate(level: Float, elapsed: TimeInterval) {
        guard phase == .listening else { return }
        panel.update(level: level)
        // The engine posts about ten times a second; the delta keeps the silence
        // clock honest even if a post is dropped.
        let seconds = max(0, elapsed - lastElapsed)
        lastElapsed = elapsed
        if silence.add(level: level, seconds: seconds) {
            finish()
        }
    }

    func captureSourcesDidChange(_ sources: CaptureSources) {
        guard phase == .listening, !sources.microphone.isWorking else { return }
        captureFailure = sources.microphone.detail ?? "The microphone stopped working."
        finish()
    }

    func captureDidFail(_ error: CaptureError) {
        captureFailure = error.localizedDescription
    }
}
