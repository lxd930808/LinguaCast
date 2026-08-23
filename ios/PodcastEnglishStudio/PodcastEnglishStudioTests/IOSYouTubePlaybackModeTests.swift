import XCTest
@testable import PodcastEnglishStudioCore

final class IOSYouTubePlaybackModeTests: XCTestCase {
    func testDefaultIsOfficialIFrameAndOnlyVisibleCase() {
        XCTAssertEqual(IOSYouTubePlaybackMode.default, .officialIFrame)
        XCTAssertEqual(IOSYouTubePlaybackMode.uiVisibleCases, [.officialIFrame])
        XCTAssertTrue(IOSYouTubePlaybackMode.allCases.contains(.localService))
        XCTAssertFalse(IOSYouTubePlaybackMode.uiVisibleCases.contains(.localService))
    }

    func testNormalizedFallsBackForMissingOrInvalidValues() {
        XCTAssertEqual(IOSYouTubePlaybackMode.normalized(nil), .officialIFrame)
        XCTAssertEqual(IOSYouTubePlaybackMode.normalized(""), .officialIFrame)
        XCTAssertEqual(IOSYouTubePlaybackMode.normalized("youtubekit"), .officialIFrame)
        XCTAssertEqual(IOSYouTubePlaybackMode.normalized(" OFFICIAL_IFRAME "), .officialIFrame)
        XCTAssertEqual(IOSYouTubePlaybackMode.normalized("local_service"), .localService)
    }

    func testEffectiveModeDefaultsToOfficialIFrameWithoutEnvironment() {
        XCTAssertEqual(
            IOSYouTubePlaybackMode.effective(configured: .officialIFrame, environment: [:]),
            .officialIFrame
        )
    }

    func testEffectiveModeFallsBackWhenLocalServiceLacksServerConfig() {
        // Hidden value stored (e.g. via sync) but no server configured → iframe.
        XCTAssertEqual(
            IOSYouTubePlaybackMode.effective(configured: .localService, environment: [:]),
            .officialIFrame
        )
        // Backend flag present but URL/token missing → still iframe.
        XCTAssertEqual(
            IOSYouTubePlaybackMode.effective(
                configured: .localService,
                environment: ["YT_PLAYBACK_BACKEND": "local-service"]
            ),
            .officialIFrame
        )
    }

    #if DEBUG
    func testEffectiveModeUsesLocalServiceWithValidDebugEnvironment() {
        let environment: [String: String] = [
            "YT_PLAYBACK_BACKEND": "local-service",
            "YT_LOCAL_MEDIA_BASE_URL": "http://192.168.1.10:8787",
            "YT_LOCAL_MEDIA_TOKEN": "token"
        ]
        XCTAssertEqual(
            IOSYouTubePlaybackMode.effective(configured: .officialIFrame, environment: environment),
            .localService
        )
    }
    #endif

    func testCaptionIngestionPolicyMapping() {
        // Test hosts are never tvOS, so this exercises the iOS mapping.
        XCTAssertEqual(
            IOSYouTubePlaybackMode.officialIFrame.captionIngestionPolicy,
            .acceptParseableContent
        )
        XCTAssertEqual(
            IOSYouTubePlaybackMode.localService.captionIngestionPolicy,
            .strict
        )
    }
}
