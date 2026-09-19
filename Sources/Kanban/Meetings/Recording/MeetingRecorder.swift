import Foundation
import Observation

/// Owns the recording lifecycle and nothing else.
///
/// Recording only ever starts because the user pressed a button. There is no
/// auto-detection, no scheduled capture and no background listening — the engine is
/// only ever running between an explicit START and an explicit STOP.
@Observable
@MainActor
final class MeetingRecorder: AudioCaptureDelegate {

    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case paused
    }

    /// What a finished recording left behind. Returned from `stop()` so the caller
    /// can file it and start the upload without re-reading the store.
    struct Finished: Equatable {
        var meetingID: UUID
        var duration: TimeInterval
        var bytes: Int64
        /// Not one non-zero sample was captured — see `CaptureResult.isSilent`.
        var wasSilent: Bool
    }

    private(set) var phase: Phase = .idle
    /// The most recent recording, kept so the panel can show what just happened.
    private(set) var lastFinished: Finished?
    private(set) var sources = CaptureSources(microphone: .ready, systemAudio: .ready)
    private(set) var level: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastError: String?
    /// Shown live while recording when the tap delivers only zeroes. macOS hands
    /// out silence rather than an error for a muted / wrong / volume-0 input, so
    /// without this the panel reads ACTIVE while nothing arrives.
    private(set) var noSignalHint: String?
    private var silentSince: TimeInterval?
    /// The meeting row being recorded into, so the menu bar and widget can show it.
    private(set) var currentMeetingID: UUID?

    var title: String = ""

    private let store: LocalStore
    private let engine: AudioCaptureEngine
    private let settings: AppSettings

    init(store: LocalStore, settings: AppSettings, engine: AudioCaptureEngine? = nil) {
        self.store = store
        self.settings = settings
        self.engine = engine ?? SystemAudioCaptureEngine()
        self.engine.delegate = self
    }

    var isRecording: Bool { phase == .recording || phase == .paused }

    private var captureRequest: CaptureRequest {
        CaptureRequest(microphone: settings.captureMicrophone,
                       systemAudio: settings.captureSystemAudio)
    }

    // MARK: Pre-flight

    /// Checks permission state without prompting, for the READY display.
    func probe() async {
        sources = await SystemAudioCaptureEngine.probeSources(captureRequest)
    }

    /// Triggers the actual system prompts.
    ///
    /// macOS only lists an app under Privacy & Security once it has asked, so this
    /// is what makes Kanban appear in the Microphone and Screen Recording lists.
    /// Offered from Settings so permissions can be sorted out before a meeting
    /// starts, rather than at the moment the user presses record.
    @discardableResult
    func requestPermissions() async -> CaptureSources {
        lastError = nil
        sources = await engine.requestPermissions(captureRequest)
        return sources
    }

    /// True when something still needs granting before a recording would capture audio.
    var needsPermission: Bool {
        (settings.captureMicrophone && !sources.microphone.isWorking)
            || (settings.captureSystemAudio && !sources.systemAudio.isWorking)
    }

    // MARK: Control

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing
        lastError = nil
        lastFinished = nil

        let meetingID = UUID()
        let startedAt = Date()
        let filename = "\(meetingID.uuidString).m4a"
        KanbanPaths.ensureRecordingsDirectory()

        do {
            try await engine.start(to: KanbanPaths.recordingURL(filename: filename),
                                   request: captureRequest)
        } catch {
            phase = .idle
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return
        }

        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Meeting.defaultTitle(at: startedAt)
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        store.upsertMeeting(Meeting(
            id: meetingID,
            title: resolvedTitle,
            startedAt: startedAt,
            duration: 0,
            status: .recording,
            audioFilename: filename
        ))

        currentMeetingID = meetingID
        sources = engine.sources
        elapsed = 0
        noSignalHint = nil
        silentSince = nil
        phase = .recording
        store.flush(recording: .init(title: resolvedTitle, startedAt: startedAt))
    }

    func pause() {
        guard phase == .recording else { return }
        do {
            try engine.pause()
            phase = .paused
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func resume() {
        guard phase == .paused else { return }
        do {
            try engine.resume()
            phase = .recording
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Stops and always leaves the recorder in a usable state.
    ///
    /// This deliberately does not bail out when `isRecording` is false. If the engine
    /// and the UI ever disagree — a failed start, a stream that died — an early
    /// return would strand the user in a recording state with no way out. Whatever
    /// the engine's opinion, we tear down and settle the phase.
    ///
    /// The recording is kept on disk either way. Returns what was captured so the
    /// caller can hand it to the processor; `nil` means there is nothing to upload.
    @discardableResult
    func stop() async -> Finished? {
        let meetingID = currentMeetingID
        var result: CaptureResult?

        do {
            result = try await engine.stop()
        } catch {
            // Not fatal. Force the engine down so no capture is left running.
            await engine.cancel()
            if isRecording {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }

        defer {
            currentMeetingID = nil
            level = 0
            noSignalHint = nil
            silentSince = nil
            phase = .idle
            title = ""
            store.flush()
        }

        guard let meetingID, store.meeting(meetingID) != nil else { return nil }

        guard let result, result.byteCount > 0 else {
            // Nothing usable was captured; do not offer to upload an empty file.
            let reason = lastError ?? "No audio was captured."
            store.updateMeeting(meetingID) {
                $0.status = .failed
                $0.failureReason = reason
            }
            lastError = reason
            return nil
        }

        // A capture path that fails tends to fail silently rather than loudly: a muted
        // or misrouted input, or a mixer quietly refusing a format, all produce a
        // full-length file of zeroes. That is far more likely than a genuinely silent
        // room, so say so instead of sending it off to transcribe nothing.
        let silenceNote = result.isSilent ? Self.silenceAdvice(sources) : nil

        store.updateMeeting(meetingID) {
            $0.duration = result.duration
            $0.status = .readyToProcess
            $0.failureReason = silenceNote
        }
        if let silenceNote { lastError = silenceNote }

        let finished = Finished(meetingID: meetingID, duration: result.duration,
                                bytes: result.byteCount, wasSilent: result.isSilent)
        lastFinished = finished
        return finished
    }

    /// What to tell someone whose recording came out as pure silence.
    private static func silenceAdvice(_ sources: CaptureSources) -> String {
        sources.microphone.isWorking
            ? "No audio was detected, though the microphone reported itself as recording. "
                + "Check that the right input is picked in System Settings › Sound › Input, "
                + "that it is not muted, and that Kanban is allowed under Privacy & Security › "
                + "Microphone."
            : "No audio was detected: nothing was capturing."
    }

    /// Escape hatch: tears everything down unconditionally and keeps whatever was
    /// written. Wired to the menu bar so a wedged recording is always recoverable.
    func forceStop() async {
        await engine.cancel()
        if let meetingID = currentMeetingID, store.meeting(meetingID) != nil {
            store.updateMeeting(meetingID) {
                $0.status = .failed
                $0.failureReason = "Recording was stopped manually."
            }
        }
        currentMeetingID = nil
        level = 0
        elapsed = 0
        noSignalHint = nil
        silentSince = nil
        phase = .idle
        store.flush()
    }

    /// Discards the recording entirely, including the file.
    func discard() async {
        let meetingID = currentMeetingID ?? lastFinished?.meetingID
        await engine.cancel()
        if let meetingID {
            if let filename = store.meeting(meetingID)?.audioFilename {
                try? FileManager.default.removeItem(at: KanbanPaths.recordingURL(filename: filename))
            }
            store.deleteMeeting(meetingID)
        }
        currentMeetingID = nil
        lastFinished = nil
        phase = .idle
        level = 0
        elapsed = 0
        noSignalHint = nil
        silentSince = nil
        store.flush()
    }

    /// Clears the summary of the last recording from the panel.
    func clearLastFinished() { lastFinished = nil }

    // MARK: AudioCaptureDelegate

    // These arrive from audio threads as well as the main queue, so they hop rather
    // than assert. Asserting here is what crashed the app the moment recording began.
    nonisolated func captureDidUpdate(level: Float, elapsed: TimeInterval) {
        Task { @MainActor in
            self.level = level
            self.elapsed = elapsed
            // macOS delivers zeroes — not errors — for a muted, volume-0, or wrong
            // input, so a flat meter while ACTIVE is the only live signal. ~10 Hz
            // updates, 5 s grace for a quiet room before saying anything.
            if self.phase == .recording, self.sources.microphone.isWorking {
                if level > 0.001 {
                    self.silentSince = nil
                    self.noSignalHint = nil
                } else {
                    if self.silentSince == nil { self.silentSince = elapsed }
                    else if elapsed - (self.silentSince ?? elapsed) > 5, self.noSignalHint == nil {
                        self.noSignalHint = Self.silenceAdvice(self.sources)
                    }
                }
            }
        }
    }

    nonisolated func captureSourcesDidChange(_ sources: CaptureSources) {
        Task { @MainActor in self.sources = sources }
    }

    nonisolated func captureDidFail(_ error: CaptureError) {
        Task { @MainActor in
            if case .systemAudioStopped = error {
                // Not fatal: note it and keep the microphone running.
                self.lastError = error.errorDescription
            } else {
                self.lastError = error.errorDescription
            }
        }
    }
}
