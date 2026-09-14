import XCTest

final class V17PlaybackSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPodcastSettingsAndSubtitleShortcutRemainReachable() throws {
        #if os(tvOS)
        throw XCTSkip("Podcast playback settings are iOS-only")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-linguacast-ui-scenario", "podcast-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["player.settings.podcast"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["transcript.translation-toggle"].exists)
        XCTAssertTrue(app.buttons["player.mode-original"].exists)
        XCTAssertTrue(app.buttons["player.mode-chinese"].exists)
        XCTAssertFalse(app.buttons["player.rhythm-natural"].exists)
        XCTAssertFalse(app.buttons["player.prepare-chinese"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["media.playback-controls"].exists)
        capture(app, name: "V17-podcast-original")
        // AX converts pixel coordinates to points; allow only floating-point roundoff.
        for identifier in ["player.settings.podcast", "transcript.translation-toggle",
                           "player.mode-original", "player.mode-chinese",
                           "player.skip-back", "player.skip-forward", "player.play-pause"] {
            let control = app.buttons[identifier]
            XCTAssertGreaterThanOrEqual(control.frame.width + 0.001, 44, identifier)
            XCTAssertGreaterThanOrEqual(control.frame.height + 0.001, 44, identifier)
        }

        app.buttons["player.settings.podcast"].tap()
        XCTAssertTrue(app.buttons["player.rhythm-natural"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["player.rhythm-current"].exists)
        XCTAssertTrue(app.buttons["player.prepare-chinese"].exists)
        XCTAssertTrue(app.buttons["podcast.clear-and-regenerate"].exists)
        capture(app, name: "V17-podcast-settings")
        app.buttons["player.settings.subtitle-presentation"].tap()
        XCTAssertTrue(app.steppers["settings.subtitle.english-size"].waitForExistence(timeout: 5))
        let before = app.steppers["settings.subtitle.english-size"].value as? String
        app.steppers["settings.subtitle.english-size"].buttons["settings.subtitle.english-size-Increment"].tap()
        XCTAssertNotEqual(app.steppers["settings.subtitle.english-size"].value as? String, before)
        capture(app, name: "V17-podcast-subtitle-settings")
        #endif
    }

    func testVideoSubtitleShortcutReturnsToPlaybackSettings() throws {
        #if os(tvOS)
        throw XCTSkip("Video sheet shortcuts are iOS-only")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-linguacast-ui-scenario", "youtube-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["player.settings.navigation"].waitForExistence(timeout: 15))
        for identifier in ["player.settings.navigation", "player.play-pause", "player.sentence.next", "player.sentence.repeat"] {
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.width + 0.001, 44, identifier)
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.height + 0.001, 44, identifier)
        }
        app.buttons["player.settings.navigation"].tap()
        XCTAssertTrue(app.buttons["player.settings.close"].waitForExistence(timeout: 5))
        capture(app, name: "V17-video-settings")
        app.buttons["player.settings.subtitle-presentation"].tap()
        let size = app.steppers["settings.subtitle.english-size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        let before = size.value as? String
        size.buttons["settings.subtitle.english-size-Increment"].tap()
        XCTAssertNotEqual(size.value as? String, before)
        capture(app, name: "V17-video-subtitle-settings")
        app.navigationBars.buttons["Playback Settings"].tap()
        XCTAssertTrue(app.buttons["player.settings.close"].waitForExistence(timeout: 5))
        app.buttons["player.settings.close"].tap()
        XCTAssertTrue(app.buttons["player.sentence.next"].waitForExistence(timeout: 5))
        #endif
    }

    func testFirstLaunchGuidanceRoutesToSubscriptionsAndSettings() throws {
        #if os(tvOS)
        throw XCTSkip("Assistant is iOS-only")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-linguacast-ui-scenario", "first-launch"]
        app.launch()
        defer { app.terminate() }
        let empty = app.descendants(matching: .any)["home.empty-continue"]
        XCTAssertTrue(empty.waitForExistence(timeout: 15))
        XCTAssertEqual(empty.buttons.count, 2)
        capture(app, name: "V17-first-launch-empty")
        empty.buttons["Add subscription"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.subscriptions"].waitForExistence(timeout: 5))
        app.tabBars.buttons["tab.assistant"].tap()
        let setup = app.descendants(matching: .any)["assistant.setup-required"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertEqual(setup.buttons.count, 1)
        setup.buttons["Settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 5))
        #endif
    }

    func testTVChannelGridNavigatesTwoRowsAndRestoresFocus() throws {
        #if os(tvOS)
        let app = XCUIApplication()
        app.launchArguments = ["-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-linguacast-ui-scenario", "youtube-channel"]
        app.launchEnvironment["LINGUACAST_UI_CHANNEL_GRID"] = "1"
        app.launch()
        defer { app.terminate() }
        func card(_ index: Int) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "V17 Grid Video \(index),")).firstMatch
        }
        XCTAssertTrue(app.staticTexts["V17 Grid Video 1"].waitForExistence(timeout: 15))
        print("V17 grid hierarchy: \(app.debugDescription)")
        let first = card(1)
        let second = card(2)
        XCTAssertTrue(first.exists)
        XCTAssertTrue(second.exists)
        XCTAssertEqual(first.frame.midX, second.frame.midX, accuracy: 5)
        XCTAssertGreaterThan(second.frame.midY - first.frame.midY, 300)
        XCTAssertTrue(app.moveRemoteFocus(to: first))
        capture(app, name: "V17-tv-grid-first-row")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(second.hasFocus)
        capture(app, name: "V17-tv-grid-second-row")
        XCUIRemote.shared.press(.right)
        let fourth = card(4)
        XCTAssertTrue(fourth.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["screen.youtube-player"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        if !app.descendants(matching: .any)["screen.youtube-channel"].waitForExistence(timeout: 2) {
            XCUIRemote.shared.press(.menu)
        }
        XCTAssertTrue(app.descendants(matching: .any)["screen.youtube-channel"].waitForExistence(timeout: 5))
        XCTAssertTrue(fourth.hasFocus)
        capture(app, name: "V17-tv-grid-return")
        #else
        throw XCTSkip("Channel grid remote navigation is tvOS-only")
        #endif
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/private/tmp/LinguaCastV17", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        try? app.debugDescription.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }
}
