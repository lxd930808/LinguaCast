import XCTest
import SwiftData
@testable import CloudSyncKit
@testable import PodcastEnglishStudioCore
@testable import DomainModels

/// 假的 Podcast RSS 拉取实现：按 sourceURL 返回预设数据或抛出错误。
private final class FakePodcastFeedFetcher: PodcastFeedDataFetching, @unchecked Sendable {
    var feedsByURL: [String: Data] = [:]
    var errorByURL: [String: Error] = [:]
    private(set) var requestedURLs: [String] = []

    func fetchFeedData(sourceURL: String) async throws -> Data {
        requestedURLs.append(sourceURL)
        if let error = errorByURL[sourceURL] { throw error }
        guard let data = feedsByURL[sourceURL] else {
            throw FakeFetchError.missing
        }
        return data
    }

    enum FakeFetchError: Error { case missing }
}

@MainActor
final class PodcastCatalogRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var coordinator: CloudSyncCoordinator!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var fetcher: FakePodcastFeedFetcher!
    private var fixedNow: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "CloudSyncKit.PodcastCatalogRecoveryTests.\(UUID().uuidString)"
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
        fetcher = FakePodcastFeedFetcher()
        coordinator.podcastFeedFetcher = fetcher
        fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.nowProvider = { [unowned self] in self.fixedNow }
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

    // MARK: - 辅助

    private func makeFeedXML(
        guid: String,
        title: String,
        enclosure: String,
        metadata: Bool = false
    ) -> String {
        let metadataXML = metadata
            ? """
              <itunes:image href="https://example.com/episode.jpg"/>
              <itunes:summary><![CDATA[<p>Recovered summary.</p>]]></itunes:summary>
              <itunes:duration>12:34</itunes:duration>
              <itunes:season>2</itunes:season>
              <itunes:episode>5</itunes:episode>
              <link>https://example.com/episodes/recovered</link>
              """
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
        <title>Test Show</title>
        <item><title>\(title)</title><guid>\(guid)</guid>\(metadataXML)<enclosure url="\(enclosure)" type="audio/mpeg"/></item>
        </channel></rss>
        """
    }

    private func makeFeedXMLMultiple(items: [(guid: String, title: String, enclosure: String)]) -> String {
        let itemsXML = items.map {
            "<item><title>\($0.title)</title><guid>\($0.guid)</guid><enclosure url=\"\($0.enclosure)\" type=\"audio/mpeg\"/></item>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Test Show</title>\(itemsXML)</channel></rss>
        """
    }

    private func addDeferredPodcastProgress(
        sourceURL: String,
        guid: String,
        position: Double = 50,
        modifiedAt: Date
    ) {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: sourceURL, episodeGUID: guid)
        )
        let state = CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: position,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: modifiedAt, deviceID: "other"),
            catalog: nil
        )
        coordinator.applyOrDeferPlaybackProgress(state)
    }

    // MARK: - 命中插入 + 进度重放

    func testRecoversMatchingEpisodeAndReplaysProgress() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        fetcher.feedsByURL[subscription.showURL] = Data(
            makeFeedXML(
                guid: "guid-1",
                title: "Episode One",
                enclosure: "https://example.com/ep1.mp3",
                metadata: true
            ).utf8
        )
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-1", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        let result = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-1"])],
            context: context,
            bypassMisses: false
        )

        XCTAssertEqual(result.insertedEpisodes, 1)
        XCTAssertEqual(result.reappliedProgress, 1)
        XCTAssertTrue(result.definitiveMisses.isEmpty)

        let episodes = try context.fetch(FetchDescriptor<EpisodeRecord>())
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.episodeGUID, "guid-1")
        XCTAssertEqual(episodes.first?.episodeTitle, "Episode One")
        XCTAssertEqual(episodes.first?.artworkURL, "https://example.com/episode.jpg")
        XCTAssertEqual(episodes.first?.summaryText, "Recovered summary.")
        XCTAssertEqual(episodes.first?.mediaDurationSeconds, 754)
        XCTAssertEqual(episodes.first?.seasonNumber, 2)
        XCTAssertEqual(episodes.first?.episodeNumber, 5)
        XCTAssertEqual(episodes.first?.episodeWebsiteURL, "https://example.com/episodes/recovered")
        XCTAssertEqual(episodes.first?.status, "queued")
        XCTAssertEqual(episodes.first?.playbackPositionSeconds, 50)
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 0)
    }

    // MARK: - 同一订阅多个 GUID 只请求一次

    func testMultipleGUIDsSameSubscriptionFetchOnce() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        fetcher.feedsByURL[subscription.showURL] = Data(makeFeedXMLMultiple(items: [
            (guid: "guid-a", title: "A", enclosure: "https://example.com/a.mp3"),
            (guid: "guid-b", title: "B", enclosure: "https://example.com/b.mp3")
        ]).utf8)
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-a", modifiedAt: fixedNow)
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-b", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        let result = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-a", "guid-b"])],
            context: context,
            bypassMisses: false
        )

        XCTAssertEqual(result.insertedEpisodes, 2)
        // 同一订阅的多个 GUID 只发起一次 RSS 请求。
        XCTAssertEqual(fetcher.requestedURLs.filter { $0 == subscription.showURL }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EpisodeRecord>()).count, 2)
    }

    // MARK: - 同一 RSS 部分命中部分未命中

    func testPartialHitRecordsMissOnlyForMissingGUID() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        fetcher.feedsByURL[subscription.showURL] = Data(
            makeFeedXML(guid: "guid-hit", title: "Hit", enclosure: "https://example.com/hit.mp3").utf8
        )
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-hit", modifiedAt: fixedNow)
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-miss", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        let result = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-hit", "guid-miss"])],
            context: context,
            bypassMisses: false
        )

        XCTAssertEqual(result.insertedEpisodes, 1)
        XCTAssertEqual(result.definitiveMisses.count, 1)
        XCTAssertEqual(result.definitiveMisses.first?.episodeGUID, "guid-miss")
        XCTAssertTrue(coordinator.isDefinitiveMiss(subscriptionIdentity: identity, episodeGUID: "guid-miss"))
        XCTAssertFalse(coordinator.isDefinitiveMiss(subscriptionIdentity: identity, episodeGUID: "guid-hit"))
    }

    // MARK: - 确定未命中停止自动重试，跨“重启”持久化

    func testDefinitiveMissStopsAutomaticRetry() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        fetcher.feedsByURL[subscription.showURL] = Data(
            makeFeedXML(guid: "other-guid", title: "Other", enclosure: "https://example.com/o.mp3").utf8
        )
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-gone", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        // 第一次：RSS 成功但 GUID 不存在 → 确定未命中。
        _ = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-gone"])],
            context: context,
            bypassMisses: false
        )
        let firstRequestCount = fetcher.requestedURLs.count

        // 第二次自动触发：应跳过，不再请求。
        let result = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-gone"])],
            context: context,
            bypassMisses: false
        )
        XCTAssertEqual(fetcher.requestedURLs.count, firstRequestCount)
        XCTAssertEqual(result.insertedEpisodes, 0)
    }

    func testDefinitiveMissPersistsAcrossCoordinatorReinit() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        fetcher.feedsByURL[subscription.showURL] = Data(
            makeFeedXML(guid: "other-guid", title: "Other", enclosure: "https://example.com/o.mp3").utf8
        )
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-gone", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        _ = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-gone"])],
            context: context,
            bypassMisses: false
        )

        // 模拟重启：用同一 defaults 重建 coordinator。
        let rebooted = CloudSyncCoordinator(defaults: defaults)
        rebooted.attachModelContext(context)
        rebooted.podcastFeedFetcher = fetcher
        XCTAssertTrue(rebooted.isDefinitiveMiss(subscriptionIdentity: identity, episodeGUID: "guid-gone"))

        let requestCountBefore = fetcher.requestedURLs.count
        _ = await rebooted.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-gone"])],
            context: context,
            bypassMisses: false
        )
        XCTAssertEqual(fetcher.requestedURLs.count, requestCountBefore)
    }

    // MARK: - 手动刷新绕过未命中

    func testManualRefreshBypassesDefinitiveMiss() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        // 初始 RSS 不含目标 → 未命中。
        fetcher.feedsByURL[subscription.showURL] = Data(
            makeFeedXML(guid: "other-guid", title: "Other", enclosure: "https://example.com/o.mp3").utf8
        )
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-late", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        _ = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-late"])],
            context: context,
            bypassMisses: false
        )
        XCTAssertTrue(coordinator.isDefinitiveMiss(subscriptionIdentity: identity, episodeGUID: "guid-late"))

        // 之后该集回到 RSS；手动刷新绕过未命中 → 恢复成功并清除标记。
        fetcher.feedsByURL[subscription.showURL] = Data(
            makeFeedXML(guid: "guid-late", title: "Back", enclosure: "https://example.com/back.mp3").utf8
        )
        let result = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-late"])],
            context: context,
            bypassMisses: true
        )
        XCTAssertEqual(result.insertedEpisodes, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EpisodeRecord>()).count, 1)
    }

    // MARK: - 临时错误退避，不误判为确定未命中

    struct FakeNetworkError: Error {}

    func testTransientNetworkErrorBacksOffWithoutDefinitiveMiss() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        fetcher.errorByURL[subscription.showURL] = FakeNetworkError()
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-1", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        _ = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-1"])],
            context: context,
            bypassMisses: false
        )
        // 网络错误不是确定未命中。
        XCTAssertFalse(coordinator.isDefinitiveMiss(subscriptionIdentity: identity, episodeGUID: "guid-1"))

        // 立即重试：处于 15 分钟退避窗口内 → 跳过，不再请求。
        let requestCount = fetcher.requestedURLs.count
        let result = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-1"])],
            context: context,
            bypassMisses: false
        )
        XCTAssertEqual(fetcher.requestedURLs.count, requestCount)
        XCTAssertEqual(result.backoffSkipped, [identity])
    }

    func testBackoffAllowsRetryAfterIntervalElapses() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()
        fetcher.errorByURL[subscription.showURL] = FakeNetworkError()
        addDeferredPodcastProgress(sourceURL: subscription.showURL, guid: "guid-1", modifiedAt: fixedNow)

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        _ = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-1"])],
            context: context,
            bypassMisses: false
        )
        XCTAssertEqual(fetcher.requestedURLs.count, 1)

        // 时钟前进 16 分钟（超过 15 分钟退避）→ 允许重试。
        fixedNow = fixedNow.addingTimeInterval(16 * 60)
        _ = await coordinator.recoverPodcastCatalog(
            targets: [.init(subscriptionIdentity: identity, episodeGUIDs: ["guid-1"])],
            context: context,
            bypassMisses: false
        )
        XCTAssertEqual(fetcher.requestedURLs.count, 2)
    }
}
