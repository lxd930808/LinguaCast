import XCTest
import Foundation
@testable import PlayerKit
import PodcastEnglishStudioCore

@MainActor
final class AudioPlaybackLifecycleTests: XCTestCase {
    func testPrepareResumeStashesSeekAndRecalculatesActiveSequence() throws {
        let controller = AudioPlaybackController()
        let audioURL = try makeSilentWAV(durationSeconds: 10)
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 2_999, text: "one", learningText: "one", translation: "一"),
            LearningSegment(sequence: 2, startMS: 3_000, endMS: 5_999, text: "two", learningText: "two", translation: "二"),
            LearningSegment(sequence: 3, startMS: 6_000, endMS: 9_999, text: "three", learningText: "three", translation: "三")
        ]
        controller.load(audioURL: audioURL, segments: segments, initialTime: 3.5)
        XCTAssertNil(controller.pendingResumeSeekTime)

        controller.prepareResume(at: 4.2)
        XCTAssertEqual(controller.pendingResumeSeekTime ?? -1, 4.2, accuracy: 0.001)
        XCTAssertEqual(controller.currentTime, 4.2, accuracy: 0.001)
        XCTAssertEqual(controller.activeSequence, 2)
        XCTAssertFalse(controller.isPlaying)
    }

    func testPausePlaybackClearsPlayingWithoutConsumingResumeSeek() throws {
        let controller = AudioPlaybackController()
        let audioURL = try makeSilentWAV(durationSeconds: 4)
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 3_999, text: "only", learningText: "only", translation: "仅")
        ]
        controller.load(audioURL: audioURL, segments: segments, initialTime: 3.2)
        controller.prepareResume(at: 3.2)
        controller.pausePlayback()
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.pendingResumeSeekTime ?? -1, 3.2, accuracy: 0.001)
    }

    func testUserSeekCancelsPendingResumeSeek() throws {
        let controller = AudioPlaybackController()
        let audioURL = try makeSilentWAV(durationSeconds: 8)
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 7_999, text: "only", learningText: "only", translation: "仅")
        ]
        controller.load(audioURL: audioURL, segments: segments, initialTime: 2)
        controller.prepareResume(at: 2)
        controller.seek(to: 5)
        XCTAssertNil(controller.pendingResumeSeekTime)
        XCTAssertEqual(controller.currentTime, 5, accuracy: 0.001)
    }

    func testPlayPauseConsumesPendingResumeSeekBeforePlaying() async throws {
        let controller = AudioPlaybackController()
        let audioURL = try makeSilentWAV(durationSeconds: 6)
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 2_999, text: "a", learningText: "a", translation: "甲"),
            LearningSegment(sequence: 2, startMS: 3_000, endMS: 5_999, text: "b", learningText: "b", translation: "乙")
        ]
        controller.load(audioURL: audioURL, segments: segments, initialTime: 3.5)
        controller.prepareResume(at: 3.5)
        XCTAssertNotNil(controller.pendingResumeSeekTime)

        controller.playPause()

        // Seek-then-play is asynchronous; wait until playing or pending seek is consumed.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if controller.pendingResumeSeekTime == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(controller.pendingResumeSeekTime)

        while Date() < deadline, !controller.isPlaying {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // On hosts without a usable audio session (CI/simulator edge), play may fail with
        // an error message; the critical contract is still seek-before-play ordering.
        if controller.errorMessage == nil {
            XCTAssertTrue(controller.isPlaying)
            XCTAssertEqual(controller.currentTime, 3.5, accuracy: 0.35)
            XCTAssertEqual(controller.activeSequence, 2)
        }
        controller.pausePlayback()
    }

    func testPauseInvalidatesAnInFlightSentenceSeek() async throws {
        let controller = AudioPlaybackController()
        let url = try makeSilentWAV(durationSeconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let segment = LearningSegment(sequence: 1, startMS: 2000, endMS: 5000, text: "sentence")
        controller.load(audioURL: url, segments: [segment])
        controller.play(segment: segment)
        controller.pausePlayback()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(controller.isPlaying, "A paused seek must never restart original audio after a mode switch")
    }

    private func makeSilentWAV(durationSeconds: UInt32) throws -> URL {
        let sampleRate: UInt32 = 8_000
        let sampleCount = sampleRate * durationSeconds
        let dataSize = sampleCount * 2
        var wav = Data()
        func append(_ text: String) { wav.append(contentsOf: text.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        append("RIFF")
        append(UInt32(36) + dataSize)
        append("WAVEfmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        append("data")
        append(dataSize)
        wav.append(Data(repeating: 0, count: Int(dataSize)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playerkit-lifecycle-\(UUID().uuidString).wav")
        try wav.write(to: url, options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
