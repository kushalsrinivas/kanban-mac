import Foundation
import Observation

/// Gets a finished recording to the VPS and follows the job until results come back.
///
/// Nothing is uploaded until the user explicitly asks for it. If the VPS is
/// unreachable the recording stays on disk and is retried when the connection returns —
/// a meeting is never lost because the network was down.
@Observable
@MainActor
final class MeetingProcessor {

    struct Progress: Equatable {
        var meetingID: UUID
        var status: MeetingStatus
        /// Upload fraction, 0...1, only meaningful while `status == .uploading`.
        var uploadFraction: Double = 0
        var detail: String?
    }

    private(set) var active: [UUID: Progress] = [:]
    private(set) var lastError: String?

    private let store: LocalStore
    private let client: APIClient
    private let settings: AppSettings
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Bumped by every PROCESS and CANCEL. A cancelled run that is still unwinding
    /// uses its old generation and can no longer write meeting state, so a second
    /// upload cannot race the first one's teardown.
    private var generations: [UUID: UInt64] = [:]

    /// Called when a meeting finishes processing, so the UI can jump to the results.
    var onCompleted: ((Meeting) -> Void)?

    /// The on-device engine and its catalog; nil only if the bundled catalog
    /// failed to decode, which surfaces as a model-missing error.
    private let engine: TranscriptionEngine
    private let catalog: ModelCatalog?

    init(store: LocalStore, client: APIClient, settings: AppSettings,
         engine: TranscriptionEngine, catalog: ModelCatalog?) {
        self.store = store
        self.client = client
        self.settings = settings
        self.engine = engine
        self.catalog = catalog
    }

    func progress(for id: UUID) -> Progress? { active[id] }
    var isBusy: Bool { !active.isEmpty }

    // MARK: Entry points

    /// The user pressed PROCESS.
    func process(_ meetingID: UUID) {
        guard tasks[meetingID] == nil else { return }
        generations[meetingID, default: 0] &+= 1
        let generation = generations[meetingID]!
        tasks[meetingID] = Task { [weak self] in
            await self?.run(meetingID, generation: generation)
            self?.finish(meetingID, generation: generation)
        }
    }

    /// Retries everything recorded but never uploaded. Called when the app regains a
    /// connection, not on a timer.
    ///
    /// Only `.readyToProcess` is picked up. `.failed` is a permanent failure the user
    /// has to retry explicitly — re-uploading it on every activation would never
    /// succeed and would keep hammering the server with the same bad recording.
    func processPending() {
        for meeting in store.meetingsAwaitingUpload where meeting.status == .readyToProcess {
            process(meeting.id)
        }
    }

    func cancel(_ meetingID: UUID) {
        generations[meetingID, default: 0] &+= 1
        tasks[meetingID]?.cancel()
        // A decode owns the engine while it runs, so stopping it has to reach
        // the engine's cancellation token, not just the Swift task.
        Task { engine.cancel() }
        tasks[meetingID] = nil
        active[meetingID] = nil
        store.updateMeeting(meetingID) {
            if $0.status.isProcessing { $0.status = .readyToProcess }
        }
    }

    private func finish(_ meetingID: UUID, generation: UInt64) {
        guard isCurrent(meetingID, generation) else { return }
        tasks[meetingID] = nil
    }

    private func isCurrent(_ meetingID: UUID, _ generation: UInt64) -> Bool {
        generations[meetingID] == generation
    }

    /// Throws when CANCEL (or a newer PROCESS) superseded this run while it awaited.
    private func ensureCurrent(_ meetingID: UUID, _ generation: UInt64) throws {
        guard isCurrent(meetingID, generation) else { throw CancellationError() }
    }

    // MARK: Pipeline

