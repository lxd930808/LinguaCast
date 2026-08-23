import XCTest

/// UI coverage for app-owned reversible YouTube fullscreen on iOS.
/// Uses the youtube-ready fixture so chrome controls are available without a live stream.
final class YouTubeFullscreenUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnterAndExitFullscreenKeepsPlayerScreen() throws {
        #if !os(tvOS)
        let app = launchYouTubeReady()
        let playerCue = app.staticTexts["A deterministic English subtitle."]
        XCTAssertTrue(playerCue.waitForExistence(timeout: 8))

        let enter = app.buttons["player.fullscreen.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 5), "Enter fullscreen control missing")
        XCTAssertTrue(enter.isHittable)
        enter.tap()

        let exit = app.buttons["player.fullscreen.exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "Exit fullscreen control missing")
        XCTAssertTrue(waitForWindow(app, landscape: true), "Fullscreen should request a landscape window")
        XCTAssertTrue(exit.isHittable)
        XCTAssertFalse(app.buttons["player.fullscreen.enter"].exists)

        let panel = app.descendants(matching: .any)["player.immersive-subtitle-panel"]
        let surface = app.descendants(matching: .any)["player.surface"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Immersive subtitle panel missing")
        XCTAssertTrue(surface.waitForExistence(timeout: 5), "Player fixture surface missing")
        XCTAssertGreaterThanOrEqual(
            panel.frame.minY,
            surface.frame.maxY - 1,
            "Subtitle panel must remain outside the player surface"
        )

        // Fixture subtitle content must remain after the layout-only fullscreen toggle.
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 5))
        XCTAssertTrue(playerCue.exists)

        exit.tap()
        XCTAssertTrue(enter.waitForExistence(timeout: 5), "Enter control should return after exit")
        XCTAssertTrue(waitForWindow(app, landscape: false), "Exit should restore the portrait window")
        XCTAssertFalse(app.buttons["player.fullscreen.exit"].exists)
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].exists)
        XCTAssertTrue(playerCue.exists)

        app.terminate()
        #endif
    }

    func testSettingsHasExactlyOneEntryAcrossInlineAndFullscreenLayouts() throws {
        #if !os(tvOS)
        let app = launchYouTubeReady()
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 8))

        let navigationSettings = app.buttons["player.settings.navigation"]
        let fullscreenSettings = app.buttons["player.settings.fullscreen"]
        XCTAssertTrue(navigationSettings.waitForExistence(timeout: 5))
        XCTAssertFalse(fullscreenSettings.exists)

        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForWindow(app, landscape: true))
        XCTAssertTrue(navigationSettings.waitForExistence(timeout: 5))
        XCTAssertFalse(fullscreenSettings.exists)

        let enter = app.buttons["player.fullscreen.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 5))
        enter.tap()

        XCTAssertTrue(fullscreenSettings.waitForExistence(timeout: 5))
        XCTAssertFalse(navigationSettings.exists)

        app.buttons["player.fullscreen.exit"].tap()
        XCTAssertTrue(navigationSettings.waitForExistence(timeout: 5))
        XCTAssertFalse(fullscreenSettings.exists)
        app.terminate()
        #endif
    }

    func testFullscreenExitControlStaysAboveChrome() throws {
        #if !os(tvOS)
        let app = launchYouTubeReady()
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 8))

        let enter = app.buttons["player.fullscreen.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 5))
        enter.tap()

        let exit = app.buttons["player.fullscreen.exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertTrue(exit.isHittable, "Exit button must remain tappable above the player")

        let settings = app.buttons.matching(
            NSPredicate(format: "label == %@", "Settings")
        ).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        // Entering fullscreen must not destroy the player screen identity.
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].exists)
        exit.tap()
        app.terminate()
        #endif
    }

    func testPortraitSentenceNavigationAndRepeatControls() throws {
        #if !os(tvOS)
        let app = launchYouTubeReady()
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Current sentence"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 / 3"].exists)

        let next = app.buttons["player.sentence.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.isEnabled)
        next.tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 5))

        let repeatButton = app.buttons["player.sentence.repeat"]
        XCTAssertTrue(repeatButton.exists)
        repeatButton.tap()
        XCTAssertTrue(repeatButton.isSelected)

        let playPause = app.buttons["player.play-pause"]
        XCTAssertTrue(playPause.exists)
        playPause.tap()
        XCTAssertEqual(playPause.label, "Pause")

        let timeline = app.sliders["player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertTrue(app.staticTexts["3 / 3"].waitForExistence(timeout: 5))

        let enter = app.buttons["player.fullscreen.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 5))
        enter.tap()
        XCTAssertTrue(app.buttons["player.fullscreen.exit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["player.timeline"].exists)
        app.buttons["player.fullscreen.exit"].tap()
        XCTAssertTrue(app.staticTexts["3 / 3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["player.sentence.repeat"].isSelected)
        app.terminate()
        #endif
    }

    func testSubtitleOffCollapsesReadingCardAndDisablesSentenceActions() throws {
        #if !os(tvOS)
        let app = launchYouTubeReady(subtitleDisplayMode: "off")
        XCTAssertTrue(app.staticTexts["Subtitles are off"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["player.sentence.next"].isEnabled)
        XCTAssertFalse(app.buttons["player.sentence.repeat"].isEnabled)
        XCTAssertFalse(app.buttons["player.sentence.replay"].exists)
        XCTAssertFalse(app.staticTexts["A deterministic English subtitle."].exists)
        app.terminate()
        #endif
    }

    func testRTLInterfaceKeepsMediaTimelineLeftToRight() throws {
        #if !os(tvOS)
        let app = launchYouTubeReady(language: "ar", locale: "ar_SA")
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 8))
        let timeline = app.sliders["player.timeline"]
        if !timeline.exists {
            app.descendants(matching: .any)["player.surface"].tap()
        }
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let elapsed = app.staticTexts["0:00"].firstMatch
        let duration = app.staticTexts["0:18"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertLessThan(elapsed.frame.midX, duration.frame.midX)
        app.terminate()
        #endif
    }

    func testAccessibilityDynamicTypeKeepsPrimaryControlsReachable() throws {
        #if !os(tvOS)
        let app = launchYouTubeReady(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 8))
        for identifier in ["player.play-pause", "player.sentence.next", "player.sentence.repeat"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing control: \(identifier)")
            XCTAssertGreaterThanOrEqual(button.frame.width, 43.5)
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5)
        }
        app.terminate()
        #endif
    }

    private func launchYouTubeReady(
        subtitleDisplayMode: String? = nil,
        language: String = "en",
        locale: String = "en_US",
        contentSizeCategory: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = "youtube-ready"
        if let subtitleDisplayMode {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_DISPLAY_MODE"] = subtitleDisplayMode
        }
        app.launchArguments = [
            "-linguacast-ui-testing",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "-linguacast-ui-scenario", "youtube-ready",
            "-linguacast-ui-start-portrait"
        ]
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        return app
    }

    private func waitForWindow(_ app: XCUIApplication, landscape: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if (frame.width > frame.height) == landscape {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }
}
