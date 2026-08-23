import XCTest

/// Background / foreground lifecycle for the podcast player page (iPad lock-resume acceptance).
final class PodcastLockResumeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBackgroundForegroundKeepsPlayButtonPositionAndResumesFromSavedTime() throws {
        #if os(tvOS)
        throw XCTSkip("Lock/unlock resume is an iOS/iPad acceptance path")
        #else
        let app = launchLockResumeFixture()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForLockResumeReady(app)

        let playPause = app.buttons["player.play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        let transport = app.descendants(matching: .any)["player.transport-row"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))

        // Ensure paused before simulating lock (inactive/background).
        if playPause.label.lowercased().contains("pause") {
            playPause.tap()
        }
        XCTAssertTrue(playPause.label.lowercased().contains("play"))

        let frameBefore = playPause.frame
        let midCueBefore = app.descendants(matching: .any)["transcript.segment.9"]
        XCTAssertTrue(midCueBefore.waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForLockResumeReady(app)

        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        let frameAfter = playPause.frame
        XCTAssertEqual(
            frameBefore.midX,
            frameAfter.midX,
            accuracy: 2,
            "Play/pause midX jumped across background/foreground"
        )
        XCTAssertEqual(
            frameBefore.midY,
            frameAfter.midY,
            accuracy: 2,
            "Play/pause midY jumped across background/foreground"
        )

        playPause.tap()

        // Resume from saved ~8s → cue 9 should remain active and visible with follow on.
        let activeCue = app.descendants(matching: .any)["transcript.segment.9"]
        XCTAssertTrue(activeCue.waitForExistence(timeout: 5))
        XCTAssertEqual(activeCue.value as? String, "active")
        XCTAssertTrue(activeCue.isHittable, "Active subtitle must stay visible after unlock play")

        // Follow continues: after a couple seconds cue 11 should become active.
        let laterCue = app.descendants(matching: .any)["transcript.segment.11"]
        let deadline = Date().addingTimeInterval(6)
        var sawLater = false
        while Date() < deadline {
            if laterCue.exists, (laterCue.value as? String) == "active" {
                sawLater = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(sawLater, "Subtitle follow did not advance after resume play")
        XCTAssertTrue(laterCue.isHittable)

        app.terminate()
        #endif
    }

    func testTransportRowIdentifierRemainsStableAcrossActivation() throws {
        #if os(tvOS)
        throw XCTSkip("iOS-only transport geometry check")
        #else
        let app = launchLockResumeFixture()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForLockResumeReady(app)

        let transport = app.descendants(matching: .any)["player.transport-row"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        let before = transport.frame

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitForLockResumeReady(app)

        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        let after = transport.frame
        XCTAssertEqual(before.height, after.height, accuracy: 1)
        XCTAssertEqual(before.minX, after.minX, accuracy: 2)
        app.terminate()
        #endif
    }

    private func launchLockResumeFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LINGUACAST_UI_SCENARIO"] = "podcast-lock-resume"
        app.launchArguments = [
            "-linguacast-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-linguacast-ui-scenario", "podcast-lock-resume"
        ]
        app.launch()
        return app
    }

    private func waitForLockResumeReady(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["screen.podcast-player"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["subtitle.ready-state"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["media.playback-controls"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["transcript.segment.9"].waitForExistence(timeout: 8))
    }
}
