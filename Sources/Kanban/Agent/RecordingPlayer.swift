import AVFoundation
import Foundation
import Observation

/// One player for the agent's recording cards and the meeting page.
///
/// Local files play directly. An uploaded meeting streams from the authenticated
/// audio route, so "Play Recording" works even after the transport file was removed.
@Observable
@MainActor
final class RecordingPlayer {

    struct Remote: Sendable {
        var url: URL
        var token: String
    }

    private(set) var meetingID: UUID?
    private(set) var title = ""
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var error: String?
    private(set) var sourceLabel = ""

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?

    var isLoaded: Bool { meetingID != nil }

    // MARK: Loading

    func loadAndPlay(meeting: Meeting, remote: Remote?) {
        load(meeting: meeting, remote: remote)
        play()
    }

    func load(meeting: Meeting, remote: Remote?) {
        stop()
        meetingID = meeting.id
        title = meeting.title
        duration = meeting.duration
        error = nil
        currentTime = 0

        let item: AVPlayerItem
        if let local = meeting.audioFilename {
            let url = KanbanPaths.recordingURL(filename: local)
            guard FileManager.default.fileExists(atPath: url.path) else {
                error = remote == nil
                    ? "The recording file is no longer on this Mac."
                    : nil
                if remote == nil { return }
                item = remoteItem(remote!)
                sourceLabel = "STREAMING"
                attach(item)
                return
            }
            item = AVPlayerItem(url: url)
            sourceLabel = "LOCAL FILE"
        } else if let remote {
            item = remoteItem(remote)
            sourceLabel = "STREAMING"
        } else {
            error = "The audio was removed after processing."
            return
        }

        attach(item)
    }

    private func remoteItem(_ remote: Remote) -> AVPlayerItem {
        // AVFoundation needs the bearer token to reach the authenticated route. The
        // options key is the documented-by-use mechanism for per-asset headers.
        let asset = AVURLAsset(url: remote.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(remote.token)"]
        ])
        return AVPlayerItem(asset: asset)
    }

    private func attach(_ item: AVPlayerItem) {
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        isLoading = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if let itemDuration = player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.isLoading = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.isLoading = false
                if let failure = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    self.error = "Could not play this recording. \(failure.localizedDescription)"
                } else {
                    self.error = "Could not play this recording."
                }
            }
        }
    }

    // MARK: Transport

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        error = nil
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, seconds), max(duration, 0))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    /// Plays the meeting from a transcript timestamp.
    func seekAndPlay(_ seconds: TimeInterval) {
        seek(to: seconds)
        play()
    }

    func stop() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        player?.pause()
        player = nil
        meetingID = nil
        title = ""
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        sourceLabel = ""
        error = nil
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var timeLabel: String {
        "\(Meeting.timecode(currentTime)) / \(Meeting.timecode(duration))"
    }
}
