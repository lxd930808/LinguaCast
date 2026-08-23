import XCTest

final class PodcastPlaybackStateTabsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPodcastProgramDetailDefaultsToUnplayedTabWithCountsAndEmptyPlayedState() {
        let app = launch(scenario: "podcast-large-list")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.episode.ui-large-episode-1"].waitForExistence(timeout: 15)
        )
        XCTAssertTrue(app.descendants(matching: .any)["podcast.program-header"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["podcast.program-summary"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["podcast.apple-source-link"].exists)

        let categoryPicker = app.descendants(matching: .any)["podcast.playback-category"]
        XCTAssertTrue(categoryPicker.waitForExistence(timeout: 5))

        XCTAssertTrue(segment(named: "Unplayed 999", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(segment(named: "In progress 1", in: app).exists)
        XCTAssertTrue(segment(named: "Played 0", in: app).exists)

        XCTAssertEqual(
            app.descendants(matching: .any)["podcast.playback-category-title"].label,
            "Unplayed"
        )
        XCTAssertFalse(app.descendants(matching: .any)["podcast.episode.ui-episode-podcast-large-list"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["podcast.playback-category-empty"].exists)

        #if os(tvOS)
        selectSegment(named: "In progress 1", in: app)
        #else
        segment(named: "In progress 1", in: app).tap()
        #endif
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.episode.ui-episode-podcast-large-list"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["podcast.playback-category-title"].label,
            "In progress"
        )
        XCTAssertFalse(app.descendants(matching: .any)["podcast.episode.ui-large-episode-1"].exists)

        #if os(tvOS)
        selectSegment(named: "Played 0", in: app)
        #else
        segment(named: "Played 0", in: app).tap()
        #endif
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.playback-category-empty"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["podcast.playback-category-title"].label,
            "Played"
        )
        XCTAssertTrue(app.staticTexts["None yet"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["podcast.episode.ui-large-episode-1"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["podcast.episode.ui-episode-podcast-large-list"].exists)

        app.terminate()
    }

    func testPodcastProgramDetailOpensSelectedCategoryEpisode() {
        let app = launch(scenario: "podcast-large-list")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.episode.ui-large-episode-1"].waitForExistence(timeout: 15)
        )

        #if os(tvOS)
        selectSegment(named: "In progress 1", in: app)
        let inProgressEpisode = app.descendants(matching: .any)["podcast.episode.ui-episode-podcast-large-list"]
        XCTAssertTrue(inProgressEpisode.waitForExistence(timeout: 5))
        focusAndSelect(inProgressEpisode)
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8)
                || app.buttons["Close"].waitForExistence(timeout: 8)
        )
        #else
        segment(named: "In progress 1", in: app).tap()
        let inProgressEpisode = app.descendants(matching: .any)["podcast.episode.ui-episode-podcast-large-list"]
        XCTAssertTrue(inProgressEpisode.waitForExistence(timeout: 5))
        inProgressEpisode.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8)
                || app.navigationBars.buttons["Close"].waitForExistence(timeout: 8)
                || app.buttons["Close"].waitForExistence(timeout: 8)
        )
        #endif
        XCTAssertTrue(
            app.descendants(matching: .any)["podcast.episode-metadata"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["podcast.episode-summary"].exists)

        app.terminate()
    }

    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = scenario
        app.launchArguments = [
            "-linguacast-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-linguacast-ui-scenario", scenario
        ]
        app.launch()
        return app
    }

    private func segment(named title: String, in app: XCUIApplication) -> XCUIElement {
        let segmented = app.segmentedControls["podcast.playback-category"]
        if segmented.exists {
            let button = segmented.buttons[title]
            if button.exists { return button }
        }
        return app.buttons[title]
    }

    #if os(tvOS)
    private func selectSegment(named title: String, in app: XCUIApplication) {
        let target = segment(named: title, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        focusAndSelect(target)
    }

    private func focusAndSelect(_ element: XCUIElement) {
        for _ in 0..<12 where !element.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        for _ in 0..<8 where !element.hasFocus {
            XCUIRemote.shared.press(.right)
        }
        for _ in 0..<8 where !element.hasFocus {
            XCUIRemote.shared.press(.left)
        }
        XCTAssertTrue(element.hasFocus, "Expected focus on \(element.identifier.isEmpty ? element.label : element.identifier)")
        XCUIRemote.shared.press(.select)
    }
    #endif
}