    private func run(_ meetingID: UUID, generation: UInt64) async {
        guard isCurrent(meetingID, generation), let meeting = store.meeting(meetingID) else { return }
        guard let filename = meeting.audioFilename else {
            fail(meetingID, "The recording file is missing.")
            return
        }
        let fileURL = KanbanPaths.recordingURL(filename: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            fail(meetingID, "The recording file is missing from disk.")
            return
        }

        // Local first: it needs no server and keeps the audio on this Mac.
        // A speech model is all transcription needs; the Gemini key only adds
        // the analysis step.
        let local = catalog.flatMap {
            ModelStorage.resolve(in: $0, preferred: settings.transcriptionModelID)
        }
        if let local {
            do {
                try await runLocal(meeting: meeting, fileURL: fileURL,
                                   entry: local.entry, modelURL: local.url,
                                   meetingID: meetingID, generation: generation)
                try ensureCurrent(meetingID, generation)
                cleanupAudio(meetingID: meetingID, filename: filename)
                clearActive(meetingID, generation: generation)
                if isCurrent(meetingID, generation), let finished = store.meeting(meetingID) {
                    onCompleted?(finished)
                }
            } catch is CancellationError {
                clearActive(meetingID, generation: generation)
            } catch let error as LocalAIError {
                if isCurrent(meetingID, generation) {
                    fail(meetingID, error.localizedDescription, transient: error.isTransient)
                }
            } catch let error as TranscriptionError {
                if isCurrent(meetingID, generation) {
                    fail(meetingID, error.localizedDescription, transient: error.isTransient)
                }
            } catch {
                if isCurrent(meetingID, generation) { fail(meetingID, "\(error)") }
            }
            return
        }

        // No model on disk. With a Gemini key the user asked for local work, so
        // say what is missing instead of silently uploading to a server.
        if settings.hasGeminiKey {
            fail(meetingID, TranscriptionError
                .modelMissing(catalog?.entry(settings.transcriptionModelID)?.name ?? "speech")
                .localizedDescription)
            return
        }

        guard await client.isConfigured else {
            if isCurrent(meetingID, generation) {
                fail(meetingID, "Download a speech model in Settings → Local AI to transcribe on this Mac.")
            }
            return
        }

        do {
            // 1. Register the meeting server-side.
            set(meetingID, .queued)
            let remote = try await client.createMeeting(CreateMeetingBody(
                id: meetingID.uuidString,
                title: meeting.title,
                startedAt: DateInput.iso(meeting.startedAt),
                duration: meeting.duration))
            try ensureCurrent(meetingID, generation)
            store.updateMeeting(meetingID) { $0.remoteID = remote.id }

            // 2. Upload the audio.
            set(meetingID, .uploading)
            try await client.uploadAudio(meetingID: remote.id, fileURL: fileURL) { [weak self] fraction in
                Task { @MainActor in
                    self?.setUploadFraction(meetingID, fraction, generation: generation)
                }
            }
            try ensureCurrent(meetingID, generation)
            store.updateMeeting(meetingID) { $0.uploadedAt = Date() }

            // 3. Ask the backend to process it. Returns a job, not a result.
            let job = try await client.processMeeting(remote.id)
            try ensureCurrent(meetingID, generation)
            store.updateMeeting(meetingID) { $0.jobID = job.id }

            // 4. Follow the job.
            try await follow(job: job, meetingID: meetingID, remoteID: remote.id,
                             generation: generation)

            // 5. Pull the finished meeting and clean up the transport file.
            try await fetchResults(meetingID: meetingID, remoteID: remote.id,
                                   generation: generation)
            try ensureCurrent(meetingID, generation)
            cleanupAudio(meetingID: meetingID, filename: filename)

            clearActive(meetingID, generation: generation)
            if isCurrent(meetingID, generation), let finished = store.meeting(meetingID) {
                onCompleted?(finished)
            }

        } catch is CancellationError {
            clearActive(meetingID, generation: generation)
        } catch let error as APIError {
            if isCurrent(meetingID, generation) {
                fail(meetingID, error.localizedDescription, transient: error.isTransient)
            }
        } catch {
            if isCurrent(meetingID, generation) { fail(meetingID, "\(error)") }
        }
    }

