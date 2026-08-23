import XCTest
import SwiftData
@testable import CloudSyncKit
@testable import PodcastEnglishStudioCore
@testable import DomainModels

@MainActor
final class PlaybackProgressReportingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var coordinator: CloudSyncCoordinator!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "CloudSyncKit.PlaybackProgressReportingTests.\(UUID().uuidString)"
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
    }

    override func tearDown() {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaults = nil
        coordinator = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - 领域对象上报生成快照

    func testPodcastDomainReportingAttachesCatalogSnapshot() throws {
        let subscription = PodcastSubscription(
            showURL: "https://example.com/feed",
            displayName: "Example Show"
        )
        let episode = EpisodeRecord(
            subscriptionID: subscription.id,
            showTitle: "Example Show",
            showArtist: "Host",
            episodeTitle: "Episode 1",
            episodeGUID: "guid-1",
            publishedAt: Date(timeIntervalSince1970: 1_699_000_000),
            enclosureURL: "https://example.com/ep1.mp3"
        )
        context.insert(subscription)
        context.insert(episode)
        try context.save()

        coordinator.recordPlaybackProgress(
            episode: episode,
            subscription: subscription,
            positionSeconds: 42,
            durationSeconds: 300,
            completedAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-1")
        )
        let state = coordinator.playbackProgressStateForTesting(recordName: recordName)
        XCTAssertEqual(state?.positionSeconds, 42)
        guard case .podcast(let podcast)? = state?.catalog?.content else {
            return XCTFail("应携带 Podcast 快照")
        }
        XCTAssertEqual(podcast.episodeGUID, "guid-1")
        XCTAssertEqual(podcast.episodeTitle, "Episode 1")
        XCTAssertEqual(podcast.enclosureURL, "https://example.com/ep1.mp3")
        // 快照身份必须与 recordName 一致。
        XCTAssertNil(CloudSyncCoordinator.catalogSnapshotRejection(state!.catalog!, forRecordName: recordName))
    }

    func testYouTubeDomainReportingAttachesCatalogSnapshot() throws {
        let video = YTVideoRecord(
            id: "abc123",
            channelRecordID: "channel-1",
            channelID: "UCabc",
            title: "Demo",
            publishedAt: Date(timeIntervalSince1970: 1_699_000_000),
            url: "https://www.youtube.com/watch?v=abc123",
            thumbnail: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"
        )
        context.insert(video)
        try context.save()

        coordinator.recordPlaybackProgress(
            video: video,
            positionSeconds: 15,
            durationSeconds: 90,
            completedAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let recordName = CloudSyncCoordinator.playbackProgressRecordName(for: .youtubeVideo(videoID: "abc123"))
        let state = coordinator.playbackProgressStateForTesting(recordName: recordName)
        guard case .youtube(let youtube)? = state?.catalog?.content else {
            return XCTFail("应携带 YouTube 快照")
        }
        XCTAssertEqual(youtube.videoID, "abc123")
        XCTAssertEqual(youtube.channelID, "UCabc")
        XCTAssertEqual(youtube.title, "Demo")
        XCTAssertEqual(youtube.thumbnailURL, "https://i.ytimg.com/vi/abc123/hqdefault.jpg")
    }

    func testEpisodeWithLocalEnclosureProducesNoSnapshot() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show")
        let episode = EpisodeRecord(
            subscriptionID: subscription.id,
            showTitle: "Show",
            episodeTitle: "Local only",
            episodeGUID: "guid-local",
            enclosureURL: "/var/mobile/local.mp3"
        )
        context.insert(subscription)
        context.insert(episode)
        try context.save()

        coordinator.recordPlaybackProgress(
            episode: episode,
            subscription: subscription,
            positionSeconds: 10,
            durationSeconds: 100,
            completedAt: nil
        )
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-local")
        )
        // 进度仍写入，但不生成残缺快照。
        let state = coordinator.playbackProgressStateForTesting(recordName: recordName)
        XCTAssertNotNil(state)
        XCTAssertNil(state?.catalog)
    }

    // MARK: - 30 天快照回填

    func testBackfillAddsSnapshotToLegacyRecord() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show")
        let episode = EpisodeRecord(
            subscriptionID: subscription.id,
            showTitle: "Show",
            episodeTitle: "Legacy",
            episodeGUID: "guid-legacy",
            enclosureURL: "https://example.com/legacy.mp3"
        )
        context.insert(subscription)
        context.insert(episode)
        try context.save()

        // 旧路径：无快照的进度记录。
        coordinator.recordPlaybackProgress(
            .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-legacy"),
            positionSeconds: 20,
            durationSeconds: 200,
            completedAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-legacy")
        )
        XCTAssertNil(coordinator.playbackProgressStateForTesting(recordName: recordName)?.catalog)

        let changed = coordinator.backfillMissingCatalogSnapshots(context: context)
        XCTAssertTrue(changed)
        let state = coordinator.playbackProgressStateForTesting(recordName: recordName)
        XCTAssertNotNil(state?.catalog)
        // 进度未被改动。
        XCTAssertEqual(state?.positionSeconds, 20)
    }

    func testBackfillSkipsRecordsThatAlreadyHaveSnapshotsAndMissingContent() throws {
        let video = YTVideoRecord(
            id: "have-snap",
            channelRecordID: "c",
            channelID: "UC",
            title: "Has snapshot",
            url: "https://www.youtube.com/watch?v=have-snap"
        )
        context.insert(video)
        try context.save()

        coordinator.recordPlaybackProgress(
            video: video,
            positionSeconds: 5,
            durationSeconds: 50,
            completedAt: nil
        )
        // 一条没有对应本地内容的记录。
        coordinator.recordPlaybackProgress(
            .youtubeVideo(videoID: "missing-content"),
            positionSeconds: 5,
            durationSeconds: 50,
            completedAt: nil
        )

        let changed = coordinator.backfillMissingCatalogSnapshots(context: context)
        XCTAssertFalse(changed)
        let snapRecordName = CloudSyncCoordinator.playbackProgressRecordName(for: .youtubeVideo(videoID: "have-snap"))
        XCTAssertNotNil(coordinator.playbackProgressStateForTesting(recordName: snapRecordName)?.catalog)
        let missingRecordName = CloudSyncCoordinator.playbackProgressRecordName(for: .youtubeVideo(videoID: "missing-content"))
        XCTAssertNil(coordinator.playbackProgressStateForTesting(recordName: missingRecordName)?.catalog)
    }
}
