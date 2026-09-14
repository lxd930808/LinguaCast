import XCTest

/// V12 device-order UI coverage. These fixtures stay offline: they prove the
/// player still presents subtitles when cloud MP4 is absent (iframe on iOS,
/// native fallback on tvOS). Live cloud-hit playback is the handoff checklist.
final class CloudVideoMediaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testIOSIFrameReadyKeepsSubtitlesWithoutCloudMP4() {
        #if !os(tvOS)
        let app = launchYouTubeReady()
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["一条稳定的英文字幕。"].waitForExistence(timeout: 5))
        app.terminate()
        #endif
    }

    func testTVNativeReadyKeepsSubtitlesWithoutCloudMP4() {
        #if os(tvOS)
        let app = launchYouTubeReady()
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 12))
        app.terminate()
        #endif
    }

    private func launchYouTubeReady() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = "youtube-ready"
        app.launchArguments = [
            "-linguacast-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-linguacast-ui-scenario", "youtube-ready"
        ]
        app.launch()
        return app
    }
}
