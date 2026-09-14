import XCTest
import Foundation
@testable import PlayerKit
import PodcastEnglishStudioCore

// WP12 — 远程播放源 / 签名 URL 刷新 / 来源解析测试。
// 远程 AVPlayerItem 在测试中不会真正加载，因此失败与晚到时长通过
// internal 钩子（handleItemFailure / applyDiscoveredDuration）确定性模拟。
@MainActor
final class AudioPlaybackRemoteSourceTests: XCTestCase {
    private let remoteURL = URL(string: "https://cdn.example.com/media/episode.mp3")!

    private func makeSegments(count: Int = 10, segmentMS: Int = 10_000) -> [LearningSegment] {
        (1...count).map { index in
            LearningSegment(
                sequence: index,
                startMS: (index - 1) * segmentMS,
                endMS: index * segmentMS - 1,
                text: "line \(index)",
                learningText: "line \(index)",
                translation: "译 \(index)"
            )
        }
    }

    private func makeRemoteSource(url: URL? = nil) -> AudioPlaybackSource {
        .remote(url ?? remoteURL, expiresAt: Date().addingTimeInterval(3_600))
    }

    private func makeTempAudioFile(bytes: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playerkit-remote-\(UUID().uuidString).mp3")
        try Data(repeating: 1, count: bytes).write(to: url, options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    // MARK: - Source validation

    func testLocalFileSourceKeepsMissingFileValidation() {
        let controller = AudioPlaybackController()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("playerkit-missing-\(UUID().uuidString).mp3")
        controller.load(source: .localFile(missing), segments: makeSegments())
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.currentSource)
    }

    func testLocalFileSourceKeepsEmptyFileValidation() throws {
        let controller = AudioPlaybackController()
        let empty = try makeTempAudioFile(bytes: 0)
        controller.load(source: .localFile(empty), segments: makeSegments())
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.currentSource)
    }

