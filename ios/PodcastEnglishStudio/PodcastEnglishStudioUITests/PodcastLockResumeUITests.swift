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

        // Verify the saved cue while paused; a one-second cue may advance while
        // XCTest waits for the tap animation and the application to become idle.
        let activeCue = app.descendants(matching: .any)["transcript.segment.9"]
        XCTAssertTrue(activeCue.waitForExistence(timeout: 5))
        XCTAssertEqual(activeCue.value as? String, "active")
        XCTAssertTrue(activeCue.isHittable, "Saved subtitle must stay visible after activation")
        playPause.tap()

        let deadline = Date().addingTimeInterval(6)
        var sawLater = false
        while Date() < deadline {
            let current = app.descendants(matching: .any)
                .matching(NSPredicate(format: "value == %@", "active")).firstMatch
            if current.exists,
               let sequence = Int(current.identifier.replacingOccurrences(of: "transcript.segment.", with: "")),
               sequence >= 11 {
                XCTAssertTrue(current.isHittable, "The resumed active subtitle must remain visible")
                sawLater = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(sawLater, "Subtitle follow did not advance after resume play")

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
            "-linguacast-ui-testing", "-linguacast-ui-hide-test-chrome",
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
