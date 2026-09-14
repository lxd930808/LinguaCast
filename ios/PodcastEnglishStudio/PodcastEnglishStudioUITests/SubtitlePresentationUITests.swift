import XCTest

/// V7 bilingual subtitle presentation: Settings controls, fixture seeding, and player order.
final class SubtitlePresentationUITests: XCTestCase {
    private let englishCue = "A deterministic English subtitle."
    private let chineseCue = "确定性的双语字幕。"
    private let previewEnglish = "Hello, welcome to today's lesson."
    private let previewChinese = "你好，欢迎收听今天的课程。"
    private let targetFirstLabel = "简体中文 first"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsShowsSubtitleControlsAndPreview() throws {
        #if os(tvOS)
        throw XCTSkip("Detailed Settings control scrolling is covered by testTVOSSettingsControlsAndPodcastFixtureOrder")
        #else
        let app = launch(scenario: "tabs", tab: "settings")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 8))

        scrollUntilExists(app.descendants(matching: .any)["settings.subtitle.english-size"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.subtitle.english-size"].exists)
        scrollUntilExists(app.descendants(matching: .any)["settings.subtitle.target-scale"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.subtitle.target-scale"].exists)
        scrollUntilExists(app.descendants(matching: .any)["settings.subtitle.order"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.subtitle.order"].exists)

        scrollUntilExists(app.staticTexts[previewEnglish], in: app)
        let english = app.staticTexts[previewEnglish]
        let chinese = app.staticTexts[previewChinese]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            english.frame.minY,
            chinese.frame.minY,
            "Default englishFirst preview should place English above Chinese"
        )

        app.terminate()
        #endif
    }

    func testIOSSettingsSaveUpdatesPodcastSubtitleOrder() throws {
        #if os(tvOS)
        throw XCTSkip("iOS Save → podcast player path")
        #else
        let app = launch(scenario: "podcast-ready")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForPodcastReady(app)

        let segment = app.descendants(matching: .any)["transcript.segment.1"]
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        assertTextOrder(in: segment.label, first: englishCue, second: chineseCue)

        let openSettings = app.buttons["uitest.open-settings"]
        XCTAssertTrue(openSettings.waitForExistence(timeout: 8))
        openSettings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 8))

        scrollUntilExists(app.descendants(matching: .any)["settings.subtitle.order"], in: app)
        let targetFirst = app.buttons[targetFirstLabel]
        XCTAssertTrue(targetFirst.waitForExistence(timeout: 5), "Missing order segment: \(targetFirstLabel)")
        targetFirst.tap()

        scrollUntilExists(app.staticTexts[previewChinese], in: app)
        let previewZH = app.staticTexts[previewChinese]
        let previewEN = app.staticTexts[previewEnglish]
        XCTAssertTrue(previewZH.waitForExistence(timeout: 5))
        XCTAssertTrue(previewEN.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            previewZH.frame.minY,
            previewEN.frame.minY,
            "Settings draft preview should flip to target-first"
        )

        let save = app.navigationBars.buttons["Save"].exists
            ? app.navigationBars.buttons["Save"]
            : app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        Thread.sleep(forTimeInterval: 0.4)

        // Prefer an explicit dismiss over an ambiguous swipe that can hit player chrome.
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap()
        } else {
            app.swipeDown()
        }

        XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
        let updatedSegment = app.descendants(matching: .any)["transcript.segment.1"]
        XCTAssertTrue(updatedSegment.waitForExistence(timeout: 5))

        let deadline = Date().addingTimeInterval(6)
        var flipped = false
        while Date() < deadline {
            if let en = updatedSegment.label.range(of: englishCue),
               let zh = updatedSegment.label.range(of: chineseCue),
               zh.lowerBound < en.lowerBound {
                flipped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(flipped, "Saved targetFirst order did not reach podcast transcript: \(updatedSegment.label)")

        app.terminate()
        #endif
    }

    func testPodcastFixtureOrderAndTranslationToggle() throws {
        let app = launch(
            scenario: "podcast-ready",
            subtitleOrder: "targetFirst",
            subtitleLevel: "7",
            subtitleScale: "50"
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForPodcastReady(app)

        let segment = app.descendants(matching: .any)["transcript.segment.1"]
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        assertTextOrder(in: segment.label, first: chineseCue, second: englishCue)
        XCTAssertTrue(app.staticTexts[chineseCue].waitForExistence(timeout: 5))

        let translationToggle = app.buttons["transcript.translation-toggle"]
        XCTAssertTrue(translationToggle.waitForExistence(timeout: 5))

        #if !os(tvOS)
        // Assert via the toggle's own accessibility label — more stable than hunting
        // static texts that can remain in off-screen lazy rows.
        XCTAssertTrue(
            translationToggle.label.localizedCaseInsensitiveContains("Hide")
                || translationToggle.label.localizedCaseInsensitiveContains("Bilingual")
                || translationToggle.label.contains("隐藏")
                || translationToggle.label.contains("双语")
        )
        translationToggle.tap()
        let deadline = Date().addingTimeInterval(5)
        var toggled = false
        while Date() < deadline {
            let label = translationToggle.label
            if label.localizedCaseInsensitiveContains("Show")
                || label.localizedCaseInsensitiveContains("English Only")
                || label.contains("显示")
                || label.contains("仅英语") {
                toggled = true
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(toggled, "Translation toggle did not flip accessibility label: \(translationToggle.label)")
        let updated = app.descendants(matching: .any)["transcript.segment.1"]
        XCTAssertTrue(updated.waitForExistence(timeout: 3))
        XCTAssertFalse(
            updated.label.contains(chineseCue),
            "English-only mode should drop translation from the active segment a11y label"
        )
        #endif

        app.terminate()
    }

    func testYouTubeFixtureRespectsLaunchSubtitleOrderSeed() throws {
        let app = launch(
            scenario: "youtube-ready",
            subtitleOrder: "targetFirst",
            subtitleLevel: "5",
            subtitleScale: "60",
            subtitleDisplayMode: "englishOnly"
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["screen.youtube-player"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[englishCue].waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.staticTexts[chineseCue].exists,
            "englishOnly fixture must hide the translation cue"
        )
        XCTAssertTrue(app.buttons["uitest.open-settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["uitest.apply-subtitle-update"].exists)
        app.terminate()
    }

    func testApplyAfterEnvFlipsPodcastOrderWhilePlaying() throws {
        #if os(tvOS)
        throw XCTSkip("iOS apply-after mid-session update path")
        #else
        let app = launch(
            scenario: "podcast-ready",
            subtitleOrder: "englishFirst",
            subtitleOrderAfter: "targetFirst",
            subtitleLevelAfter: "8",
            subtitleScaleAfter: "55"
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForPodcastReady(app)

        let segment = app.descendants(matching: .any)["transcript.segment.1"]
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        assertTextOrder(in: segment.label, first: englishCue, second: chineseCue)

        let apply = app.buttons["uitest.apply-subtitle-update"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()

        let deadline = Date().addingTimeInterval(6)
        var flipped = false
        while Date() < deadline {
            let label = app.descendants(matching: .any)["transcript.segment.1"].label
            if let en = label.range(of: englishCue),
               let zh = label.range(of: chineseCue),
               zh.lowerBound < en.lowerBound {
                flipped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(flipped, "Apply-after env did not flip transcript order")
        app.terminate()
        #endif
    }

    func testTVOSSettingsControlsAndPodcastFixtureOrder() throws {
        #if !os(tvOS)
        throw XCTSkip("tvOS subtitle presentation path")
        #else
        let settings = launch(
            scenario: "tabs",
            tab: "settings",
            subtitleOrder: "targetFirst",
            subtitleLevel: "6",
            subtitleScale: "80"
        )
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(settings.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 8))
        #if os(tvOS)
        let subtitlesRow = settings.descendants(matching: .any)["settings.row.subtitles"]
        if !subtitlesRow.exists {
            for _ in 0..<10 { XCUIRemote.shared.press(.down) }
        }
        XCTAssertTrue(subtitlesRow.waitForExistence(timeout: 5))
        for _ in 0..<10 where !subtitlesRow.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.select)
        #endif
        let englishSize = settings.descendants(matching: .any)["settings.subtitle.english-size"]
        if !englishSize.exists {
            for _ in 0..<8 { XCUIRemote.shared.press(.down) }
        }
        XCTAssertTrue(
            englishSize.waitForExistence(timeout: 3)
                || settings.descendants(matching: .any)["settings.subtitle.order"].exists
                || settings.descendants(matching: .any)["settings.subtitle.preview"].exists
                || settings.staticTexts[previewEnglish].exists,
            "Expected at least one subtitle settings control on tvOS Settings"
        )
        settings.terminate()

        let podcast = launch(
            scenario: "podcast-ready",
            subtitleOrder: "targetFirst",
            subtitleLevel: "6",
            subtitleScale: "80"
        )
        XCTAssertTrue(podcast.wait(for: .runningForeground, timeout: 10))
        waitForPodcastReady(podcast)
        let segment = podcast.descendants(matching: .any)["transcript.segment.1"]
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        assertTextOrder(in: segment.label, first: chineseCue, second: englishCue)
        XCTAssertTrue(podcast.staticTexts[chineseCue].waitForExistence(timeout: 5))
        XCTAssertTrue(podcast.staticTexts[englishCue].exists)
        podcast.terminate()
        #endif
    }

    // MARK: - Helpers

    private func launch(
        scenario: String,
        tab: String = "home",
        subtitleOrder: String? = nil,
        subtitleLevel: String? = nil,
        subtitleScale: String? = nil,
        subtitleDisplayMode: String? = nil,
        subtitleOrderAfter: String? = nil,
        subtitleLevelAfter: String? = nil,
        subtitleScaleAfter: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = scenario
        app.launchEnvironment["LINGUACAST_UI_TAB"] = tab
        if let subtitleOrder {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_ORDER"] = subtitleOrder
        }
        if let subtitleLevel {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_LEVEL"] = subtitleLevel
        }
        if let subtitleScale {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_SCALE"] = subtitleScale
        }
        if let subtitleDisplayMode {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_DISPLAY_MODE"] = subtitleDisplayMode
        }
        if let subtitleOrderAfter {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_ORDER_AFTER"] = subtitleOrderAfter
        }
        if let subtitleLevelAfter {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_LEVEL_AFTER"] = subtitleLevelAfter
        }
        if let subtitleScaleAfter {
            app.launchEnvironment["LINGUACAST_UI_SUBTITLE_SCALE_AFTER"] = subtitleScaleAfter
        }
        app.launchArguments = [
            "-linguacast-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-linguacast-ui-tab", tab,
            "-linguacast-ui-scenario", scenario
        ]
        app.launch()
        return app
    }

    private func waitForPodcastReady(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["subtitle.ready-state"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["media.playback-controls"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[englishCue].waitForExistence(timeout: 8))
    }

    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 16) {
        #if os(tvOS)
        for _ in 0..<maxSwipes where !element.exists {
            XCUIRemote.shared.press(.down)
        }
        #else
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
        #endif
        XCTAssertTrue(element.waitForExistence(timeout: 3), "Element not found after scrolling")
    }

    private func assertTextOrder(
        in haystack: String,
        first: String,
        second: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstRange = haystack.range(of: first),
              let secondRange = haystack.range(of: second)
        else {
            return XCTFail("Missing expected texts in accessibility string: \(haystack)", file: file, line: line)
        }
        XCTAssertLessThan(
            firstRange.lowerBound,
            secondRange.lowerBound,
            "Expected “\(first)” before “\(second)” in: \(haystack)",
            file: file,
            line: line
        )
    }
}