    /// Transcription on this Mac. Never uploads the recording. Analysis follows
    /// only when a Gemini key is configured; without one the meeting finishes
    /// with its transcript and no summary.
    private func runLocal(meeting: Meeting, fileURL: URL,
                          entry: ModelCatalog.Entry, modelURL: URL,
                          meetingID: UUID, generation: UInt64) async throws {
        let vadURL = catalog?.vadEntry.flatMap(ModelStorage.installedURL(for:))

        set(meetingID, .transcribing, detail: "Reading the recording…")
        let pcm = try await Task.detached(priority: .userInitiated) {
            try AudioPCM.decode(url: fileURL)
        }.value
        try ensureCurrent(meetingID, generation)

        let result = try await engine.transcribe(
            pcm: pcm,
            entry: entry,
            modelURL: modelURL,
            vadModelURL: vadURL,
            vocabulary: settings.vocabularyList) { [weak self] fraction, detail in
                Task { @MainActor in
                    self?.setProgress(meetingID, fraction, detail, generation: generation)
                }
            }
        try ensureCurrent(meetingID, generation)

        setDetail(meetingID, "Saving transcript…", generation: generation)
        store.saveTranscript(result.segments, for: meetingID)
        store.updateMeeting(meetingID) {
            $0.duration = max($0.duration, result.segments.last?.end ?? 0)
        }

        guard settings.hasGeminiKey else {
            // Transcript only: still a finished meeting, just without analysis.
            store.updateMeeting(meetingID) {
                $0.status = .completed
                $0.processedAt = Date()
                $0.failureReason = nil
            }
            return
        }

        set(meetingID, .analyzing, detail: "Analysing with Gemini…")
        let client = GeminiClient(apiKey: settings.geminiAPIKey, model: settings.geminiModel)
        let analysis = try await client.analyseMeeting(
            title: meeting.title,
            startedAt: meeting.startedAt,
            duration: store.meeting(meetingID)?.duration ?? meeting.duration,
            transcript: result.text)
        try ensureCurrent(meetingID, generation)
        apply(analysis, to: meetingID, segments: result.segments)
    }

    private func setProgress(_ meetingID: UUID, _ fraction: Double, _ detail: String,
                             generation: UInt64) {
        guard isCurrent(meetingID, generation), var progress = active[meetingID] else { return }
        progress.uploadFraction = fraction
        progress.detail = detail
        active[meetingID] = progress
    }

    private func setDetail(_ meetingID: UUID, _ detail: String, generation: UInt64) {
        guard isCurrent(meetingID, generation), var progress = active[meetingID] else { return }
        progress.detail = detail
        active[meetingID] = progress
    }

