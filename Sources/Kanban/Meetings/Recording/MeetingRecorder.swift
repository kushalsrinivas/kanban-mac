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
        /// Stopped, waiting for the user to choose PROCESS or SAVE LOCALLY.
        case awaitingDecision(meetingID: UUID, duration: TimeInterval, bytes: Int64)
    }

    private(set) var phase: Phase = .idle
    private(set) var sources = CaptureSources(microphone: .ready, systemAudio: .ready)
    private(set) var level: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastError: String?
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
    func stop() async {
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
            store.flush()
        }

        guard let meetingID, store.meeting(meetingID) != nil else {
            phase = .idle
            return
        }

        if let result, result.byteCount > 0 {
            store.updateMeeting(meetingID) {
                $0.duration = result.duration
                $0.status = .readyToProcess
            }
            phase = .awaitingDecision(meetingID: meetingID, duration: result.duration,
                                      bytes: result.byteCount)
        } else {
            // Nothing usable was captured; do not offer to upload an empty file.
            let reason = lastError ?? "No audio was captured."
            store.updateMeeting(meetingID) {
                $0.status = .failed
                $0.failureReason = reason
            }
            lastError = reason
            phase = .idle
        }
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
        phase = .idle
        store.flush()
    }

    /// Discards the recording entirely, including the file.
    func discard() async {
        let meetingID = currentMeetingID ?? {
            if case .awaitingDecision(let id, _, _) = phase { return id }
            return nil
        }()
        await engine.cancel()
        if let meetingID {
            if let filename = store.meeting(meetingID)?.audioFilename {
                try? FileManager.default.removeItem(at: KanbanPaths.recordingURL(filename: filename))
            }
            store.deleteMeeting(meetingID)
        }
        currentMeetingID = nil
        phase = .idle
        level = 0
        elapsed = 0
        store.flush()
    }

    /// The user chose SAVE LOCALLY: keep the audio, never upload it.
    func keepLocal() {
        guard case .awaitingDecision(let meetingID, _, _) = phase else { return }
        store.updateMeeting(meetingID) { $0.status = .localOnly }
        phase = .idle
        title = ""
    }

    /// Clears the decision prompt after the caller has kicked off processing.
    func acknowledgeDecision() {
        phase = .idle
        title = ""
    }

    // MARK: AudioCaptureDelegate

    // These arrive from audio threads as well as the main queue, so they hop rather
    // than assert. Asserting here is what crashed the app the moment recording began.
    nonisolated func captureDidUpdate(level: Float, elapsed: TimeInterval) {
        Task { @MainActor in
            self.level = level
            self.elapsed = elapsed
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
