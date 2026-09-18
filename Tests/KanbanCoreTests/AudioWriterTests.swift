import AVFoundation
import XCTest

/// These exist because the first version of the capture path called
/// `MainActor.assumeIsolated` from the AVAudioEngine tap, which runs on a realtime
/// audio thread — the app trapped the instant recording started. The writer is now
/// off-actor, and these tests drive it the way the tap does: from other threads,
/// concurrently, with no main-actor context.
final class AudioWriterTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-\(UUID().uuidString).m4a")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 32_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000
    ]

    private var tapFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    private func buffer(frames: AVAudioFrameCount = 4096, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(tapFormat.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = amplitude * sin(Float(i) * 0.05)
            }
        }
        return buffer
    }

    func testWritesFromANonMainThread() throws {
        let writer = AudioFileWriter()
        try writer.open(url: url, settings: settings, tapFormat: tapFormat)

        // The exact condition that used to trap: no main actor, no Swift concurrency.
        let done = expectation(description: "audio thread finished")
        let make = { self.buffer(frames: 4096, amplitude: 0.5) }
        Thread.detachNewThread {
            for _ in 0..<40 { _ = writer.write(make()) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        writer.finish()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        XCTAssertGreaterThan(size, 0, "releasing the file must flush the encoder")
        XCTAssertGreaterThan(writer.frameCount, 0)
    }

    func testConcurrentWritersDoNotCorruptState() throws {
        let writer = AudioFileWriter()
        try writer.open(url: url, settings: settings, tapFormat: tapFormat)

        // Mic tap and system-audio callback arrive on different queues.
        let make = { self.buffer(frames: 4096, amplitude: 0.5) }
        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<25 { _ = writer.write(make()) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)

        writer.finish()
        XCTAssertGreaterThan(writer.frameCount, 0)
        XCTAssertNoThrow(try AVAudioFile(forReading: url), "the file must be readable")
    }

    func testPauseStopsWritingButKeepsMetering() throws {
        let writer = AudioFileWriter()
        try writer.open(url: url, settings: settings, tapFormat: tapFormat)

        for _ in 0..<10 { _ = writer.write(buffer()) }
        let written = writer.frameCount
        XCTAssertGreaterThan(written, 0)

        writer.setPaused(true)
        XCTAssertTrue(writer.isPaused)
        let level = writer.write(buffer(amplitude: 0.9))
        XCTAssertGreaterThan(level, 0, "the meter still reports while paused")
        XCTAssertEqual(writer.frameCount, written, "paused audio must not reach the file")

        writer.setPaused(false)
        _ = writer.write(buffer())
        XCTAssertGreaterThan(writer.frameCount, written)
        writer.finish()
    }

    func testWritingAfterFinishIsANoOpRatherThanACrash() throws {
        let writer = AudioFileWriter()
        try writer.open(url: url, settings: settings, tapFormat: tapFormat)
        _ = writer.write(buffer())
        writer.finish()

        // A tap buffer can land after stop(); it must not trap.
        XCTAssertNoThrow(_ = writer.write(buffer()))
        _ = writer.write(buffer())
    }

    func testPeakLevelTracksAmplitude() throws {
        let writer = AudioFileWriter()
        try writer.open(url: url, settings: settings, tapFormat: tapFormat)
        let quiet = writer.write(buffer(amplitude: 0.05))
        let loud = writer.write(buffer(amplitude: 0.9))
        XCTAssertLessThan(quiet, loud)
        XCTAssertLessThanOrEqual(loud, 1.0)
        writer.finish()
    }

    func testOpenFailsCleanlyOnAnUnwritablePath() {
        let writer = AudioFileWriter()
        let bad = URL(fileURLWithPath: "/System/definitely/not/writable/x.m4a")
        XCTAssertThrowsError(try writer.open(url: bad, settings: settings, tapFormat: tapFormat))
        // And the writer stays inert rather than half-open.
        XCTAssertEqual(writer.write(buffer()), writer.write(buffer()))
    }
}