    private func apply(_ analysis: MeetingAnalysis, to meetingID: UUID,
                       segments: [TranscriptSegment]) {
        guard let meeting = store.meeting(meetingID) else { return }
        // Preserve decisions the user already made; the new analysis only adds
        // suggestions. Matching by title is the same rule the server uses.
        let decided = meeting.actionItems.filter { $0.state != .suggested }
        let decidedTitles = Set(decided.map { $0.title.trimmingCharacters(in: .whitespaces).lowercased() })
        var items = decided
        for suggestion in analysis.actionItems {
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  !decidedTitles.contains(title.lowercased()) else { continue }
            items.append(ActionItem(
                meetingID: meetingID,
                title: String(title.prefix(500)),
                assignee: suggestion.assignee,
                dueDate: suggestion.dueDate.flatMap { DateInput.parse($0) },
                confidence: min(1, max(0, suggestion.confidence ?? 0)),
                state: .suggested,
                position: Double(items.count),
                quote: suggestion.quote?.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        store.updateMeeting(meetingID) {
            $0.summary = analysis.summary
            $0.keyPoints = analysis.keyPoints
            $0.decisions = analysis.decisions
            $0.questions = analysis.questions
            $0.topics = analysis.topics
            $0.participants = analysis.participants
            $0.actionItems = items
            $0.status = .completed
            $0.processedAt = Date()
            $0.failureReason = nil
        }

        // Link each quote to the segment that said it, so a commitment can be
        // played back instead of trusted as a paraphrase.
        if let finished = store.meeting(meetingID) {
            store.upsertMeeting(MeetingMemory.attachSources(to: finished, segments: segments))
        }
    }

    /// Follows job state over SSE, falling back to polling if the stream will not open.
    private func follow(job: JobDTO, meetingID: UUID, remoteID: String,
                        generation: UInt64) async throws {
        if let stream = await sseStream(jobID: job.id) {
            do {
                for try await update in stream.decoded(JobDTO.self) {
                    if Task.isCancelled { throw CancellationError() }
                    try ensureCurrent(meetingID, generation)
                    apply(update, to: meetingID)
                    if update.meetingStatus == .completed { return }
                    if update.meetingStatus == .failed {
                        throw APIError.server(500, update.error ?? "processing failed")
                    }
                }
                // Stream ended without a terminal event; confirm by polling once.
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError {
                throw error
            } catch let failure as SSEClient.Failure {
                // An expired token must read as "re-authenticate", not as a stream
                // problem that silently degrades to polling.
                if case .http(let code) = failure, code == 401 || code == 403 {
                    throw APIError.unauthorized
                }
                // SSE unavailable or dropped — fall through to polling.
            } catch {
                // SSE unavailable or dropped — fall through to polling.
            }
        }
        try await poll(jobID: job.id, meetingID: meetingID, generation: generation)
    }

    private func sseStream(jobID: String) async -> SSEClient? {
        guard let config = await client.currentConfiguration else { return nil }
        let url = config.apiRoot.appendingPathComponent("jobs/\(jobID)/events")
        return SSEClient(url: url, token: config.token)
    }

    /// Fallback progress. Intentionally slow — this only runs when SSE is unavailable,
    /// and a transcription job takes minutes, not milliseconds.
    private func poll(jobID: String, meetingID: UUID, generation: UInt64) async throws {
        let deadline = Date().addingTimeInterval(3 * 3600)
        var interval: UInt64 = 3
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            try ensureCurrent(meetingID, generation)
            let job = try await client.job(jobID)
            try ensureCurrent(meetingID, generation)
            apply(job, to: meetingID)
            switch job.meetingStatus {
            case .completed: return
            case .failed: throw APIError.server(500, job.error ?? "processing failed")
            default: break
            }
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            interval = min(interval * 2, 20)   // back off to one check every 20s
        }
        throw APIError.server(504, "processing did not finish in time")
    }

    private func fetchResults(meetingID: UUID, remoteID: String, generation: UInt64) async throws {
        let dto = try await client.getMeeting(remoteID)
        try ensureCurrent(meetingID, generation)
        guard let merged = dto.merged(into: store.meeting(meetingID)) else { return }
        store.upsertMeeting(merged)
        if !merged.transcript.isEmpty {
            store.saveTranscript(merged.transcript, for: meetingID)
        }
        store.updateMeeting(meetingID) {
            $0.status = .completed
            $0.processedAt = Date()
            $0.failureReason = nil
        }
    }

    /// The temporary file exists for transport. Unless the user asked to keep
    /// originals, it goes as soon as the server has the results.
    private func cleanupAudio(meetingID: UUID, filename: String) {
        guard !settings.keepRecordings else { return }
        try? FileManager.default.removeItem(at: KanbanPaths.recordingURL(filename: filename))
        store.updateMeeting(meetingID) { $0.audioFilename = nil }
    }

    // MARK: State

    private func set(_ meetingID: UUID, _ status: MeetingStatus, detail: String? = nil) {
        active[meetingID] = Progress(meetingID: meetingID, status: status,
                                     uploadFraction: active[meetingID]?.uploadFraction ?? 0,
                                     detail: detail)
        store.updateMeeting(meetingID) { $0.status = status }
    }

    private func setUploadFraction(_ meetingID: UUID, _ fraction: Double, generation: UInt64) {
        guard isCurrent(meetingID, generation), var progress = active[meetingID] else { return }
        progress.uploadFraction = fraction
        active[meetingID] = progress
    }

    private func clearActive(_ meetingID: UUID, generation: UInt64) {
        guard isCurrent(meetingID, generation) else { return }
        active[meetingID] = nil
    }

    private func apply(_ job: JobDTO, to meetingID: UUID) {
        guard let status = job.meetingStatus else { return }
        set(meetingID, status, detail: job.error)
    }

    private func fail(_ meetingID: UUID, _ message: String, transient: Bool = false) {
        lastError = message
        active[meetingID] = nil
        store.updateMeeting(meetingID) {
            // A transient failure keeps the recording queued for a later retry.
            $0.status = transient ? .readyToProcess : .failed
            $0.failureReason = message
        }
    }
}
