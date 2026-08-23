import XCTest
import SwiftData
@testable import CloudSyncKit
@testable import PodcastEnglishStudioCore
@testable import DomainModels

@MainActor
final class PlaybackCatalogRecoveryCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var coordinator: CloudSyncCoordinator!
    private var recovery: PlaybackCatalogRecoveryCoordinator!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var fixedNow: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "CloudSyncKit.RecoveryCoordinatorTests.\(UUID().uuidString)"
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
        fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.nowProvider = { [unowned self] in self.fixedNow }
        recovery = PlaybackCatalogRecoveryCoordinator(cloudSync: coordinator) { [unowned self] in
            self.context
        }
    }

    override func tearDown() {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaults = nil
        coordinator = nil
        recovery = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - 快照恢复路径（无网络）

    func testSnapshotRecoveryMaterializesWithoutNetworkFetchers() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-1")
        )
        let snapshot = PlaybackCatalogSnapshot(
            content: .podcast(.init(
                sourceURL: subscription.showURL,
                episodeGUID: "guid-1",
                episodeTitle: "Recovered",
                showTitle: "Show",
                enclosureURL: "https://example.com/ep1.mp3"
            )),
            modifiedAt: recent,
            deviceID: "other"
        )
        coordinator.applyOrDeferPlaybackProgress(CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 100,
            durationSeconds: 600,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other"),
            catalog: snapshot
        ))

        // 无 fetcher：纯快照路径应仍能恢复。
        let outcome = await recovery.synchronizeAndRecover(trigger: .automatic)
        XCTAssertEqual(outcome.materializedFromSnapshot, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EpisodeRecord>()).count, 1)
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 0)
    }

    // MARK: - 任务去重

    func testConcurrentTriggersShareOneRecoveryTask() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        let fetcher = CountingPodcastFetcher(feedXML: Self.feedXML(guid: "guid-1", enclosure: "https://example.com/ep1.mp3"))
        coordinator.podcastFeedFetcher = fetcher

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-1")
        )
        coordinator.applyOrDeferPlaybackProgress(CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 50,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other"),
            catalog: nil
        ))

        // 并发触发多次（模拟启动 + 前台 + 首页刷新同时进行）。
        async let r1 = recovery.synchronizeAndRecover(trigger: .automatic)
        async let r2 = recovery.synchronizeAndRecover(trigger: .automatic)
        async let r3 = recovery.synchronizeAndRecover(trigger: .automatic)
        let results = await [r1, r2, r3]

        // 只发起一次 RSS 请求（去重到同一任务 + 同一订阅只请求一次）。
        XCTAssertEqual(fetcher.requestCount, 1)
        XCTAssertEqual(results[0].podcastRecovered, results[1].podcastRecovered)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EpisodeRecord>()).count, 1)
    }

    // MARK: - 手动刷新绕过确定未命中

    func testManualRefreshBypassesDefinitiveMiss() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        let identity = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        // 预置一个确定未命中标记。
        coordinator.recordDefinitiveMiss(PodcastCatalogDefinitiveMiss(
            subscriptionIdentity: identity,
            episodeGUID: "guid-late",
            recordedAt: fixedNow
        ))

        let fetcher = CountingPodcastFetcher(feedXML: Self.feedXML(guid: "guid-late", enclosure: "https://example.com/back.mp3"))
        coordinator.podcastFeedFetcher = fetcher

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-late")
        )
        coordinator.applyOrDeferPlaybackProgress(CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 50,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other"),
            catalog: nil
        ))

        // 自动路径：未命中标记阻止请求。
        let autoOutcome = await recovery.synchronizeAndRecover(trigger: .automatic)
        XCTAssertEqual(fetcher.requestCount, 0)
        XCTAssertEqual(autoOutcome.podcastRecovered, 0)

        // 手动刷新：绕过未命中 → 恢复成功。
        let manualOutcome = await recovery.synchronizeAndRecover(trigger: .manualRefresh)
        XCTAssertEqual(fetcher.requestCount, 1)
        XCTAssertEqual(manualOutcome.podcastRecovered, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EpisodeRecord>()).count, 1)
    }

    // MARK: - 失败分离：云同步失败不阻断目录恢复

    func testLocalSnapshotRecoveryRunsEvenWhenCloudUnavailable() async throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-1")
        )
        coordinator.applyOrDeferPlaybackProgress(CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 100,
            durationSeconds: 600,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other"),
            catalog: PlaybackCatalogSnapshot(
                content: .podcast(.init(
                    sourceURL: subscription.showURL,
                    episodeGUID: "guid-1",
                    episodeTitle: "Offline",
                    showTitle: "Show",
                    enclosureURL: "https://example.com/ep.mp3"
                )),
                modifiedAt: recent,
                deviceID: "other"
            )
        ))

        // 无 iCloud engine（测试环境）→ 云同步不可用，但本地快照恢复仍应执行。
        let outcome = await recovery.synchronizeAndRecover(trigger: .automatic)
        XCTAssertEqual(outcome.materializedFromSnapshot, 1)
        // 目录恢复本身未报错（失败分离：云不可用 ≠ 目录恢复失败）。
        XCTAssertNil(outcome.recoveryError)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EpisodeRecord>()).count, 1)
    }

    // MARK: - 辅助

    private static func feedXML(guid: String, enclosure: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Show</title>
        <item><title>Ep</title><guid>\(guid)</guid><enclosure url="\(enclosure)" type="audio/mpeg"/></item>
        </channel></rss>
        """
    }

    private final class CountingPodcastFetcher: PodcastFeedDataFetching, @unchecked Sendable {
        let feedXML: String
        private(set) var requestCount = 0

        init(feedXML: String) { self.feedXML = feedXML }

        func fetchFeedData(sourceURL: String) async throws -> Data {
            requestCount += 1
            // 模拟轻微网络延迟，让并发触发更可能重叠。
            try? await Task.sleep(nanoseconds: 5_000_000)
            return Data(feedXML.utf8)
        }
    }
}
