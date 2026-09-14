import XCTest

final class ChinesePlaybackUITests: XCTestCase {
    func testChineseSentenceFollowDeepInVariableHeightTranscript() throws {
        #if os(tvOS)
        throw XCTSkip("Chinese playback is iOS-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = "podcast-follow"
        app.launchEnvironment["LINGUACAST_UI_VARIABLE_TRANSCRIPT"] = "1"
        app.launchEnvironment["LINGUACAST_UI_REPLAY_CHINESE_SENTENCES"] = "1"
        app.launchArguments = ["-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-linguacast-ui-scenario", "podcast-follow"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["subtitle.ready-state"].waitForExistence(timeout: 20))
        for sequence in 773...777 {
            let row = app.descendants(matching: .any)["transcript.segment.\(sequence)"].firstMatch
            expectation(for: NSPredicate(format: "value == %@", "active"), evaluatedWith: row)
            waitForExpectations(timeout: 10)
            // A cue can exist in a lazy stack's accessibility tree while the viewport is
            // dozens of rows behind it. Check its actual screen position after layout.
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertTrue(row.isHittable, "Sentence \(sequence) is active but the viewport jumped elsewhere")
            let anchoredY = row.frame.minY
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.3)
                guard row.value as? String == "active" else { break }
                XCTAssertEqual(row.frame.minY, anchoredY, accuracy: 2,
                               "Progress refresh moved the current sentence toward an earlier row")
            }
        }
        #endif
    }

    func testChinesePreparationStaysPausedAndCanReturnToOriginal() throws {
        #if os(tvOS)
        throw XCTSkip("Chinese playback is iOS-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = "podcast-follow"
        app.launchArguments = ["-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-linguacast-ui-scenario", "podcast-follow"]
        app.launch()
        let chinese = app.buttons["player.mode-chinese"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 20))
        // A restored checkpoint may select Chinese on a repeated test run.
        if chinese.isSelected { app.buttons["player.mode-original"].tap() }
        XCTAssertFalse(app.buttons["player.rhythm-natural"].exists)
        app.buttons["player.settings.podcast"].tap()
        let natural = app.buttons["player.rhythm-natural"]
        XCTAssertTrue(natural.exists, "Rhythm must be available in playback settings")
        XCTAssertTrue(natural.isEnabled)
        natural.tap()
        XCTAssertTrue(natural.isSelected)
        XCTAssertTrue(natural.isEnabled, "Selected rhythm remains operable, with a selection marker")
        app.buttons["player.settings.close"].tap()
        let control = app.buttons["player.chinese-play-pause"]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "value == %@", "paused")
        expectation(for: ready, evaluatedWith: control)
        waitForExpectations(timeout: 180)
        app.buttons["player.settings.podcast"].tap()
        let current = app.buttons["player.rhythm-current"]
        XCTAssertTrue(natural.exists)
        current.tap()
        XCTAssertTrue(current.isSelected)
        natural.tap()
        XCTAssertTrue(natural.isSelected)
        XCTAssertTrue(app.buttons["player.prepare-chinese"].exists)
        app.buttons["player.settings.close"].tap()
        expectation(for: ready, evaluatedWith: control)
        waitForExpectations(timeout: 180)
        XCTAssertEqual(control.value as? String, "paused")
        control.tap()
        expectation(for: NSPredicate(format: "value == %@", "playing"), evaluatedWith: control)
        waitForExpectations(timeout: 10)
        control.tap()
        XCTAssertEqual(control.value as? String, "paused")
        app.buttons["player.mode-original"].tap()
        XCTAssertTrue(app.buttons["player.play-pause"].waitForExistence(timeout: 5))
        chinese.tap()
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        expectation(for: ready, evaluatedWith: control)
        waitForExpectations(timeout: 15)
        app.buttons["player.mode-original"].tap()
        app.terminate()
        #endif
    }
}
