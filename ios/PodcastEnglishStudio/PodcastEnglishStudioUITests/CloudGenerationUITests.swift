import XCTest

/// V10/WP14 — cloud generation UI states. All scenarios run against offline
/// fixtures (UITestSupport blocks the network); no DMIT or real service is
/// involved.
final class CloudGenerationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Podcast cloud states (iOS + tvOS)

    func testPodcastCloudQueuedShowsServerQueueStateWithoutRetry() {
        let app = launch(scenario: "podcast-cloud-queued")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 15)
        )
        XCTAssertTrue(app.staticTexts["Queued on the server"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["subtitle.retry"].exists)
        app.terminate()
    }

    func testPodcastCloudRunningShowsProgressAndAudioReadyFirst() {
        let app = launch(scenario: "podcast-cloud-running")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 15)
        )
        // Note: on iOS the running container's outer identifier is the legacy
        // "subtitle.error-state"; assert on the stable content instead.
        XCTAssertTrue(
            app.staticTexts["Generating bilingual subtitles"].waitForExistence(timeout: 5)
        )
        // Audio-ready-first: the remote job finished the audio while the
        // subtitles are still generating.
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.cloud-audio-ready"].waitForExistence(timeout: 5)
        )
        app.terminate()
    }

    func testPodcastCloudRetryableFailureShowsRetry() {
        let app = launch(scenario: "podcast-cloud-failed")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 15)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["subtitle.retry"].waitForExistence(timeout: 5)
        )
        // The localized cloud error keeps the stable [CODE] for diagnostics.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "[INTERNAL_ERROR]")
        ).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testPodcastCloudFinalFailureHidesRetry() {
        let app = launch(scenario: "podcast-cloud-failed-final")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 15)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.cloud-not-retryable"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.descendants(matching: .any)["subtitle.retry"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.clear-and-regenerate"].exists
        )
        app.terminate()
    }

    // MARK: - Video cloud states

    func testYouTubeCloudGeneratingShowsCloudStage() {
        let app = launch(scenario: "youtube-cloud-generating")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForPlayerScreen(app))
        #if !os(tvOS)
        // The cloud stage text renders in the status card and the sentence card.
        // (On tvOS the subtitle loader is intentionally accessibility-hidden.)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Translating Subtitles")
        ).firstMatch.waitForExistence(timeout: 5))
        #endif
        app.terminate()
    }

    func testYouTubeCloudFailedShowsLocalizedErrorAndHidesRetry() {
        let app = launch(scenario: "youtube-cloud-failed")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForPlayerScreen(app))
        #if os(tvOS)
        // tvOS surfaces the failure in the subtitle actions overlay: DPAD-UP
        // shows the chrome, focus starts on Subtitles; move right past Quality
        // and Playback speed to the actions button and open it.
        XCUIRemote.shared.press(.up)
        let actionsButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "View translation progress")
        ).firstMatch
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        #else
        let settingsButton = app.buttons["player.settings.navigation"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        #endif
        // SOURCE_RESTRICTED is not retryable: no direct retry action.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "[SOURCE_RESTRICTED]")
        ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Retry subtitle translation")
        ).firstMatch.exists)
        app.terminate()
    }

    // MARK: - Settings: cloud section, token masking, backend toggle

    func testSettingsCloudSectionShowsMaskedTokenOnly() {
        let app = launch(scenario: "tabs", tab: "settings", extraEnvironment: [
            "LINGUACAST_UI_CLOUD_FIXTURE": "1"
        ])
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        #if os(tvOS)
        // Hierarchical settings: open the Cloud Generation Service category first.
        selectFocusedRow(app, identifier: "settings.row.cloud_service")
        #endif
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.cloud-enabled"].waitForExistence(timeout: 10)
        )
        // Later rows of the section are virtualized until scrolled into view;
        // assert each row as it materializes.
        scrollUntilExists(app, identifier: "settings.cloud-status")
        XCTAssertTrue(app.descendants(matching: .any)["settings.cloud-status"].exists)
        scrollUntilExists(app, identifier: "settings.cloud-token")
        XCTAssertTrue(app.descendants(matching: .any)["settings.cloud-token"].exists)
        // Task 6: the raw token never appears on screen / in screenshots;
        // only the masked bullet form is shown.
        XCTAssertFalse(app.staticTexts["fixture-cloud-token"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "fixture-cloud")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "••••")
        ).firstMatch.exists)
        #if !os(tvOS)
        scrollUntilExists(app, identifier: "settings.cloud-active-jobs")
        XCTAssertTrue(app.descendants(matching: .any)["settings.cloud-active-jobs"].exists)
        // Task 8: with cloud generation active, the legacy key sections leave
        // the normal settings flow (scroll the whole form to prove absence is
        // not just virtualization).
        for _ in 0..<6 { app.swipeUp() }
        XCTAssertFalse(app.secureTextFields["settings.dashscope-api-key"].exists)
        #else
        XCUIRemote.shared.press(.menu)
        selectFocusedRow(app, identifier: "settings.row.about")
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.cloud-active-jobs"].waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.secureTextFields["settings.dashscope-api-key"].exists)
        #endif
        app.terminate()
    }

    // MARK: - Helpers

    /// The player screen identifier differs per platform: the iOS chrome
    /// overrides the inner identifier with "player.surface".
    private func waitForPlayerScreen(_ app: XCUIApplication) -> Bool {
        let any = app.descendants(matching: .any)
        return any["screen.youtube-player"].waitForExistence(timeout: 15)
            || any["player.surface"].exists
    }

    private func selectFocusedRow(_ app: XCUIApplication, identifier: String, maxMoves: Int = 14) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing settings row \(identifier)")
        #if os(tvOS)
        for _ in 0..<maxMoves {
            if element.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.select)
        #else
        element.tap()
        #endif
    }

    /// Forms virtualize off-screen rows; scroll until the row materializes
    /// (swipe on iOS, DPAD focus moves on tvOS).
    private func scrollUntilExists(
        _ app: XCUIApplication,
        identifier: String,
        maxSwipes: Int = 6
    ) {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<maxSwipes where !element.exists {
            #if os(tvOS)
            XCUIRemote.shared.press(.down)
            #else
            app.swipeUp()
            #endif
        }
    }

    private func launch(
        scenario: String,
        tab: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = scenario
        if let tab {
            app.launchEnvironment["LINGUACAST_UI_TAB"] = tab
        }
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments = [
            "-linguacast-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-linguacast-ui-scenario", scenario
        ]
        app.launch()
        return app
    }
}
