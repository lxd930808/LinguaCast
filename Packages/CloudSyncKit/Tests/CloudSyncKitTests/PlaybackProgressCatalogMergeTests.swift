import XCTest
@testable import CloudSyncKit
@testable import PodcastEnglishStudioCore

@MainActor
final class PlaybackProgressCatalogMergeTests: XCTestCase {
    private func podcastCatalog(
        sourceURL: String = "https://example.com/feed",
        guid: String = "guid-1",
        title: String = "Episode 1",
        enclosureURL: String = "https://example.com/ep1.mp3",
        modifiedAt: Date,
        deviceID: String = "phone"
    ) -> PlaybackCatalogSnapshot {
        PlaybackCatalogSnapshot(
            content: .podcast(.init(
                sourceURL: sourceURL,
                episodeGUID: guid,
                episodeTitle: title,
                showTitle: "Show",
                enclosureURL: enclosureURL
            )),
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
    }

    private func state(
        recordName: String,
        position: Double?,
        updatedAt: Date,
        deviceID: String,
        catalog: PlaybackCatalogSnapshot? = nil
    ) -> CloudSyncCoordinator.PlaybackProgressState {
        CloudSyncCoordinator.PlaybackProgressState(
            recordName: recordName,
            positionSeconds: position,
            durationSeconds: 100,
            completedAt: nil,
            version: SyncFieldVersion(modifiedAt: updatedAt, deviceID: deviceID),
            catalog: catalog
        )
    }

    // MARK: - 进度与快照独立 LWW

    func testNewerProgressWinsButKeepsNewerCatalog() {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: "https://example.com/feed", episodeGUID: "guid-1")
        )
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        let t3 = Date(timeIntervalSince1970: 300)

        // 远端进度更新（t3），但本地快照更新（t2 > 远端 t1）。
        let local = state(
            recordName: recordName,
            position: 10,
            updatedAt: t1,
            deviceID: "phone",
            catalog: podcastCatalog(title: "Newer local title", modifiedAt: t2, deviceID: "phone")
        )
        let remote = state(
            recordName: recordName,
            position: 90,
            updatedAt: t3,
            deviceID: "tv",
            catalog: podcastCatalog(title: "Older remote title", modifiedAt: t1, deviceID: "tv")
        )

        let merged = CloudSyncCoordinator.mergedPlaybackProgress(local: local, remote: remote)
        // 进度取较新的远端。
        XCTAssertEqual(merged.positionSeconds, 90)
        XCTAssertEqual(merged.version.modifiedAt, t3)
        // 快照取较新的本地。
        XCTAssertEqual(merged.catalog?.version.modifiedAt, t2)
        if case .podcast(let podcast)? = merged.catalog?.content {
            XCTAssertEqual(podcast.episodeTitle, "Newer local title")
        } else {
            XCTFail("应保留本地较新快照")
        }
    }

    func testRemoteProgressWithoutCatalogDoesNotClearLocalCatalog() {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .youtubeVideo(videoID: "vid-1")
        )
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)

        let local = state(
            recordName: recordName,
            position: 10,
            updatedAt: t1,
            deviceID: "phone",
            catalog: PlaybackCatalogSnapshot(
                content: .youtube(.init(videoID: "vid-1", channelID: "UC", title: "T", playbackURL: "https://www.youtube.com/watch?v=vid-1")),
                modifiedAt: t1,
                deviceID: "phone"
            )
        )
        // 旧客户端：进度更新但不带快照。
        let remote = state(recordName: recordName, position: 80, updatedAt: t2, deviceID: "tv", catalog: nil)

        let merged = CloudSyncCoordinator.mergedPlaybackProgress(local: local, remote: remote)
        XCTAssertEqual(merged.positionSeconds, 80)
        // 快照不得被清除。
        XCTAssertNotNil(merged.catalog)
    }

    func testNewerRemoteCatalogReplacesOlderLocalCatalog() {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .youtubeVideo(videoID: "vid-1")
        )
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)

        let local = state(
            recordName: recordName,
            position: 10,
            updatedAt: t1,
            deviceID: "phone",
            catalog: PlaybackCatalogSnapshot(
                content: .youtube(.init(videoID: "vid-1", channelID: "UC", title: "Old", playbackURL: "https://www.youtube.com/watch?v=vid-1")),
                modifiedAt: t1,
                deviceID: "phone"
            )
        )
        let remote = state(
            recordName: recordName,
            position: 10,
            updatedAt: t1,
            deviceID: "tv",
            catalog: PlaybackCatalogSnapshot(
                content: .youtube(.init(videoID: "vid-1", channelID: "UC", title: "New", playbackURL: "https://www.youtube.com/watch?v=vid-1")),
                modifiedAt: t2,
                deviceID: "tv"
            )
        )

        let merged = CloudSyncCoordinator.mergedPlaybackProgress(local: local, remote: remote)
        if case .youtube(let youtube)? = merged.catalog?.content {
            XCTAssertEqual(youtube.title, "New")
        } else {
            XCTFail("应采用较新远端快照")
        }
    }

    // MARK: - 身份校验

    func testSnapshotIdentityMismatchIsRejected() {
        // 快照声称 guid-1，但 recordName 对应 guid-2。
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: "https://example.com/feed", episodeGUID: "guid-2")
        )
        let snapshot = podcastCatalog(guid: "guid-1", modifiedAt: Date())
        XCTAssertEqual(
            CloudSyncCoordinator.catalogSnapshotRejection(snapshot, forRecordName: recordName),
            .identityMismatch
        )
    }

    func testSnapshotIdentityMatchIsAccepted() {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: "https://example.com/feed", episodeGUID: "guid-1")
        )
        // recordName 用的是归一化 URL；快照给带尾随斜杠/大小写差异的等价 URL 仍应匹配。
        let snapshot = podcastCatalog(sourceURL: " HTTPS://Example.com/feed/ ", guid: "guid-1", modifiedAt: Date())
        XCTAssertNil(CloudSyncCoordinator.catalogSnapshotRejection(snapshot, forRecordName: recordName))
    }

    func testIncompleteSnapshotIsRejectedEvenWithMatchingIdentity() {
        let recordName = CloudSyncCoordinator.playbackProgressRecordName(
            for: .podcastEpisode(subscriptionSourceURL: "https://example.com/feed", episodeGUID: "guid-1")
        )
        let snapshot = podcastCatalog(guid: "guid-1", enclosureURL: "/local/path.mp3", modifiedAt: Date())
        XCTAssertEqual(
            CloudSyncCoordinator.catalogSnapshotRejection(snapshot, forRecordName: recordName),
            .incomplete
        )
    }
}
