import XCTest
import SwiftData
import PodcastEnglishStudioCore
import DomainModels
@testable import CloudSyncKit

@MainActor
final class PlaybackProgressApplyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var coordinator: CloudSyncCoordinator!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuiteName = "CloudSyncKit.PlaybackProgressApplyTests.\(UUID().uuidString)"
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

    // MARK: - Identity match

    func testAppliesYouTubeProgressByVideoID() throws {
        let video = YTVideoRecord(
            id: "abc123",
            channelRecordID: "channel-1",
            channelID: "UCabc",
            title: "Demo",
            url: "https://youtube.com/watch?v=abc123"
        )
        context.insert(video)
        try context.save()

        let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let state = progressState(
            recordName: CloudSyncCoordinator.playbackProgressRecordName(
                for: .youtubeVideo(videoID: "abc123")
            ),
            position: 42,
            duration: 300,
            completedAt: nil,
            updatedAt: updatedAt,
            deviceID: "phone"
        )

        XCTAssertTrue(try coordinator.applyPlaybackProgressToLocalStore(state))
        XCTAssertEqual(video.playbackPositionSeconds, 42)
        XCTAssertEqual(video.playbackDurationSeconds, 300)
        XCTAssertNil(video.playbackCompletedAt)
        XCTAssertEqual(video.playbackUpdatedAt, updatedAt)
    }

    func testAppliesPodcastProgressBySubscriptionIdentityAndEpisodeGUID() throws {
        let subscription = PodcastSubscription(
            showURL: " HTTPS://Example.com/feed/ ",
            displayName: "Example Show"
        )
        let episode = EpisodeRecord(
            subscriptionID: subscription.id,
            showTitle: "Example Show",
            episodeTitle: "Episode 1",
            episodeGUID: " guid-001 ",
            enclosureURL: "https://example.com/ep1.mp3"
        )
        context.insert(subscription)
        context.insert(episode)
        try context.save()

        // Record name uses the same SyncRecordIdentity.podcast normalization as upload.
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(
                subscriptionSourceURL: "https://example.com/feed#ignored",
                episodeGUID: "guid-001"
            )
        )
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let completedAt = Date(timeIntervalSince1970: 1_700_000_180)
        let state = progressState(
            recordName: recordName,
            position: 500,
            duration: 600,
            completedAt: completedAt,
            updatedAt: updatedAt,
            deviceID: "tv"
        )

        XCTAssertTrue(try coordinator.applyPlaybackProgressToLocalStore(state))
        XCTAssertEqual(episode.playbackPositionSeconds, 500)
        XCTAssertEqual(episode.playbackDurationSeconds, 600)
        XCTAssertEqual(episode.playbackCompletedAt, completedAt)
        XCTAssertEqual(episode.playbackUpdatedAt, updatedAt)
    }

    // MARK: - Version conflict

    func testPreferredProgressKeepsNewerLocalOverOlderRemote() {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .youtubeVideo(videoID: "vid")
        )
        let local = progressState(
            recordName: recordName,
            position: 90,
            duration: 100,
            completedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 200),
            deviceID: "phone"
        )
        let remote = progressState(
            recordName: recordName,
            position: 10,
            duration: 100,
            completedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            deviceID: "tv"
        )

        let merged = CloudSyncCoordinator.preferredPlaybackProgress(local: local, remote: remote)
        XCTAssertEqual(merged, local)
    }

    func testDoesNotOverwriteNewerLocalSwiftDataWithOlderRemote() throws {
        let video = YTVideoRecord(
            id: "newer-local",
            channelRecordID: "channel-1",
            channelID: "UCabc",
            title: "Demo",
            url: "https://youtube.com/watch?v=newer-local"
        )
        video.playbackPositionSeconds = 80
        video.playbackDurationSeconds = 120
        video.playbackUpdatedAt = Date(timeIntervalSince1970: 300)
        context.insert(video)
        try context.save()

        let olderRemote = progressState(
            recordName: CloudSyncCoordinator.playbackProgressRecordName(
                for: .youtubeVideo(videoID: "newer-local")
            ),
            position: 5,
            duration: 120,
            completedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            deviceID: "tv"
        )

        XCTAssertTrue(try coordinator.applyPlaybackProgressToLocalStore(olderRemote))
        XCTAssertEqual(video.playbackPositionSeconds, 80)
        XCTAssertEqual(video.playbackUpdatedAt, Date(timeIntervalSince1970: 300))
    }

    // MARK: - Delayed local content

    func testDefersWhenLocalContentMissingThenAppliesAfterInsert() throws {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .youtubeVideo(videoID: "late-video")
        )
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_300)
        let state = progressState(
            recordName: recordName,
            position: 15,
            duration: 90,
            completedAt: nil,
            updatedAt: updatedAt,
            deviceID: "phone"
        )

        coordinator.applyOrDeferPlaybackProgress(state)
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<YTVideoRecord>()).count, 0)

        let video = YTVideoRecord(
            id: "late-video",
            channelRecordID: "channel-1",
            channelID: "UCabc",
            title: "Late",
            url: "https://youtube.com/watch?v=late-video"
        )
        context.insert(video)
        try context.save()

        try coordinator.retryPendingPlaybackApplications()
        XCTAssertEqual(coordinator.pendingPlaybackApplicationCount, 0)
        XCTAssertEqual(video.playbackPositionSeconds, 15)
        XCTAssertEqual(video.playbackDurationSeconds, 90)
        XCTAssertEqual(video.playbackUpdatedAt, updatedAt)
    }

    func testNeverCreatesIncompleteRecordsWhenContentMissing() throws {
        let podcastState = progressState(
            recordName: CloudSyncCoordinator.playbackProgressRecordName(
                for: .podcastEpisode(
                    subscriptionSourceURL: "https://example.com/missing-feed",
                    episodeGUID: "missing-guid"
                )
            ),
            position: 1,
            duration: 2,
            completedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50),
            deviceID: "phone"
        )

        XCTAssertFalse(try coordinator.applyPlaybackProgressToLocalStore(podcastState))
        XCTAssertTrue(try context.fetch(FetchDescriptor<EpisodeRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PodcastSubscription>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<YTVideoRecord>()).isEmpty)
    }

    // MARK: - Completed / duration writeback

    func testWritesCompletedAtAndDurationForPodcastAndYouTube() throws {
        let subscription = PodcastSubscription(
            showURL: "https://podcast.example/show",
            displayName: "Show"
        )
        let episode = EpisodeRecord(
            subscriptionID: subscription.id,
            showTitle: "Show",
            episodeTitle: "Done",
            episodeGUID: "ep-done",
            enclosureURL: "https://podcast.example/done.mp3"
        )
        let video = YTVideoRecord(
            id: "yt-done",
            channelRecordID: "channel-1",
            channelID: "UCabc",
            title: "Done",
            url: "https://youtube.com/watch?v=yt-done"
        )
        context.insert(subscription)
        context.insert(episode)
        context.insert(video)
        try context.save()

        let episodeCompletedAt = Date(timeIntervalSince1970: 1_700_000_400)
        let episodeUpdatedAt = Date(timeIntervalSince1970: 1_700_000_410)
        XCTAssertTrue(
            try coordinator.applyPlaybackProgressToLocalStore(
                progressState(
                    recordName: CloudSyncCoordinator.playbackProgressRecordName(
                        for: .podcastEpisode(
                            subscriptionSourceURL: subscription.showURL,
                            episodeGUID: episode.episodeGUID
                        )
                    ),
                    position: 595,
                    duration: 600,
                    completedAt: episodeCompletedAt,
                    updatedAt: episodeUpdatedAt,
                    deviceID: "phone"
                )
            )
        )
        XCTAssertEqual(episode.playbackDurationSeconds, 600)
        XCTAssertEqual(episode.playbackCompletedAt, episodeCompletedAt)
        XCTAssertEqual(episode.playbackUpdatedAt, episodeUpdatedAt)

        let videoCompletedAt = Date(timeIntervalSince1970: 1_700_000_420)
        let videoUpdatedAt = Date(timeIntervalSince1970: 1_700_000_430)
        XCTAssertTrue(
            try coordinator.applyPlaybackProgressToLocalStore(
                progressState(
                    recordName: CloudSyncCoordinator.playbackProgressRecordName(
                        for: .youtubeVideo(videoID: video.id)
                    ),
                    position: 1180,
                    duration: 1200,
                    completedAt: videoCompletedAt,
                    updatedAt: videoUpdatedAt,
                    deviceID: "tv"
                )
            )
        )
        XCTAssertEqual(video.playbackDurationSeconds, 1200)
        XCTAssertEqual(video.playbackCompletedAt, videoCompletedAt)
        XCTAssertEqual(video.playbackUpdatedAt, videoUpdatedAt)
    }

    // MARK: - Helpers

    private func progressState(
        recordName: String,
        position: Double?,
        duration: Double?,
        completedAt: Date?,
        updatedAt: Date,
        deviceID: String
    ) -> CloudSyncCoordinator.PlaybackProgressState {
        CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: position,
            durationSeconds: duration,
            completedAt: completedAt,
            version: SyncFieldVersion(modifiedAt: updatedAt, deviceID: deviceID)
        )
    }
}
