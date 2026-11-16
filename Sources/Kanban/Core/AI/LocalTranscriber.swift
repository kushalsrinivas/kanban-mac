import AVFoundation
import CoreMedia
import Foundation
import Speech

/// A transcript produced on this Mac. Times are seconds from the start of the audio.
struct LocalTranscript: Sendable {
    var text: String
    var segments: [TranscriptSegment]
    var language: String?
}

/// On-device speech-to-text.
///
/// macOS 26's `SpeechAnalyzer` handles long meeting files natively and installs its
/// model through the system. Older systems fall back to `SFSpeechRecognizer` with
/// on-device recognition forced, which is bounded and intended for shorter files.
struct LocalTranscriber {

    enum Engine: String, Sendable {
        case speechAnalyzer
        case speechRecognizer
    }

    func engine() -> Engine {
        if #available(macOS 26, *) { return .speechAnalyzer }
        return .speechRecognizer
    }

    func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { result in
                continuation.resume(returning: result == .authorized)
            }
        }
    }

    /// - Parameter status: called with human-readable progress; always on the main actor.
    func transcribe(url: URL, locale: Locale = Locale(identifier: "en-US"),
                    status: @escaping @MainActor (String) -> Void) async throws -> LocalTranscript {
        guard await requestAuthorization() else { throw LocalAIError.speechDenied }

        if #available(macOS 26, *) {
            return try await transcribeWithAnalyzer(url: url, locale: locale, status: status)
        }
        return try await transcribeWithRecognizer(url: url, locale: locale)
    }

    // MARK: macOS 26+ analyzer

    @available(macOS 26, *)
    private func transcribeWithAnalyzer(url: URL, locale: Locale,
                                        status: @escaping @MainActor (String) -> Void) async throws -> LocalTranscript {
        guard SpeechTranscriber.isAvailable else { throw LocalAIError.speechUnavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LocalAIError.speechUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            preset: .timeIndexedTranscriptionWithAlternatives)

        await status("Preparing the on-device speech model…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    start: CMTimeGetSeconds(result.range.start),
                    end: CMTimeGetSeconds(result.range.end),
                    speaker: nil,
                    text: text))
            }
            return segments
        }

        do {
            await status("Transcribing on this Mac…")
            let file = try AVAudioFile(forReading: url)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        let segments = try await collector.value
        guard !segments.isEmpty else {
            throw LocalAIError.malformed("no speech was detected in the recording")
        }
        return LocalTranscript(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            language: supported.identifier)
    }

    // MARK: macOS 14–15 fallback

    private func transcribeWithRecognizer(url: URL, locale: Locale) async throws -> LocalTranscript {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LocalAIError.speechUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true

        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: LocalAIError.transport(error.localizedDescription))
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result)
                }
            }
        }

        let segments = result.bestTranscription.segments.map { segment in
            TranscriptSegment(
                start: segment.timestamp,
                end: segment.timestamp + segment.duration,
                speaker: nil,
                text: segment.substring)
        }
        guard !segments.isEmpty else {
            throw LocalAIError.malformed("no speech was detected in the recording")
        }
        return LocalTranscript(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            language: locale.identifier)
    }
}
