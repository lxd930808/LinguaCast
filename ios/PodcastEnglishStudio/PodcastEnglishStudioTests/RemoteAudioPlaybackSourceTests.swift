import XCTest

// WP12 app 层远程音频接线测试。
// 本目录同时被 SwiftPM（仅依赖 PodcastEnglishStudioCore）编译：PlayerKit 与
// app 模块在 SwiftPM 图中不可用，因此整体用 canImport 守护——在链接了 app
// 与 PlayerKit 的测试 target 中才会真正执行；可执行的行为覆盖见
// Packages/PlayerKit/Tests/PlayerKitTests/AudioPlaybackRemoteSourceTests.swift。
#if canImport(PlayerKit) && canImport(PodcastEnglishStudio)
@testable import PlayerKit
import PodcastEnglishStudioCore
@testable import PodcastEnglishStudio

@MainActor
final class RemoteAudioPlaybackSourceTests: XCTestCase {
    func testRefreshWiringReplacesSourceOnSuccess() async throws {
        let controller = AudioPlaybackController()
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 9_999, text: "a", learningText: "a", translation: "甲"),
            LearningSegment(sequence: 2, startMS: 10_000, endMS: 19_999, text: "b", learningText: "b", translation: "乙")
        ]
        let stale = AudioPlaybackSource.remote(
            URL(string: "https://cdn.example.com/a.mp3")!,
            expiresAt: Date().addingTimeInterval(60)
        )
        let fresh = AudioPlaybackSource.remote(
            URL(string: "https://cdn.example.com/b.mp3")!,
            expiresAt: Date().addingTimeInterval(3_600)
        )
        controller.load(source: stale, segments: segments)
        controller.seek(to: 12)

        let resolver = AudioPlaybackSourceResolver { fresh }
        EpisodeAudioRemotePlayback.installSourceRefreshHandling(on: controller, resolver: resolver)
        controller.handleItemFailure(nil)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, controller.currentSource != fresh {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(controller.currentSource, fresh)
        XCTAssertEqual(controller.currentTime, 12, accuracy: 0.001)
    }

    func testRefreshWiringFailureKeepsLastPosition() async throws {
        let controller = AudioPlaybackController()
        let stale = AudioPlaybackSource.remote(
            URL(string: "https://cdn.example.com/a.mp3")!,
            expiresAt: Date().addingTimeInterval(60)
        )
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 9_999, text: "a", learningText: "a", translation: "甲"),
            LearningSegment(sequence: 2, startMS: 10_000, endMS: 19_999, text: "b", learningText: "b", translation: "乙")
        ]
        controller.load(source: stale, segments: segments)
        controller.seek(to: 12)

        struct RefreshFailed: Error {}
        let resolver = AudioPlaybackSourceResolver { throw RefreshFailed() }
        var failures = 0
        EpisodeAudioRemotePlayback.installSourceRefreshHandling(
            on: controller,
            resolver: resolver,
            onRefreshFailure: { _ in failures += 1 }
        )
        controller.handleItemFailure(nil)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, failures == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(controller.currentTime, 12, accuracy: 0.001)
        XCTAssertEqual(controller.currentSource, stale)
    }
}
#endif
