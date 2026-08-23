import XCTest
import SwiftData
@testable import CloudSyncKit
@testable import PodcastEnglishStudioCore
@testable import DomainModels

@MainActor
final class PlaybackCatalogRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var coordinator: CloudSyncCoordinator!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var fixedNow: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "CloudSyncKit.PlaybackCatalogRecoveryTests.\(UUID().uuidString)"
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

    // MARK: - 快照物化

    private func makePodcastState(
        sourceURL: String,
        guid: String,
        title: String,
        enclosureURL: String,
        position: Double,
        duration: Double,
        modifiedAt: Date
    ) -> CloudSyncCoordinator.PlaybackProgressState {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: sourceURL, episodeGUID: guid)
        )
        let snapshot = PlaybackCatalogSnapshot(
            content: .podcast(.init(
                sourceURL: sourceURL,
                episodeGUID: guid,
                episodeTitle: title,
                showTitle: "Show",
                enclosureURL: enclosureURL,
                publishedAt: Date(timeIntervalSince1970: 1_699_000_000)
            )),
            modifiedAt: modifiedAt,
            deviceID: "other-device"
        )
        return CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: position,
            durationSeconds: duration,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: modifiedAt, deviceID: "other-device"),
            catalog: snapshot
        )
    }

    func testMaterializesPodcastFromCompleteSnapshotAndAppliesProgress() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let state = makePodcastState(
            sourceURL: subscription.showURL,
            guid: "guid-1",
            title: "Recovered Episode",
            enclosureURL: "https://example.com/ep1.mp3",
            position: 120,
            duration: 600,
            modifiedAt: recent
        )
        coordinator.applyOrDeferPlaybackProgress(state)
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<EpisodeRecord>()).isEmpty)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        XCTAssertEqual(outcome.materializedFromSnapshot, 1)
        XCTAssertTrue(outcome.networkTargets.isEmpty)
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 0)

        let episodes = try context.fetch(FetchDescriptor<EpisodeRecord>())
        XCTAssertEqual(episodes.count, 1)
        let episode = try XCTUnwrap(episodes.first)
        XCTAssertEqual(episode.episodeTitle, "Recovered Episode")
        XCTAssertEqual(episode.episodeGUID, "guid-1")
        XCTAssertEqual(episode.enclosureURL, "https://example.com/ep1.mp3")
        XCTAssertEqual(episode.status, "queued")
        XCTAssertEqual(episode.pipelineStep, "discover")
        XCTAssertFalse(episode.isNew)
        // 物化后立即重放 deferred progress。
        XCTAssertEqual(episode.playbackPositionSeconds, 120)
        XCTAssertEqual(episode.playbackDurationSeconds, 600)
    }

    func testMaterializesYouTubeFromCompleteSnapshot() throws {
        let channel = YTChannelRecord(id: "UCabc", channelID: "UCabc", url: "https://youtube.com/channel/UCabc", displayName: "Chan", isEnabled: true)
        context.insert(channel)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(for: .youtubeVideo(videoID: "vid-1"))
        let snapshot = PlaybackCatalogSnapshot(
            content: .youtube(.init(
                videoID: "vid-1",
                channelID: "UCabc",
                title: "Recovered Video",
                playbackURL: "https://www.youtube.com/watch?v=vid-1",
                thumbnailURL: "https://i.ytimg.com/vi/vid-1/hqdefault.jpg"
            )),
            modifiedAt: recent,
            deviceID: "other-device"
        )
        let state = CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 45,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other-device"),
            catalog: snapshot
        )
        coordinator.applyOrDeferPlaybackProgress(state)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        XCTAssertEqual(outcome.materializedFromSnapshot, 1)

        let videos = try context.fetch(FetchDescriptor<YTVideoRecord>())
        XCTAssertEqual(videos.count, 1)
        let video = try XCTUnwrap(videos.first)
        XCTAssertEqual(video.id, "vid-1")
        XCTAssertEqual(video.title, "Recovered Video")
        XCTAssertEqual(video.channelRecordID, channel.id)
        XCTAssertEqual(video.playbackPositionSeconds, 45)
    }

    func testExistingLocalRecordAppliesProgressWithoutOverwritingCatalogMetadata() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        let existing = EpisodeRecord(
            subscriptionID: subscription.id,
            showTitle: "Local Show Title",
            episodeTitle: "Local Episode Title",
            episodeGUID: "guid-1",
            enclosureURL: "https://example.com/local.mp3"
        )
        context.insert(subscription)
        context.insert(existing)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let state = makePodcastState(
            sourceURL: subscription.showURL,
            guid: "guid-1",
            title: "Cloud Title Should Not Override",
            enclosureURL: "https://example.com/cloud.mp3",
            position: 200,
            duration: 600,
            modifiedAt: recent
        )
        coordinator.applyOrDeferPlaybackProgress(state)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        // 已有本地记录 → 只应用进度，不算物化。
        XCTAssertEqual(outcome.materializedFromSnapshot, 0)
        let episodes = try context.fetch(FetchDescriptor<EpisodeRecord>())
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.episodeTitle, "Local Episode Title")
        XCTAssertEqual(episodes.first?.enclosureURL, "https://example.com/local.mp3")
        XCTAssertEqual(episodes.first?.playbackPositionSeconds, 200)
    }

    // MARK: - 需要联网的目标

    func testMissingSnapshotYieldsPodcastNetworkTarget() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-old")
        )
        let state = CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 50,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other-device"),
            catalog: nil // 旧格式：无快照
        )
        coordinator.applyOrDeferPlaybackProgress(state)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        XCTAssertEqual(outcome.materializedFromSnapshot, 0)
        XCTAssertEqual(outcome.networkTargets.count, 1)
        guard case .podcast(let identity, _, let guids) = outcome.networkTargets.first else {
            return XCTFail("应产生 Podcast 网络目标")
        }
        XCTAssertEqual(identity, SyncRecordIdentity.podcast(sourceURL: subscription.showURL))
        XCTAssertEqual(guids, ["guid-old"])
        // 不应创建残缺记录。
        XCTAssertTrue(try context.fetch(FetchDescriptor<EpisodeRecord>()).isEmpty)
    }

    func testMissingSnapshotYieldsYouTubeNetworkTarget() throws {
        let channel = YTChannelRecord(id: "UCabc", channelID: "UCabc", url: "https://youtube.com/channel/UCabc", displayName: "Chan", isEnabled: true)
        context.insert(channel)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(for: .youtubeVideo(videoID: "vid-old"))
        let state = CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 50,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other-device"),
            catalog: nil
        )
        coordinator.applyOrDeferPlaybackProgress(state)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        guard case .youtube(let videoIDs) = outcome.networkTargets.first else {
            return XCTFail("应产生 YouTube 网络目标")
        }
        XCTAssertEqual(videoIDs, ["vid-old"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<YTVideoRecord>()).isEmpty)
    }

    func testIncompleteSnapshotFallsBackToNetworkTarget() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        let recent = fixedNow.addingTimeInterval(-3600)
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: "guid-bad")
        )
        // 快照存在但 enclosure 是本地路径（不完整）→ 走网络补全。
        let snapshot = PlaybackCatalogSnapshot(
            content: .podcast(.init(
                sourceURL: subscription.showURL,
                episodeGUID: "guid-bad",
                episodeTitle: "Bad",
                showTitle: "Show",
                enclosureURL: "/local/path.mp3"
            )),
            modifiedAt: recent,
            deviceID: "other-device"
        )
        let state = CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: 50,
            durationSeconds: 300,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: recent, deviceID: "other-device"),
            catalog: snapshot
        )
        coordinator.applyOrDeferPlaybackProgress(state)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        XCTAssertEqual(outcome.materializedFromSnapshot, 0)
        XCTAssertEqual(outcome.networkTargets.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<EpisodeRecord>()).isEmpty)
    }

    // MARK: - 筛选边界

    func testCompletedAndStaleRecordsAreNotRecovered() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: true)
        context.insert(subscription)
        try context.save()

        // 已完成：不在恢复范围。
        let completedState = makePodcastState(
            sourceURL: subscription.showURL, guid: "guid-done", title: "Done",
            enclosureURL: "https://example.com/done.mp3",
            position: 590, duration: 600, modifiedAt: fixedNow.addingTimeInterval(-3600)
        )
        var completed = completedState
        completed.completedAt = fixedNow.addingTimeInterval(-3700)
        coordinator.applyOrDeferPlaybackProgress(completed)

        // 超过 30 天：不在恢复范围。
        let stale = makePodcastState(
            sourceURL: subscription.showURL, guid: "guid-stale", title: "Stale",
            enclosureURL: "https://example.com/stale.mp3",
            position: 50, duration: 600, modifiedAt: fixedNow.addingTimeInterval(-31 * 24 * 3600)
        )
        coordinator.applyOrDeferPlaybackProgress(stale)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        XCTAssertEqual(outcome.materializedFromSnapshot, 0)
        XCTAssertTrue(outcome.networkTargets.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<EpisodeRecord>()).isEmpty)
    }

    func testDisabledSubscriptionIsNotRecovered() throws {
        let subscription = PodcastSubscription(showURL: "https://example.com/feed", displayName: "Show", isEnabled: false)
        context.insert(subscription)
        try context.save()

        let state = makePodcastState(
            sourceURL: subscription.showURL, guid: "guid-1", title: "Ep",
            enclosureURL: "https://example.com/ep.mp3",
            position: 50, duration: 600, modifiedAt: fixedNow.addingTimeInterval(-3600)
        )
        coordinator.applyOrDeferPlaybackProgress(state)

        let outcome = coordinator.recoverPendingPlaybackCatalog(context: context)
        XCTAssertEqual(outcome.materializedFromSnapshot, 0)
        XCTAssertTrue(outcome.networkTargets.isEmpty)
    }

    // MARK: - recordName 解析

    func testParsePodcastPlaybackRecordNameRoundTrips() {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: "https://example.com/feed", episodeGUID: "my-guid")
        )
        let parsed = CloudSyncCoordinator.parsePodcastPlaybackRecordName(recordName)
        XCTAssertEqual(parsed?.subscriptionIdentity, SyncRecordIdentity.podcast(sourceURL: "https://example.com/feed"))
        XCTAssertEqual(parsed?.episodeGUID, "my-guid")
        XCTAssertNil(CloudSyncCoordinator.parsePodcastPlaybackRecordName("playback-yt-abc"))
    }

    func testParseYouTubePlaybackRecordName() {
        XCTAssertEqual(
            CloudSyncCoordinator.parseYouTubePlaybackRecordName("playback-yt-abc123"),
            "abc123"
        )
        XCTAssertNil(CloudSyncCoordinator.parseYouTubePlaybackRecordName("playback-ep-x"))
    }
}
