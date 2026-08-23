import XCTest
@testable import PodcastEnglishStudioCore

final class PlaybackCatalogSnapshotTests: XCTestCase {
    private func podcastSnapshot(
        sourceURL: String = "https://example.com/feed",
        guid: String = "guid-1",
        title: String = "Episode 1",
        enclosureURL: String = "https://example.com/ep1.mp3",
        schemaVersion: Int = PlaybackCatalogSnapshot.currentSchemaVersion,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        deviceID: String = "phone"
    ) -> PlaybackCatalogSnapshot {
        PlaybackCatalogSnapshot(
            schemaVersion: schemaVersion,
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

    private func youtubeSnapshot(
        videoID: String = "abc123",
        title: String = "Video",
        playbackURL: String = "https://www.youtube.com/watch?v=abc123",
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        deviceID: String = "phone"
    ) -> PlaybackCatalogSnapshot {
        PlaybackCatalogSnapshot(
            content: .youtube(.init(
                videoID: videoID,
                channelID: "UCabc",
                title: title,
                playbackURL: playbackURL
            )),
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
    }

    // MARK: - 完整性校验

    func testCompletePodcastAndYouTubeSnapshotsPass() {
        XCTAssertNil(PlaybackCatalogSnapshotPolicy.completenessRejection(podcastSnapshot()))
        XCTAssertNil(PlaybackCatalogSnapshotPolicy.completenessRejection(youtubeSnapshot()))
    }

    func testPodcastSnapshotRejectsEmptyGUIDTitleAndBadEnclosure() {
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(podcastSnapshot(guid: "  ")),
            .incomplete
        )
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(podcastSnapshot(title: "")),
            .incomplete
        )
        // 本地路径 / 无 scheme 的 URL 不可播放。
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(podcastSnapshot(enclosureURL: "/var/local/ep1.mp3")),
            .incomplete
        )
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(podcastSnapshot(enclosureURL: "not a url")),
            .incomplete
        )
    }

    func testYouTubeSnapshotRejectsEmptyIDTitleAndBadURL() {
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(youtubeSnapshot(videoID: "")),
            .incomplete
        )
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(youtubeSnapshot(title: "  ")),
            .incomplete
        )
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(youtubeSnapshot(playbackURL: "ftp://x/y")),
            .incomplete
        )
    }

    func testUnsupportedFutureSchemaIsRejected() {
        let future = podcastSnapshot(schemaVersion: PlaybackCatalogSnapshot.currentSchemaVersion + 1)
        XCTAssertEqual(
            PlaybackCatalogSnapshotPolicy.completenessRejection(future),
            .unsupportedSchema(found: PlaybackCatalogSnapshot.currentSchemaVersion + 1, supported: PlaybackCatalogSnapshot.currentSchemaVersion)
        )
    }

    // MARK: - Codable 往返

    func testSnapshotCodableRoundTrip() throws {
        let snapshot = podcastSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PlaybackCatalogSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    // MARK: - 候选筛选

    private func candidate(
        recordName: String,
        position: Double?,
        duration: Double?,
        completedAt: Date? = nil,
        modifiedAt: Date,
        isEnabled: Bool = true,
        isDeleted: Bool = false
    ) -> PlaybackRecoveryCandidateInput {
        PlaybackRecoveryCandidateInput(
            recordName: recordName,
            positionSeconds: position,
            durationSeconds: duration,
            completedAt: completedAt,
            progressModifiedAt: modifiedAt,
            isSourceEnabled: isEnabled,
            isSourceDeleted: isDeleted
        )
    }

    func testSelectsOnlyInProgressWithinRecencyWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-10 * 24 * 3600)
        let stale = now.addingTimeInterval(-31 * 24 * 3600)
        let inputs = [
            candidate(recordName: "inprogress", position: 50, duration: 100, modifiedAt: recent),
            candidate(recordName: "completed", position: 99, duration: 100, completedAt: recent, modifiedAt: recent),
            candidate(recordName: "unplayed", position: 1, duration: 100, modifiedAt: recent),
            candidate(recordName: "stale", position: 50, duration: 100, modifiedAt: stale)
        ]
        let selected = PlaybackRecoveryCandidatePolicy.selectCandidates(inputs, now: now)
        XCTAssertEqual(selected.map(\.recordName), ["inprogress"])
    }

    func testExcludesDisabledAndDeletedSources() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-3600)
        let inputs = [
            candidate(recordName: "disabled", position: 50, duration: 100, modifiedAt: recent, isEnabled: false),
            candidate(recordName: "deleted", position: 50, duration: 100, modifiedAt: recent, isDeleted: true),
            candidate(recordName: "ok", position: 50, duration: 100, modifiedAt: recent)
        ]
        let selected = PlaybackRecoveryCandidatePolicy.selectCandidates(inputs, now: now)
        XCTAssertEqual(selected.map(\.recordName), ["ok"])
    }

    func testRecencyBoundaryIsInclusiveAtThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let boundary = now.addingTimeInterval(-PlaybackRecoveryCandidatePolicy.recencyWindow)
        let justInside = boundary
        let justOutside = boundary.addingTimeInterval(-1)
        let inputs = [
            candidate(recordName: "inside", position: 50, duration: 100, modifiedAt: justInside),
            candidate(recordName: "outside", position: 50, duration: 100, modifiedAt: justOutside)
        ]
        let selected = PlaybackRecoveryCandidatePolicy.selectCandidates(inputs, now: now)
        XCTAssertEqual(selected.map(\.recordName), ["inside"])
    }

    func testCapsAtTwentyNewestOrderedByRecency() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inputs = (0..<30).map { index in
            candidate(
                recordName: "r\(index)",
                position: 50,
                duration: 100,
                modifiedAt: now.addingTimeInterval(TimeInterval(-index * 60))
            )
        }
        let selected = PlaybackRecoveryCandidatePolicy.selectCandidates(inputs, now: now)
        XCTAssertEqual(selected.count, 20)
        // 最新（index 0）应排最前。
        XCTAssertEqual(selected.first?.recordName, "r0")
        XCTAssertEqual(selected.last?.recordName, "r19")
    }

    // MARK: - 退避策略

    func testBackoffScheduleProgressesAndCapsAtSixHours() {
        XCTAssertEqual(PodcastCatalogMissPolicy.backoffInterval(consecutiveFailures: 1), 15 * 60)
        XCTAssertEqual(PodcastCatalogMissPolicy.backoffInterval(consecutiveFailures: 2), 60 * 60)
        XCTAssertEqual(PodcastCatalogMissPolicy.backoffInterval(consecutiveFailures: 3), 6 * 60 * 60)
        XCTAssertEqual(PodcastCatalogMissPolicy.backoffInterval(consecutiveFailures: 10), 6 * 60 * 60)
    }

    func testMayAttemptRespectsBackoffWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 从未失败 → 允许。
        XCTAssertTrue(PodcastCatalogMissPolicy.mayAttempt(consecutiveFailures: 0, lastAttemptAt: nil, now: now))
        // 失败 1 次，10 分钟前 → 未到 15 分钟，禁止。
        let tenMinutesAgo = now.addingTimeInterval(-10 * 60)
        XCTAssertFalse(PodcastCatalogMissPolicy.mayAttempt(consecutiveFailures: 1, lastAttemptAt: tenMinutesAgo, now: now))
        // 失败 1 次，20 分钟前 → 允许。
        let twentyMinutesAgo = now.addingTimeInterval(-20 * 60)
        XCTAssertTrue(PodcastCatalogMissPolicy.mayAttempt(consecutiveFailures: 1, lastAttemptAt: twentyMinutesAgo, now: now))
    }
}
