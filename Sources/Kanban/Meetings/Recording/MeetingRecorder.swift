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

    func stop() async {
        guard isRecording, let meetingID = currentMeetingID else { return }
        do {
            let result = try await engine.stop()
            store.updateMeeting(meetingID) {
                $0.duration = result.duration
                $0.status = .readyToProcess
            }
            phase = .awaitingDecision(meetingID: meetingID, duration: result.duration,
                                      bytes: result.byteCount)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            store.updateMeeting(meetingID) {
                $0.status = .failed
                $0.failureReason = self.lastError
            }
            phase = .idle
        }
        currentMeetingID = nil
        level = 0
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

    nonisolated func captureDidUpdate(level: Float, elapsed: TimeInterval) {
        MainActor.assumeIsolated {
            self.level = level
            self.elapsed = elapsed
        }
    }

    nonisolated func captureSourcesDidChange(_ sources: CaptureSources) {
        MainActor.assumeIsolated { self.sources = sources }
    }

    nonisolated func captureDidFail(_ error: CaptureError) {
        MainActor.assumeIsolated { self.lastError = error.errorDescription }
    }
}
