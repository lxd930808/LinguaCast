import XCTest
import SwiftData
@testable import CloudSyncKit
@testable import PodcastEnglishStudioCore
@testable import DomainModels

/// 假的 YouTube 视频详情拉取实现。
private final class FakeYouTubeDetailsFetcher: YouTubeVideoDetailsFetching, @unchecked Sendable {
    var detailsByID: [String: YouTubeVideoDetails] = [:]
    var error: Error?
    private(set) var requestedBatches: [Set<String>] = []

    func fetchVideoDetails(videoIDs: Set<String>) async throws -> [String: YouTubeVideoDetails] {
        requestedBatches.append(videoIDs)
        if let error { throw error }
        return detailsByID.filter { videoIDs.contains($0.key) }
    }

    struct FakeError: Error {}
}

@MainActor
final class YouTubeCatalogRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var coordinator: CloudSyncCoordinator!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var fetcher: FakeYouTubeDetailsFetcher!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "CloudSyncKit.YouTubeCatalogRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let schema = Schema([
            PodcastSubscription.self,
            EpisodeRecord.self,
            SegmentRecord.self,
            TranslationVariantRecord.self,
            YTChannelRecord.self,
            YTVideoRecord.self
        ])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        coordinator = CloudSyncCoordinator(defaults: defaults)
        coordinator.attachModelContext(context)
        fetcher = FakeYouTubeDetailsFetcher()
        coordinator.youTubeVideoDetailsFetcher = fetcher
    }

    override func tearDown() {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaults = nil
        coordinator = nil
        context = nil
        container = nil
        fetcher = nil
        super.tearDown()
    }

    private func addChannel(channelID: String, isEnabled: Bool = true) -> YTChannelRecord {
        let channel = YTChannelRecord(
            id: channelID,
            channelID: channelID,
            url: "https://youtube.com/channel/\(channelID)",
            displayName: "Chan \(channelID)",
            isEnabled: isEnabled
        )
        context.insert(channel)
        try? context.save()
        return channel
    }

    private func addDeferredYouTubeProgress(videoID: String, position: Double = 40) {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(for: .youtubeVideo(videoID: videoID))
        let state = CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: position,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), deviceID: "other"),
            catalog: nil
        )
        coordinator.applyOrDeferPlaybackProgress(state)
    }

    // MARK: - 批量合并为一次请求

    func testMissingVideoIDsAreBatchedIntoOneRequest() async throws {
        addChannel(channelID: "UCabc")
        fetcher.detailsByID = [
            "v1": YouTubeVideoDetails(videoID: "v1", channelID: "UCabc", title: "One", playbackURL: "https://www.youtube.com/watch?v=v1"),
            "v2": YouTubeVideoDetails(videoID: "v2", channelID: "UCabc", title: "Two", playbackURL: "https://www.youtube.com/watch?v=v2")
        ]
        addDeferredYouTubeProgress(videoID: "v1")
        addDeferredYouTubeProgress(videoID: "v2")

        let result = await coordinator.recoverYouTubeCatalog(videoIDs: ["v1", "v2"], context: context)

        XCTAssertEqual(fetcher.requestedBatches.count, 1)
        XCTAssertEqual(fetcher.requestedBatches.first, ["v1", "v2"])
        XCTAssertEqual(result.insertedVideos, 2)
        XCTAssertEqual(result.reappliedProgress, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<YTVideoRecord>()).count, 2)
    }

    // MARK: - 频道校验

    func testRejectsVideosFromUnsubscribedOrDisabledChannels() async throws {
        addChannel(channelID: "UCenabled", isEnabled: true)
        addChannel(channelID: "UCdisabled", isEnabled: false)
        fetcher.detailsByID = [
            "ok": YouTubeVideoDetails(videoID: "ok", channelID: "UCenabled", title: "OK", playbackURL: "https://www.youtube.com/watch?v=ok"),
            "disabled": YouTubeVideoDetails(videoID: "disabled", channelID: "UCdisabled", title: "Disabled", playbackURL: "https://www.youtube.com/watch?v=disabled"),
            "unknown": YouTubeVideoDetails(videoID: "unknown", channelID: "UCunknown", title: "Unknown", playbackURL: "https://www.youtube.com/watch?v=unknown")
        ]
        addDeferredYouTubeProgress(videoID: "ok")
        addDeferredYouTubeProgress(videoID: "disabled")
        addDeferredYouTubeProgress(videoID: "unknown")

        let result = await coordinator.recoverYouTubeCatalog(
            videoIDs: ["ok", "disabled", "unknown"],
            context: context
        )

        XCTAssertEqual(result.insertedVideos, 1)
        XCTAssertEqual(result.skippedVideoIDs, ["disabled", "unknown"])
        let videos = try context.fetch(FetchDescriptor<YTVideoRecord>())
        XCTAssertEqual(videos.map(\.id), ["ok"])
        XCTAssertEqual(videos.first?.channelID, "UCenabled")
    }

    // MARK: - 视频删除 / 拉取失败

    func testDeletedVideoIsSkippedWithoutPlaceholder() async throws {
        addChannel(channelID: "UCabc")
        // fetcher 不返回 v-deleted（视频已删除）。
        fetcher.detailsByID = [:]
        addDeferredYouTubeProgress(videoID: "v-deleted")

        let result = await coordinator.recoverYouTubeCatalog(videoIDs: ["v-deleted"], context: context)

        XCTAssertEqual(result.insertedVideos, 0)
        XCTAssertEqual(result.skippedVideoIDs, ["v-deleted"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<YTVideoRecord>()).isEmpty)
    }

    func testFetchFailureCreatesNoRecords() async throws {
        addChannel(channelID: "UCabc")
        fetcher.error = FakeYouTubeDetailsFetcher.FakeError()
        addDeferredYouTubeProgress(videoID: "v1")

        let result = await coordinator.recoverYouTubeCatalog(videoIDs: ["v1"], context: context)

        XCTAssertEqual(result.insertedVideos, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<YTVideoRecord>()).isEmpty)
        // 进度仍 deferred，留待下次。
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 1)
    }

    // MARK: - 命中后重放进度

    func testInsertedVideoReplaysDeferredProgress() async throws {
        let channel = addChannel(channelID: "UCabc")
        fetcher.detailsByID = [
            "v1": YouTubeVideoDetails(videoID: "v1", channelID: "UCabc", title: "One", playbackURL: "https://www.youtube.com/watch?v=v1", thumbnailURL: "https://i.ytimg.com/vi/v1/hq.jpg")
        ]
        addDeferredYouTubeProgress(videoID: "v1", position: 77)

        let result = await coordinator.recoverYouTubeCatalog(videoIDs: ["v1"], context: context)

        XCTAssertEqual(result.reappliedProgress, 1)
        let video = try XCTUnwrap(context.fetch(FetchDescriptor<YTVideoRecord>()).first)
        XCTAssertEqual(video.playbackPositionSeconds, 77)
        XCTAssertEqual(video.channelRecordID, channel.id)
        XCTAssertEqual(video.thumbnail, "https://i.ytimg.com/vi/v1/hq.jpg")
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 0)
    }
}
