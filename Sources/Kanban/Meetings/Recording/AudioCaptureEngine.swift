import Foundation

/// What a recording is capturing, and whether each source is actually working.
///
/// The UI shows this verbatim (MICROPHONE ON / SYSTEM AUDIO OFF), because silently
/// failing to capture half a meeting is the worst possible outcome here.
public struct CaptureSources: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready
        case active
        case unavailable(String)
        case denied
        case disabled

        public var label: String {
            switch self {
            case .ready: return "READY"
            case .active: return "ACTIVE"
            case .unavailable: return "UNAVAILABLE"
            case .denied: return "DENIED"
            case .disabled: return "OFF"
            }
        }

        public var isWorking: Bool { self == .active || self == .ready }

        /// The reason shown under the status when something is wrong.
        public var detail: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .denied: return "Permission not granted in System Settings."
            default: return nil
            }
        }
    }

    public var microphone: State
    public var systemAudio: State

    public init(microphone: State = .ready, systemAudio: State = .ready) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    /// True when nothing at all is being captured — recording would produce silence.
    public var isSilent: Bool { !microphone.isWorking && !systemAudio.isWorking }
}

/// What the user asked to capture, before permissions are taken into account.
public struct CaptureRequest: Equatable, Sendable {
    public var microphone: Bool
    public var systemAudio: Bool

    public init(microphone: Bool = true, systemAudio: Bool = true) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }
}

public struct CaptureResult: Sendable {
    public var fileURL: URL
    public var duration: TimeInterval
    public var byteCount: Int64
    /// Loudest sample seen anywhere in the recording.
    ///
    /// Exactly zero means the file is digital silence. macOS does not report a
    /// blocked microphone as an error — it hands out buffers of zeroes — so this is
    /// the only way to tell a quiet room from a mic that was never really open.
    public var peakLevel: Float

    public init(fileURL: URL, duration: TimeInterval, byteCount: Int64, peakLevel: Float) {
        self.fileURL = fileURL
        self.duration = duration
        self.byteCount = byteCount
        self.peakLevel = peakLevel
    }

    /// True when not one non-zero sample was captured.
    public var isSilent: Bool { peakLevel <= 0 }
}

public enum CaptureError: LocalizedError {
    case microphoneDenied
    case screenRecordingDenied
    case noSourcesAvailable
    case alreadyRecording
    case notRecording
    case engine(String)
    /// ScreenCaptureKit stopped — usually the user clicking "Stop Sharing" in the
    /// menu bar. The microphone keeps recording.
    case systemAudioStopped(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
        case .screenRecordingDenied:
            return "System audio needs Screen Recording permission in System Settings › Privacy & Security › Screen Recording."
        case .noSourcesAvailable:
            return "Neither the microphone nor system audio is available, so there is nothing to record."
        case .alreadyRecording:
            return "A recording is already running."
        case .notRecording:
            return "No recording is running."
        case .engine(let message):
            return message
        case .systemAudioStopped:
            return "System audio capture stopped. The microphone is still recording."
        }
    }
}

@MainActor
public protocol AudioCaptureDelegate: AnyObject {
    /// Called roughly 10×/second while recording with the current level (0...1)
    /// and elapsed time. Deliberately coarse: a 60fps meter is wasted CPU.
    func captureDidUpdate(level: Float, elapsed: TimeInterval)
    func captureSourcesDidChange(_ sources: CaptureSources)
    /// A source dropped out mid-recording. The recording continues on whatever is left.
    func captureDidFail(_ error: CaptureError)
}

/// The abstraction the meeting system is written against.
///
/// Nothing above this protocol knows about AVAudioEngine or ScreenCaptureKit, so the
/// capture implementation can be replaced — including with a chunked streaming
/// uploader — without touching the meeting flow.
@MainActor
public protocol AudioCaptureEngine: AnyObject {
    var delegate: AudioCaptureDelegate? { get set }
    var isRecording: Bool { get }
    var isPaused: Bool { get }
    var elapsed: TimeInterval { get }
    var sources: CaptureSources { get }

    /// Permission state without prompting, for the pre-flight display.
    static func probeSources(_ request: CaptureRequest) async -> CaptureSources
    /// Prompts for anything not yet granted. Returns what will actually be captured.
    func requestPermissions(_ request: CaptureRequest) async -> CaptureSources

    func start(to url: URL, request: CaptureRequest) async throws
    func pause() throws
    func resume() throws
    func stop() async throws -> CaptureResult
    /// Stops capture and flushes the writer, but keeps the partial file.
    ///
    /// Used when `stop()` failed or the user forced a wedged recording to end: whatever
    /// reached disk is recoverable, and deleting it would lose the meeting.
    func closeKeepingFile() async
    /// Stops and deletes the partial file.
    func cancel() async
}

/// Elapsed recording time that stops while paused.
///
/// Shared by the main actor (`elapsed`) and the audio thread's meter posts, so it takes
/// its own lock. The time is passed in rather than read from `Date()` inside, which
/// makes the pause arithmetic testable without waiting on a wall clock.
final class ElapsedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: Date?
    private var pausedAt: Date?
    private var paused: TimeInterval = 0

    func start(at date: Date = Date()) {
        lock.lock()
        startedAt = date
        pausedAt = nil
        paused = 0
        lock.unlock()
    }

    func pause(at date: Date = Date()) {
        lock.lock()
        if startedAt != nil, pausedAt == nil { pausedAt = date }
        lock.unlock()
    }

    func resume(at date: Date = Date()) {
        lock.lock()
        if let pausedAt {
            paused += date.timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        startedAt = nil
        pausedAt = nil
        paused = 0
        lock.unlock()
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt else { return 0 }
        return max(0, (pausedAt ?? date).timeIntervalSince(startedAt) - paused)
    }
}