    func testRemoteSourceSkipsFileSystemChecks() {
        let controller = AudioPlaybackController()
        // 磁盘上不存在该路径；若执行 FileManager.exists 校验必然失败。
        let source = makeRemoteSource()
        controller.load(source: source, segments: makeSegments())
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.currentSource, source)
        // 时长先取字幕推断值，等待媒体时长晚到后覆盖。
        XCTAssertEqual(controller.duration, 99.999, accuracy: 0.001)
    }

    func testRemoteSourceRequiresHTTPS() {
        let controller = AudioPlaybackController()
        let insecure = URL(string: "http://cdn.example.com/media/episode.mp3")!
        controller.load(source: makeRemoteSource(url: insecure), segments: makeSegments())
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.currentSource)
    }

    func testRemoteHostAllowlistAcceptsListedHostAndRejectsOthers() {
        let policy = RemoteAudioHostPolicy(allowedHosts: ["cdn.example.com"])
        let controller = AudioPlaybackController(remoteHostPolicy: policy)

        let allowed = URL(string: "https://CDN.example.com/media/a.mp3")!
        let allowedSource = makeRemoteSource(url: allowed)
        controller.load(source: allowedSource, segments: makeSegments())
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.currentSource)

        let other = URL(string: "https://evil.example.net/media/a.mp3")!
        controller.load(source: makeRemoteSource(url: other), segments: makeSegments())
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.currentSource, allowedSource)
    }

    // MARK: - Failure → refresh signal

    func testRemoteItemFailureEmitsRefreshSignalOncePerItem() {
        let controller = AudioPlaybackController()
        let source = makeRemoteSource()
        controller.load(source: source, segments: makeSegments())
        var signals: [AudioPlaybackSource] = []
        controller.onSourceRefreshRequired = { signals.append($0) }

        let forbidden = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUserAuthenticationRequired,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 403"]
        )
        controller.handleItemFailure(forbidden)
        XCTAssertEqual(signals, [source])
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertTrue(AudioPlaybackFailureClassifier.isAuthorizationFailure(forbidden))

        // 同一 item 重复失败不重复发信号。
        controller.handleItemFailure(forbidden)
        XCTAssertEqual(signals.count, 1)
    }

    func testLocalItemFailureDoesNotEmitRefreshSignal() throws {
        let controller = AudioPlaybackController()
        let file = try makeTempAudioFile()
        controller.load(source: .localFile(file), segments: makeSegments())
        var signals: [AudioPlaybackSource] = []
        controller.onSourceRefreshRequired = { signals.append($0) }

        controller.handleItemFailure(nil)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testOfflineFailureSurfacesPlaybackErrorAndKeepsSignal() {
        let controller = AudioPlaybackController()
        let source = makeRemoteSource()
        controller.load(source: source, segments: makeSegments())
        var signals: [AudioPlaybackSource] = []
        controller.onSourceRefreshRequired = { signals.append($0) }

        let offline = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )
        controller.handleItemFailure(offline)
        XCTAssertTrue(controller.errorMessage?.contains("no local audio copy") ?? false)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(signals, [source])
        XCTAssertTrue(AudioPlaybackFailureClassifier.isOffline(offline))
        XCTAssertFalse(AudioPlaybackFailureClassifier.isAuthorizationFailure(offline))
    }

    // MARK: - replaceSourcePreservingPosition

    func testReplaceSourceRestoresPositionRateAndSequence() {
        let controller = AudioPlaybackController()
        controller.load(source: makeRemoteSource(), segments: makeSegments())
        controller.seek(to: 42)
        controller.playbackRate = 1.5
        XCTAssertEqual(controller.activeSequence, 5)

        let fresh = AudioPlaybackSource.remote(
            URL(string: "https://cdn.example.com/media/episode-v2.mp3")!,
            expiresAt: Date().addingTimeInterval(3_600)
        )
        controller.replaceSourcePreservingPosition(fresh)
        XCTAssertEqual(controller.currentSource, fresh)
        XCTAssertEqual(controller.currentTime, 42, accuracy: 0.001)
        XCTAssertEqual(controller.playbackRate, 1.5)
        XCTAssertEqual(controller.activeSequence, 5)
        XCTAssertNil(controller.errorMessage)
    }

    func testReplaceSourcePreservesPendingResume() {
        let controller = AudioPlaybackController()
        controller.load(source: makeRemoteSource(), segments: makeSegments())
        controller.prepareResume(at: 55)

        controller.replaceSourcePreservingPosition(makeRemoteSource())
        XCTAssertEqual(controller.currentTime, 55, accuracy: 0.001)
        XCTAssertEqual(controller.pendingResumeSeekTime ?? -1, 55, accuracy: 0.001)
        XCTAssertEqual(controller.activeSequence, 6)
        XCTAssertFalse(controller.isPlaying)
    }

    func testReplaceRejectsInvalidSourceAndKeepsLastPosition() {
        let controller = AudioPlaybackController()
        let original = makeRemoteSource()
        controller.load(source: original, segments: makeSegments())
        controller.seek(to: 42)

        let insecure = URL(string: "http://cdn.example.com/media/episode.mp3")!
        controller.replaceSourcePreservingPosition(makeRemoteSource(url: insecure))
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.currentSource, original)
        XCTAssertEqual(controller.currentTime, 42, accuracy: 0.001)
    }

    func testRefreshFailureKeepsLastPosition() {
        // 403 → 发信号；app 刷新失败（不调用 replace）→ 位置与来源保持。
        let controller = AudioPlaybackController()
        let original = makeRemoteSource()
        controller.load(source: original, segments: makeSegments())
        controller.seek(to: 42)
        controller.onSourceRefreshRequired = { _ in /* app refresh fails: no replace */ }
        controller.handleItemFailure(nil)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.currentSource, original)
        XCTAssertEqual(controller.currentTime, 42, accuracy: 0.001)
    }

    // MARK: - Remote source parity with local playback controls

    func testRemoteSeekSkipRatePointSentenceAndResumeStash() {
        let controller = AudioPlaybackController()
        let segments = makeSegments(count: 12)
        controller.load(source: makeRemoteSource(), segments: segments)

        controller.seek(to: 10)
        XCTAssertEqual(controller.currentTime, 10, accuracy: 0.001)
        controller.skip(by: 15)
        XCTAssertEqual(controller.currentTime, 25, accuracy: 0.001)

        controller.playbackRate = 0.75
        XCTAssertEqual(controller.playbackRate, 0.75)

        // Point-sentence: active cue switches synchronously to the tapped line.
        controller.play(segment: segments[2])
        XCTAssertEqual(controller.activeSequence, 3)
        XCTAssertEqual(controller.currentTime, 20, accuracy: 0.001)
        controller.pausePlayback()

        // 锁屏恢复 stash；用户 seek 取消 stash（与本地行为一致）。
        controller.prepareResume(at: 60)
        XCTAssertEqual(controller.pendingResumeSeekTime ?? -1, 60, accuracy: 0.001)
        controller.seek(to: 5)
        XCTAssertNil(controller.pendingResumeSeekTime)
        XCTAssertEqual(controller.currentTime, 5, accuracy: 0.001)
    }

    // MARK: - Late-arriving media duration

    func testLateDiscoveredDurationOverridesInferredExtent() {
        let controller = AudioPlaybackController()
        controller.load(source: makeRemoteSource(), segments: makeSegments(count: 1))
        XCTAssertEqual(controller.duration, 10, accuracy: 0.001)

        controller.applyDiscoveredDuration(25)
        XCTAssertEqual(controller.duration, 25, accuracy: 0.001)

        controller.seek(to: 20)
        XCTAssertEqual(controller.currentTime, 20, accuracy: 0.001)

        // 真实时长更短时，位置被收敛到新媒体时长。
        controller.applyDiscoveredDuration(15)
        XCTAssertEqual(controller.duration, 15, accuracy: 0.001)
        XCTAssertEqual(controller.currentTime, 15, accuracy: 0.001)
    }

    func testReplaceReappliesPositionWhenDurationArrivesLate() {
        let controller = AudioPlaybackController()
        controller.load(source: makeRemoteSource(), segments: makeSegments(), initialTime: 30)
        XCTAssertEqual(controller.currentTime, 30, accuracy: 0.001)

        controller.replaceSourcePreservingPosition(makeRemoteSource())
        XCTAssertEqual(controller.currentTime, 30, accuracy: 0.001)

        // 晚到的媒体时长触发请求位置重放。
        controller.applyDiscoveredDuration(50)
        XCTAssertEqual(controller.currentTime, 30, accuracy: 0.001)

        // 若真实时长更短，恢复位置被收敛。
        controller.replaceSourcePreservingPosition(makeRemoteSource())
        controller.applyDiscoveredDuration(20)
        XCTAssertEqual(controller.currentTime, 20, accuracy: 0.001)
    }

    // MARK: - AudioPlaybackSourceResolver (local-first, offline → playback error)

    func testResolverPrefersUsableLocalFile() async throws {
        let box = ProviderCallBox()
        let resolver = AudioPlaybackSourceResolver {
            box.count += 1
            return .remote(URL(string: "https://cdn.example.com/media/unused.mp3")!, expiresAt: Date().addingTimeInterval(3_600))
        }
        let file = try makeTempAudioFile()
        let source = try await resolver.resolve(preferredLocalFile: file)
        XCTAssertEqual(source, .localFile(file))
        XCTAssertEqual(box.count, 0, "usable local file must win without touching the network")
    }

    func testResolverFallsBackToRemoteWhenLocalMissingOrEmpty() async throws {
        let box = ProviderCallBox()
        let remote = makeRemoteSource()
        let resolver = AudioPlaybackSourceResolver {
            box.count += 1
            return remote
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("playerkit-missing-\(UUID().uuidString).mp3")
        let fromMissing = try await resolver.resolve(preferredLocalFile: missing)
        XCTAssertEqual(fromMissing, remote)

        let empty = try makeTempAudioFile(bytes: 0)
        let fromEmpty = try await resolver.resolve(preferredLocalFile: empty)
        XCTAssertEqual(fromEmpty, remote)
        XCTAssertEqual(box.count, 2)
    }

    func testResolverThrowsWhenOfflineAndNoLocalCopy() async {
        let resolver = AudioPlaybackSourceResolver {
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
            )
        }
        do {
            _ = try await resolver.resolve(preferredLocalFile: nil)
            XCTFail("offline without a local copy must fail resolution")
        } catch let error as AudioPlaybackSourceResolver.ResolutionError {
            guard case .noPlayableSource(let underlying) = error else {
                return XCTFail("unexpected resolution error: \(error)")
            }
            XCTAssertFalse(underlying.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private final class ProviderCallBox: @unchecked Sendable {
    var count = 0
}
