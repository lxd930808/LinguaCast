import XCTest

final class LocalizationSmokeUITests: XCTestCase {
    private let languages: [(tag: String, locale: String, homeTitle: String)] = [
        ("en", "en_US", "Home"), ("zh-Hans", "zh_CN", "首页"), ("zh-Hant", "zh_TW", "首頁"),
        ("es", "es_ES", "pagina de inicio"), ("pt-BR", "pt_BR", "Página inicial"), ("ja", "ja_JP", "ホームページ"),
        ("ko", "ko_KR", "홈페이지"), ("fr", "fr_FR", "Page d'accueil"), ("de", "de_DE", "Startseite"),
        ("ar", "ar_SA", "الصفحة الرئيسية")
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTenLanguageCoreScreenMatrix() throws {
        for language in languages {
            #if os(tvOS)
            for tab in ["home", "programs", "subscriptions", "settings"] {
                let app = launch(language: language, tab: tab)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                waitForScreenAndFixtures(app, tab: tab)
                if tab == "home" {
                    assertLocalizedHomeAndDirection(app, language: language)
                }
                capture(app, language: language.tag, screen: tab)
                app.terminate()
            }
            #else
            let app = launch(language: language)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            waitForScreenAndFixtures(app, tab: "home")
            assertLocalizedHomeAndDirection(app, language: language)
            capture(app, language: language.tag, screen: "home")
            captureTab("tab.programs", app: app, language: language.tag, screen: "programs")
            captureTab("tab.subscriptions", app: app, language: language.tag, screen: "subscriptions")
            captureTab("tab.settings", app: app, language: language.tag, screen: "settings")
            app.terminate()
            #endif
        }
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        let app = launch(language: ("ru", "ru_RU", "Home"))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScreenAndFixtures(app, tab: "home")
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testCoreScreenAppearanceMatrix() {
        let language = languages[0]
        for (appearance, expectedValue) in [("Light", "light"), ("Dark", "dark")] {
            #if os(tvOS)
            for tab in ["home", "programs", "subscriptions", "settings"] {
                let app = launch(language: language, tab: tab, appearance: appearance)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                waitForScreenAndFixtures(app, tab: tab)
                assertAppearance(app, expectedValue: expectedValue)
                capture(app, language: "en", screen: "\(tab)-\(expectedValue)")
                app.terminate()
            }
            #else
            let app = launch(language: language, appearance: appearance)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            waitForScreenAndFixtures(app, tab: "home")
            assertAppearance(app, expectedValue: expectedValue)
            capture(app, language: "en", screen: "home-\(expectedValue)")
            captureTab("tab.programs", app: app, language: "en", screen: "programs-\(expectedValue)")
            captureTab("tab.subscriptions", app: app, language: "en", screen: "subscriptions-\(expectedValue)")
            captureTab("tab.settings", app: app, language: "en", screen: "settings-\(expectedValue)")
            app.terminate()
            #endif

            #if !os(tvOS)
            let addSubscription = launch(
                language: language,
                tab: "subscriptions",
                appearance: appearance
            )
            XCTAssertTrue(addSubscription.wait(for: .runningForeground, timeout: 10))
            waitForScreenAndFixtures(addSubscription, tab: "subscriptions")
            let add = addSubscription.buttons["subscriptions.add"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            XCTAssertTrue(
                addSubscription.descendants(matching: .any)["screen.add-subscription"]
                    .waitForExistence(timeout: 8)
            )
            assertAppearance(addSubscription, expectedValue: expectedValue)
            capture(
                addSubscription,
                language: "en",
                screen: "add-subscription-\(expectedValue)"
            )
            addSubscription.terminate()
            #endif

            for scenario in [
                "podcast-queued", "podcast-failed", "podcast-ready",
                "podcast-follow", "youtube-channel", "mobile-setup"
            ] {
                let app = launch(language: language, scenario: scenario, appearance: appearance)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                waitForScenario(app, scenario: scenario)
                assertAppearance(app, expectedValue: expectedValue)
                capture(app, language: "en", screen: "\(scenario)-\(expectedValue)")
                app.terminate()
            }
        }
    }

    func testYouTubePlayerLightAppearance() {
        assertYouTubePlayerAppearance("Light", expectedValue: "light")
    }

    func testYouTubePlayerDarkAppearance() {
        assertYouTubePlayerAppearance("Dark", expectedValue: "dark")
    }

    func testArabicMaximumDynamicTypeVisualRegression() {
        guard let arabic = languages.first(where: { $0.tag == "ar" }) else {
            return XCTFail("Missing Arabic test locale")
        }

        let settings = launch(language: arabic, maximumDynamicType: true, tab: "settings")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        waitForScreenAndFixtures(settings, tab: "settings")
        capture(settings, language: arabic.tag, screen: "settings-accessibility-xxxl")
        settings.terminate()

        let podcast = launch(language: arabic, maximumDynamicType: true, scenario: "podcast-ready")
        XCTAssertTrue(podcast.wait(for: .runningForeground, timeout: 10))
        waitForScenario(podcast, scenario: "podcast-ready")
        capture(podcast, language: arabic.tag, screen: "podcast-ready-accessibility-xxxl")
        podcast.terminate()
    }

    func testTenLanguageMaximumDynamicTypeMatrix() throws {
        for language in languages {
            #if os(tvOS)
            for tab in ["home", "subscriptions", "settings"] {
                let app = launch(language: language, maximumDynamicType: true, tab: tab)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                waitForScreenAndFixtures(app, tab: tab)
                capture(app, language: language.tag, screen: "\(tab)-accessibility-xxxl")
                app.terminate()
            }
            #else
            let app = launch(language: language, maximumDynamicType: true)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            waitForScreenAndFixtures(app, tab: "home")
            capture(app, language: language.tag, screen: "home-accessibility-xxxl")
            captureTab("tab.subscriptions", app: app, language: language.tag, screen: "subscriptions-accessibility-xxxl")
            captureTab("tab.settings", app: app, language: language.tag, screen: "settings-accessibility-xxxl")
            app.terminate()
            #endif

            for scenario in ["podcast-ready", "youtube-ready", "mobile-setup"] {
                let app = launch(language: language, maximumDynamicType: true, scenario: scenario)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                waitForScenario(app, scenario: scenario)
                capture(app, language: language.tag, screen: "\(scenario)-accessibility-xxxl")
                app.terminate()
            }
        }
    }

    func testTenLanguageFixtureStateMatrix() {
        for language in languages {
            for scenario in fixtureScenarios {
                let app = launch(language: language, scenario: scenario)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                waitForScenario(app, scenario: scenario)
                capture(app, language: language.tag, screen: scenario)
                app.terminate()
            }
        }
    }

    func testFixtureScenarioHarnessInEnglish() {
        let language = languages[0]
        for scenario in fixtureScenarios {
            let app = launch(language: language, scenario: scenario)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            waitForScenario(app, scenario: scenario)
            app.terminate()
        }
    }

    func testSubscriptionSetupUsesThePlatformAppropriateEntryPoint() {
        let app = launch(language: languages[0], tab: "subscriptions")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScreenAndFixtures(app, tab: "subscriptions")

        #if os(tvOS)
        let setup = app.buttons["subscriptions.mobile-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        for _ in 0..<8 where !setup.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(setup.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["screen.mobile-setup"].waitForExistence(timeout: 8))
        #else
        let add = app.buttons["subscriptions.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.add-subscription"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        #endif

        app.terminate()
    }

    func testPodcastCompletionTransitionsFromProcessingToPlayerInSameProcess() {
        #if !os(tvOS)
        // Opens the play page while the episode is still persisted as `running /
        // build_learning_pack` (the orphaned-completion bug), with a complete and valid
        // translation already on disk. Without terminating or relaunching, the page must
        // reconcile and switch itself from the progress state to the bilingual player.
        let app = launch(language: languages[0], scenario: "podcast-completion-transition")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let player = app.descendants(matching: .any)["screen.podcast-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 8))

        // The same process then recovers to the ready state: subtitles + playback controls.
        XCTAssertTrue(app.descendants(matching: .any)["subtitle.ready-state"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["media.playback-controls"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["确定性的双语字幕。"].waitForExistence(timeout: 8))
        // The processing/progress UI must be gone once ready.
        XCTAssertTrue(app.descendants(matching: .any)["podcast.processing-progress"].waitForNonExistence(timeout: 5))
        app.terminate()
        #endif
    }

    func testPodcastReaderUsesReadingOnlyControlsAndTogglesTranslation() {
        let app = launch(language: languages[0], scenario: "podcast-ready")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "podcast-ready")

        XCTAssertFalse(app.buttons["Listen carefully"].exists)
        XCTAssertFalse(app.buttons["read"].exists)
        for identifier in ["player.progress", "player.skip-back", "player.play-pause", "player.skip-forward"] {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5), identifier)
        }

        let translation = app.staticTexts["确定性的双语字幕。"]
        XCTAssertTrue(translation.waitForExistence(timeout: 5))
        let translationToggle = app.buttons["transcript.translation-toggle"]
        XCTAssertTrue(translationToggle.waitForExistence(timeout: 5))
        #if !os(tvOS)
        translationToggle.tap()
        XCTAssertTrue(translation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].exists)
        #endif
        app.terminate()
    }

    func testIOSPodcastProgressScrubbingKeepsTheActiveSubtitleVisible() {
        #if !os(tvOS)
        let app = launch(language: languages[0], scenario: "podcast-follow")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "podcast-follow")

        let progress = app.sliders["player.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        progress.adjust(toNormalizedSliderPosition: 0.85)
        progress.adjust(toNormalizedSliderPosition: 0.10)
        progress.adjust(toNormalizedSliderPosition: 0.65)

        XCTAssertTrue(app.staticTexts["0:13"].waitForExistence(timeout: 5))
        let activeSubtitle = app.descendants(matching: .any)["transcript.segment.14"]
        XCTAssertTrue(activeSubtitle.waitForExistence(timeout: 5))
        XCTAssertTrue(activeSubtitle.isHittable, "The active subtitle must finish in the visible transcript area")

        let playPause = app.buttons["player.play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.tap()
        for second in 1...5 {
            Thread.sleep(forTimeInterval: 1)
            let currentSubtitle = app.descendants(matching: .any)
                .matching(NSPredicate(format: "value == %@", "active"))
                .firstMatch
            XCTAssertTrue(currentSubtitle.exists, "Missing highlighted subtitle after \(second) seconds")
            XCTAssertTrue(currentSubtitle.isHittable, "Highlighted subtitle left the visible area after \(second) seconds")
        }
        app.terminate()
        #endif
    }

    func testTVPodcastQueuedUsesActionShelfAndHidesUnavailableSubtitleControls() {
        #if os(tvOS)
        let app = launch(language: languages[0], scenario: "podcast-queued")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "podcast-queued")

        XCTAssertTrue(app.descendants(matching: .any)["podcast.action-shelf"].waitForExistence(timeout: 5))
        let start = app.descendants(matching: .any)["podcast.start-processing"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.hasFocus)
        XCTAssertFalse(app.descendants(matching: .any)["transcript.translation-toggle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["media.playback-controls"].exists)
        capture(app, language: "en", screen: "podcast-queued-action-shelf")
        app.terminate()
        #endif
    }

    func testIOSPodcastQueuedLongDetailsCanExpandCollapseAndScrollToAction() {
        #if !os(tvOS)
        let app = launch(language: languages[0], scenario: "podcast-queued")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "podcast-queued")

        let summaryToggle = app.buttons["podcast.episode-summary-toggle"]
        XCTAssertTrue(summaryToggle.waitForExistence(timeout: 5))
        let episodeWebsiteLink = app.descendants(matching: .any)["podcast.episode-website-link"]
        XCTAssertTrue(episodeWebsiteLink.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(summaryToggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(summaryToggle.frame.height, 44,
            "The V17 text disclosure must retain an accessible tap target")
        XCTAssertGreaterThan(
            episodeWebsiteLink.frame.minY - summaryToggle.frame.maxY,
            12,
            "The in-page disclosure and external website actions need a safe vertical separation"
        )
        summaryToggle.tap()
        XCTAssertEqual(summaryToggle.value as? String, "expanded")

        let start = app.buttons["podcast.start-processing"]
        for _ in 0..<8 where !start.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(start.isHittable, "The long pending-episode details must scroll to the processing action")

        for _ in 0..<8 where !summaryToggle.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(summaryToggle.isHittable)
        summaryToggle.tap()
        XCTAssertEqual(summaryToggle.value as? String, "collapsed")
        app.terminate()
        #endif
    }

    func testTVPodcastActionShelfHandlesMissingRunningAndFailedStates() {
        #if os(tvOS)
        let missing = launch(language: languages[0], scenario: "podcast-queued-missing-configuration")
        XCTAssertTrue(missing.wait(for: .runningForeground, timeout: 10))
        waitForScenario(missing, scenario: "podcast-queued-missing-configuration")
        let cloudCheckStart = missing.descendants(matching: .any)["podcast.start-processing"]
        XCTAssertTrue(cloudCheckStart.waitForExistence(timeout: 5))
        XCTAssertTrue(cloudCheckStart.hasFocus)
        XCTAssertFalse(missing.descendants(matching: .any)["podcast.open-settings"].exists)
        missing.terminate()

        let running = launch(language: languages[0], scenario: "podcast-running")
        XCTAssertTrue(running.wait(for: .runningForeground, timeout: 10))
        waitForScenario(running, scenario: "podcast-running")
        capture(running, language: "en", screen: "V17-tv-running-diagnostic")
        print("V17 running hierarchy: \(running.debugDescription)")
        XCTAssertTrue(running.descendants(matching: .any)["podcast.processing-progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(running.descendants(matching: .any)["podcast.processing-background-note"].waitForExistence(timeout: 5))
        XCTAssertFalse(running.descendants(matching: .any)["podcast.start-processing"].exists)
        running.terminate()

        let failed = launch(language: languages[0], scenario: "podcast-failed")
        XCTAssertTrue(failed.wait(for: .runningForeground, timeout: 10))
        waitForScenario(failed, scenario: "podcast-failed")
        let retry = failed.descendants(matching: .any)["subtitle.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.hasFocus)
        XCTAssertTrue(failed.descendants(matching: .any)["podcast.open-settings"].exists)
        XCTAssertFalse(failed.descendants(matching: .any)["transcript.translation-toggle"].exists)
        failed.terminate()
        #endif
    }

    func testPodcastCloudCheckFailureOffersRetryAndExplicitPaidBypass() {
        let app = launch(language: languages[0], scenario: "podcast-cloud-check-required")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "podcast-cloud-check-required")

        XCTAssertTrue(app.descendants(matching: .any)["subtitle.cloud-retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["subtitle.cloud-bypass"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["podcast.open-settings"].exists)
        app.terminate()
    }

    func testLargePodcastListOnlyMaterializesVisibleRows() {
        let app = launch(language: languages[0], scenario: "podcast-large-list")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitForScenario(app, scenario: "podcast-large-list")

        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "podcast.episode.")
        )
        XCTAssertLessThan(rows.count, 80, "The large podcast list eagerly materialized off-screen rows")
        app.terminate()
    }

    func testTVPodcastPlaybackControlsAreReachableBeforeTranscriptRows() {
        #if os(tvOS)
        let app = launch(language: languages[0], scenario: "podcast-follow")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "podcast-follow")

        let transportControls = [
            app.buttons["player.skip-back"],
            app.buttons["player.play-pause"],
            app.buttons["player.skip-forward"]
        ]
        for _ in 0..<4 where !transportControls.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(
            transportControls.contains(where: \.hasFocus),
            "Playback controls must be reachable without traversing subtitle sentences"
        )
        app.terminate()
        #endif
    }

    func testTVPodcastTranscriptContinuesFollowingAfterNonBrowsingRemoteMove() {
        #if os(tvOS)
        let app = launch(language: languages[0], scenario: "podcast-follow")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "podcast-follow")

        let firstSegment = app.descendants(matching: .any)["transcript.segment.1"]
        XCTAssertTrue(firstSegment.waitForExistence(timeout: 5))
        XCTAssertTrue(firstSegment.isHittable)
        let laterSegment = app.descendants(matching: .any)["transcript.segment.15"]
        XCTAssertFalse(laterSegment.exists)
        let play = app.buttons["player.play-pause"]
        XCTAssertTrue(app.moveRemoteFocus(to: play))
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.buttons["player.skip-forward"].hasFocus,
            "A move within playback controls must not enter transcript browsing")

        XCTAssertTrue(laterSegment.waitForExistence(timeout: 18))
        XCTAssertTrue(laterSegment.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["player.locate-playback"].exists)
        app.terminate()
        #endif
    }

    private var fixtureScenarios: [String] {
        [
            "first-launch", "podcast-ready", "podcast-failed", "youtube-ready",
            "youtube-partial", "youtube-failed", "mobile-setup"
        ]
    }

    private func launch(
        language: (tag: String, locale: String, homeTitle: String),
        maximumDynamicType: Bool = false,
        tab: String = "home",
        scenario: String = "tabs",
        appearance: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = scenario
        app.launchEnvironment["LINGUACAST_UI_TAB"] = tab
        if let appearance {
            app.launchEnvironment["LINGUACAST_UI_COLOR_SCHEME"] = appearance.lowercased()
        }
        app.launchArguments = [
            "-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome",
            "-AppleLanguages", "(\(language.tag))",
            "-AppleLocale", language.locale,
            "-linguacast-ui-tab", tab,
            "-linguacast-ui-scenario", scenario
        ]
        if maximumDynamicType {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
            ]
        }
        app.launch()
        return app
    }

    private func waitForScenario(_ app: XCUIApplication, scenario: String) {
        switch scenario {
        case "first-launch":
            XCTAssertTrue(app.descendants(matching: .any)["screen.home"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.descendants(matching: .any)["home.empty-continue"].waitForExistence(timeout: 8))
            XCTAssertFalse(app.staticTexts["The Daily Language Lab"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["setup.configuration"].waitForExistence(timeout: 5))
        case "podcast-ready":
            XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.descendants(matching: .any)["subtitle.ready-state"].waitForExistence(timeout: 8))
            #if !os(tvOS)
            let original = app.buttons["player.mode-original"]
            XCTAssertTrue(original.waitForExistence(timeout: 8))
            original.tap()
            #endif
            XCTAssertTrue(app.descendants(matching: .any)["media.playback-controls"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["A deterministic English subtitle."].waitForExistence(timeout: 8))
        case "podcast-follow":
            XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.descendants(matching: .any)["subtitle.ready-state"].waitForExistence(timeout: 8))
            #if !os(tvOS)
            let original = app.buttons["player.mode-original"]
            XCTAssertTrue(original.waitForExistence(timeout: 8))
            original.tap()
            #endif
            XCTAssertTrue(app.descendants(matching: .any)["media.playback-controls"].waitForExistence(timeout: 8))
            // The long metadata header can keep the first lazy row offscreen.
            // The scrubbing test verifies the destination row and active-cue visibility.
        case "podcast-queued":
            XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
        case "podcast-queued-missing-configuration", "podcast-running":
            XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
        case "podcast-failed":
            XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.descendants(matching: .any)["subtitle.error-state"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["subtitle.retry"].waitForExistence(timeout: 8))
        case "podcast-cloud-check-required":
            XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.descendants(matching: .any)["subtitle.cloud-retry"].waitForExistence(timeout: 8))
        case "podcast-large-list":
            XCTAssertTrue(app.descendants(matching: .any)["podcast.episode.ui-large-episode-1"].waitForExistence(timeout: 15))
        case "youtube-ready", "youtube-partial", "youtube-failed":
            #if os(tvOS)
            XCTAssertTrue(
                app.staticTexts["A deterministic English subtitle."]
                    .waitForExistence(timeout: 15)
            )
            #else
            XCTAssertTrue(app.descendants(matching: .any)["player.surface"].waitForExistence(timeout: 15))
            #endif
        case "youtube-channel":
            XCTAssertTrue(
                app.descendants(matching: .any)["screen.youtube-channel"]
                    .waitForExistence(timeout: 8)
            )
            XCTAssertTrue(app.staticTexts["LinguaCast Video Lab"].waitForExistence(timeout: 8))
        case "mobile-setup":
            XCTAssertTrue(app.descendants(matching: .any)["screen.mobile-setup"].waitForExistence(timeout: 8))
        default:
            XCTFail("Unknown fixture scenario: \(scenario)")
        }
    }

    private func assertAppearance(_ app: XCUIApplication, expectedValue: String) {
        let appearanceProbe = app.descendants(matching: .any)["theme.appearance"]
        XCTAssertTrue(appearanceProbe.waitForExistence(timeout: 5))
        XCTAssertEqual(appearanceProbe.value as? String, expectedValue)
    }

    private func assertYouTubePlayerAppearance(_ appearance: String, expectedValue: String) {
        let app = launch(
            language: languages[0],
            scenario: "youtube-ready",
            appearance: appearance
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForScenario(app, scenario: "youtube-ready")
        assertAppearance(app, expectedValue: expectedValue)
        capture(app, language: "en", screen: "youtube-ready-\(expectedValue)")

        #if !os(tvOS)
        let settings = app.buttons["player.settings.navigation"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.settings.video-panel"].waitForExistence(timeout: 5))
        capture(app, language: "en", screen: "youtube-settings-\(expectedValue)")
        #endif
        app.terminate()
    }

    private func waitForScreenAndFixtures(_ app: XCUIApplication, tab: String) {
        let screen = app.descendants(matching: .any)["screen.\(tab)"]
        XCTAssertTrue(screen.waitForExistence(timeout: 8), "Missing screen anchor: screen.\(tab)")
        guard tab != "settings" else { return }
        XCTAssertTrue(
            app.staticTexts["The Daily Language Lab"].waitForExistence(timeout: 8),
            "Fixture content did not appear on \(tab)"
        )
        if tab == "home" {
            let mediaProgress = app.descendants(matching: .any)["media.playback-progress"].firstMatch
            XCTAssertTrue(mediaProgress.waitForExistence(timeout: 5), "Missing LTR media progress anchor")
            XCTAssertEqual(mediaProgress.value as? String, "ltr")
        }
    }

    private func assertLocalizedHomeAndDirection(
        _ app: XCUIApplication,
        language: (tag: String, locale: String, homeTitle: String)
    ) {
        XCTAssertTrue(
            app.staticTexts[language.homeTitle].waitForExistence(timeout: 5),
            "Home title did not use \(language.tag)"
        )
        let home = tabButton("tab.home", in: app)
        let settings = tabButton("tab.settings", in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        if language.tag == "ar" {
            XCTAssertGreaterThan(home.frame.midX, settings.frame.midX, "Arabic tab layout did not mirror")
        } else {
            XCTAssertLessThan(home.frame.midX, settings.frame.midX, "LTR tab layout unexpectedly mirrored")
        }
    }

    private func captureTab(
        _ identifier: String,
        app: XCUIApplication,
        language: String,
        screen: String
    ) {
        #if os(tvOS)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        capture(app, language: language, screen: screen)
        #else
        let control = tabButton(identifier, in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing tab control: \(identifier)")
        control.tap()
        waitForScreenAndFixtures(app, tab: identifier.replacingOccurrences(of: "tab.", with: ""))
        capture(app, language: language, screen: screen)
        #endif
    }

    private func tabButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.tabBars.buttons.matching(identifier: identifier).firstMatch
        if identified.exists { return identified }
        let index: Int
        switch identifier {
        case "tab.programs": index = 1
        case "tab.subscriptions": index = 2
        case "tab.settings":
            #if os(tvOS)
            index = 3
            #else
            index = 4
            #endif
        default: index = 0
        }
        return app.tabBars.firstMatch.buttons.element(boundBy: index)
    }

    private func capture(_ app: XCUIApplication, language: String, screen: String) {
        #if os(tvOS)
        let platform = "tvOS"
        #else
        let platform = "iOS"
        #endif
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(platform)-\(language)-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let root = URL(fileURLWithPath: "/private/tmp/LinguaCastLocalizationSmoke", isDirectory: true)
        let destination = root
            .appendingPathComponent(platform, isDirectory: true)
            .appendingPathComponent(language, isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true))
        XCTAssertNoThrow(try screenshot.pngRepresentation.write(to: destination.appendingPathComponent("\(screen).png")))
    }
}
