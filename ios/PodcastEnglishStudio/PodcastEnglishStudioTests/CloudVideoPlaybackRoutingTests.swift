import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

final class CloudVideoPlaybackRoutingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_076_800)

    func testIFrameNeverAttemptsCloud() {
        XCTAssertFalse(CloudVideoPlaybackRouting.shouldAttemptCloud(usesOfficialIFrame: true))
        XCTAssertTrue(CloudVideoPlaybackRouting.shouldAttemptCloud(usesOfficialIFrame: false))
    }

    func testAutoQualityAcceptsReadyCompatibleRendition() {
        let candidate = sampleCandidate(height: 720)
        let decision = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(candidate),
            quality: .highestQuality,
            expectedDuration: 212.5,
            supportsAV1: false,
            now: now
        )
        guard case .useCloud(let used) = decision else {
            return XCTFail("expected useCloud, got \(decision)")
        }
        XCTAssertEqual(used.mediaId, candidate.mediaId)
    }

    func testManualQualityMissWhenCloudIsShorterThanRequested() {
        let decision = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate(height: 720)),
            quality: .preferred(maxHeight: 1080),
            expectedDuration: nil,
            supportsAV1: false,
            now: now
        )
        XCTAssertEqual(decision, .manualQualityMiss)
    }

    func testManualQualityAcceptsEqualOrTallerRendition() {
        let decision = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate(height: 1080)),
            quality: .preferred(maxHeight: 720),
            expectedDuration: nil,
            supportsAV1: false,
            now: now
        )
        guard case .useCloud = decision else {
            return XCTFail("expected useCloud, got \(decision)")
        }
    }

    func testVP9IsIncompatible() {
        let decision = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate(videoCodec: "vp9")),
            quality: nil,
            expectedDuration: nil,
            supportsAV1: true,
            now: now
        )
        XCTAssertEqual(decision, .fallback(.incompatible))
    }

    func testAV1RequiresHardwareSupport() {
        let withoutHardware = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate(videoCodec: "av01.0.08M.08")),
            quality: nil,
            expectedDuration: nil,
            supportsAV1: false,
            now: now
        )
        XCTAssertEqual(withoutHardware, .fallback(.incompatible))

        let withHardware = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate(videoCodec: "av01.0.08M.08")),
            quality: nil,
            expectedDuration: nil,
            supportsAV1: true,
            now: now
        )
        guard case .useCloud = withHardware else {
            return XCTFail("expected useCloud for AV1 with hardware, got \(withHardware)")
        }
    }

    func testDurationMismatchFallsBack() {
        let decision = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate(duration: 212.5)),
            quality: nil,
            expectedDuration: 300,
            supportsAV1: false,
            now: now
        )
        XCTAssertEqual(decision, .fallback(.durationMismatch))
    }

    func testDurationWithinThresholdIsAccepted() {
        XCTAssertFalse(
            CloudVideoPlaybackRouting.durationMismatchExceedsThreshold(
                videoSeconds: 212.5,
                expectedSeconds: 212.7
            )
        )
        let decision = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate(duration: 212.5)),
            quality: nil,
            expectedDuration: 212.7,
            supportsAV1: false,
            now: now
        )
        guard case .useCloud = decision else {
            return XCTFail("expected useCloud, got \(decision)")
        }
    }

    func testMissNotReadyAndOldServerAreSilentFallback() {
        XCTAssertEqual(
            CloudVideoPlaybackRouting.decideOnLookup(
                outcome: .notFound,
                quality: nil,
                expectedDuration: nil,
                supportsAV1: false,
                now: now
            ),
            .fallback(.miss)
        )
        XCTAssertEqual(
            CloudVideoPlaybackRouting.decideOnLookup(
                outcome: .notReady(retryAfterSeconds: 8),
                quality: nil,
                expectedDuration: nil,
                supportsAV1: false,
                now: now
            ),
            .fallback(.notReady)
        )
        XCTAssertEqual(
            CloudVideoPlaybackRouting.decideOnLookup(
                outcome: .transport,
                quality: nil,
                expectedDuration: nil,
                supportsAV1: false,
                now: now
            ),
            .fallback(.transport)
        )
    }

    func testCloudPlayer401RefreshesOnceThenFallsBack() {
        XCTAssertEqual(
            CloudVideoPlaybackRouting.decideOnPlayerFailure(
                statusCode: 401,
                currentSelectionMode: CloudVideoPlaybackRouting.selectionMode,
                didRefreshCloudURL: false
            ),
            .refreshCloudOnce
        )
        XCTAssertEqual(
            CloudVideoPlaybackRouting.decideOnPlayerFailure(
                statusCode: 403,
                currentSelectionMode: CloudVideoPlaybackRouting.selectionMode,
                didRefreshCloudURL: true
            ),
            .fallback(.unauthorized)
        )
    }

    func testYouTubeFailureDoesNotUseCloudRefresh() {
        let decision = CloudVideoPlaybackRouting.decideOnPlayerFailure(
            statusCode: 403,
            currentSelectionMode: "direct-preflight",
            didRefreshCloudURL: false
        )
        XCTAssertEqual(decision, .fallback(.miss))
    }

    func testNetworkChangeDoesNotRebuildCloudMedia() {
        XCTAssertFalse(
            CloudVideoPlaybackRouting.shouldReapplyOnNetworkChange(
                selectionMode: CloudVideoPlaybackRouting.selectionMode
            )
        )
        XCTAssertTrue(
            CloudVideoPlaybackRouting.shouldReapplyOnNetworkChange(selectionMode: "hls")
        )
    }

    func testPlaybackSelectionIsDirectCloudMP4() {
        let selection = CloudVideoPlaybackRouting.playbackSelection(from: sampleCandidate())
        XCTAssertEqual(selection.selectionMode, "cloud-media")
        XCTAssertEqual(selection.actualHeight, 720)
        if case .direct(let stream) = selection.source {
            XCTAssertEqual(stream.itag, 0)
            XCTAssertEqual(stream.container, "mp4")
            XCTAssertEqual(stream.videoCodec, .avc1)
        } else {
            XCTFail("expected direct source")
        }
    }

    func testAvailableTiersOnlyExposeTheActualHeight() {
        let tiers = CloudVideoPlaybackRouting.availableQualityTiers(height: 720)
        XCTAssertEqual(tiers, [.preferred(maxHeight: 720)])
    }

    func testIOSToTVNativeAttemptsCloudWhileIFrameDoesNot() {
        // Device-order coverage at the policy layer: tvOS / iOS native ask the
        // cloud first; iOS iframe never does, even when the same contentKey is ready.
        XCTAssertTrue(CloudVideoPlaybackRouting.shouldAttemptCloud(usesOfficialIFrame: false))
        XCTAssertFalse(CloudVideoPlaybackRouting.shouldAttemptCloud(usesOfficialIFrame: true))
        let hit = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate()),
            quality: .highestQuality,
            expectedDuration: nil,
            supportsAV1: false,
            now: now
        )
        guard case .useCloud = hit else {
            return XCTFail("native auto quality must accept a ready cloud MP4")
        }
    }

    func testNotReadyThenReadyConvergesOnHit() {
        XCTAssertEqual(
            CloudVideoPlaybackRouting.decideOnLookup(
                outcome: .notReady(retryAfterSeconds: 5),
                quality: nil,
                expectedDuration: nil,
                supportsAV1: false,
                now: now
            ),
            .fallback(.notReady)
        )
        let later = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: .ready(sampleCandidate()),
            quality: nil,
            expectedDuration: nil,
            supportsAV1: false,
            now: now
        )
        guard case .useCloud = later else {
            return XCTFail("a later ready lookup must become a cloud hit")
        }
    }

    private func sampleCandidate(
        height: Int = 720,
        duration: Double = 212.5,
        videoCodec: String = "avc1",
        audioCodec: String = "aac"
    ) -> CloudVideoPlaybackCandidate {
        CloudVideoPlaybackCandidate(
            mediaId: "cm_01JFXB2C4E6G8J0M2P4R",
            contentKey: "video:youtube:dQw4w9WgXcQ",
            url: URL(string: "https://r2.example.com/video.mp4?X-Amz-Signature=redacted")!,
            expiresAt: now.addingTimeInterval(3600),
            mimeType: "video/mp4",
            bytes: 48_234_496,
            sha256: String(repeating: "ab", count: 32),
            durationSeconds: duration,
            height: height,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            acceptRanges: "bytes",
            mediaVersion: "mp4-\(height)-avc1-aac",
            createdAt: now.addingTimeInterval(-3600)
        )
    }
}
