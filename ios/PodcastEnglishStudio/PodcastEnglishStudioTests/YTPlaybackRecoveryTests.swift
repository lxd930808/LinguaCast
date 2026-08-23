import XCTest
@testable import PodcastEnglishStudioCore

final class YTPlaybackRecoveryTests: XCTestCase {
    func testComposedHLSPreferredOnTVOS17And18ButDisabledOn26Plus() {
        XCTAssertTrue(
            YTComposedPlaybackCompatibilityPolicy.prefersComposedHLSSinglePlayer(
                platform: .tvOS,
                majorVersion: 17
            )
        )
        XCTAssertTrue(
            YTComposedPlaybackCompatibilityPolicy.prefersComposedHLSSinglePlayer(
                platform: .tvOS,
                majorVersion: 18
            )
        )
        XCTAssertTrue(
            YTComposedPlaybackCompatibilityPolicy.prefersComposedHLSSinglePlayer(
                platform: .tvOS,
                majorVersion: 25
            )
        )
        XCTAssertFalse(
            YTComposedPlaybackCompatibilityPolicy.prefersComposedHLSSinglePlayer(
                platform: .tvOS,
                majorVersion: 26
            )
        )
        XCTAssertFalse(
            YTComposedPlaybackCompatibilityPolicy.prefersComposedHLSSinglePlayer(
                platform: .tvOS,
                majorVersion: 27
            )
        )
        XCTAssertFalse(
            YTComposedPlaybackCompatibilityPolicy.prefersComposedHLSSinglePlayer(
                platform: .iOS,
                majorVersion: 18
            )
        )
    }

    func testPrepareRestoreWarmupKeepUpFalseDoesNotStartStallWatchdog() {
        var machine = YTPlaybackRecoveryMachine()
        let snapshot = YTPlaybackRecoverySnapshot(position: 714.2, wantsPlayback: true, rate: 1)

        XCTAssertEqual(
            machine.handle(.beginItemReplace(snapshot: snapshot)),
            .scheduleWatchdog(.prepareTimeout, after: 25)
        )
        XCTAssertEqual(machine.phase, .preparing)
        XCTAssertEqual(
            machine.handle(.keepUpChanged(false)),
            .none
        )
        XCTAssertNil(machine.continuousStallStartedAt)

        _ = machine.handle(.itemsReady)
        XCTAssertEqual(machine.phase, .restoring)
        XCTAssertEqual(machine.handle(.keepUpChanged(false)), .none)

        _ = machine.handle(.restoreSeekSucceeded)
        XCTAssertEqual(machine.phase, .warmingUp)
        XCTAssertEqual(machine.handle(.keepUpChanged(false)), .none)
        XCTAssertFalse(
            YTPlaybackStallRecoveryPolicy.countsAsPlaybackStall(phase: .warmingUp)
        )
    }

    func testActiveSustainedStallDowngradesOnceWithTrustedPosition() {
        var machine = primedActiveMachine(position: 714.2, wantsPlayback: true)

        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            machine.handle(.keepUpChanged(false), now: now),
            .scheduleWatchdog(.sustainedStall, after: 8)
        )
        // Repeated false while already timing does not re-arm or escalate.
        XCTAssertEqual(machine.handle(.keepUpChanged(false), now: now.addingTimeInterval(2)), .none)

        let effect = machine.handle(.stallWatchdogFired)
        XCTAssertEqual(
            effect,
            .requestDowngrade(position: 714.2, wantsPlayback: true)
        )
        XCTAssertTrue(machine.didRequestAutoDowngrade)

        // Second fire / another false must not emit another downgrade.
        XCTAssertEqual(machine.handle(.stallWatchdogFired), .none)
        XCTAssertEqual(
            machine.handle(.keepUpChanged(false), now: now.addingTimeInterval(20)),
            .none
        )
    }

    func testBriefActiveStallCancelsWatchdogAndTwoBreaksDoNotImmediateDowngrade() {
        var machine = primedActiveMachine(position: 73, wantsPlayback: true)
        let t0 = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(
            machine.handle(.keepUpChanged(false), now: t0),
            .scheduleWatchdog(.sustainedStall, after: 8)
        )
        XCTAssertEqual(
            machine.handle(.keepUpChanged(true), now: t0.addingTimeInterval(1)),
            .cancelWatchdog
        )
        XCTAssertNil(machine.continuousStallStartedAt)
        XCTAssertFalse(machine.didRequestAutoDowngrade)

        // A second brief break within 60s must not immediate-downgrade.
        XCTAssertEqual(
            machine.handle(.keepUpChanged(false), now: t0.addingTimeInterval(3)),
            .scheduleWatchdog(.sustainedStall, after: 8)
        )
        XCTAssertEqual(
            machine.handle(.keepUpChanged(true), now: t0.addingTimeInterval(4)),
            .cancelWatchdog
        )
        XCTAssertFalse(machine.didRequestAutoDowngrade)
    }

    func testSourceReplaceDoesNotPublishZeroAndRestoresSharedPosition() {
        var machine = YTPlaybackRecoveryMachine(phase: .active, generation: 3)
        let snapshot = YTPlaybackRecoverySnapshot(
            position: 714.2,
            wantsPlayback: true,
            rate: 1.25
        )

        XCTAssertEqual(
            machine.handle(.beginItemReplace(snapshot: snapshot)),
            .scheduleWatchdog(.prepareTimeout, after: 25)
        )
        XCTAssertEqual(machine.generation, 4)
        XCTAssertFalse(machine.shouldPublishObservedPlaybackTime)
        XCTAssertEqual(machine.trustedRecoveryPosition, 714.2)

        XCTAssertEqual(
            machine.handle(.itemsReady),
            .seekBothPlayers(to: 714.2, resume: false, rate: 1.25)
        )
        XCTAssertEqual(machine.phase, .restoring)
        XCTAssertFalse(machine.shouldPublishObservedPlaybackTime)

        XCTAssertEqual(
            machine.handle(.restoreSeekSucceeded),
            .resumePlayback(rate: 1.25)
        )
        XCTAssertEqual(machine.phase, .warmingUp)
        XCTAssertTrue(machine.shouldPublishObservedPlaybackTime)
    }

    func testStaleGenerationCallbacksAreIgnored() {
        var machine = YTPlaybackRecoveryMachine()
        _ = machine.handle(
            .beginItemReplace(
                snapshot: YTPlaybackRecoverySnapshot(
                    position: 10,
                    wantsPlayback: true,
                    rate: 1
                )
            )
        )
        let oldGeneration = machine.generation
        _ = machine.handle(
            .beginItemReplace(
                snapshot: YTPlaybackRecoverySnapshot(
                    position: 20,
                    wantsPlayback: false,
                    rate: 1
                )
            )
        )
        let newGeneration = machine.generation
        XCTAssertNotEqual(oldGeneration, newGeneration)

        XCTAssertEqual(
            machine.handle(.itemsReady, expectedGeneration: oldGeneration),
            .none
        )
        XCTAssertEqual(machine.phase, .preparing)
        XCTAssertEqual(machine.trustedRecoveryPosition, 20)

        XCTAssertEqual(
            machine.handle(.prepareWatchdogFired, expectedGeneration: oldGeneration),
            .none
        )
        XCTAssertFalse(machine.didRequestAutoDowngrade)

        XCTAssertEqual(
            machine.handle(.itemsReady, expectedGeneration: newGeneration),
            .seekBothPlayers(to: 20, resume: false, rate: 1)
        )
    }

    func testCommandsDuringRecoveryUpdatePendingSnapshotOnly() {
        var machine = YTPlaybackRecoveryMachine()
        _ = machine.handle(
            .beginItemReplace(
                snapshot: YTPlaybackRecoverySnapshot(
                    position: 714.2,
                    wantsPlayback: true,
                    rate: 1
                )
            )
        )
        XCTAssertFalse(machine.shouldApplyCommandsDirectlyToPlayer)

        XCTAssertEqual(machine.handle(.command(.pause)), .none)
        XCTAssertEqual(machine.snapshot?.wantsPlayback, false)
        XCTAssertEqual(machine.snapshot?.position, 714.2)

        XCTAssertEqual(
            machine.handle(.command(.seek(730, resumeAfterSeek: true))),
            .none
        )
        XCTAssertEqual(machine.snapshot?.position, 730)
        XCTAssertEqual(machine.snapshot?.wantsPlayback, true)

        XCTAssertEqual(machine.handle(.command(.play)), .none)
        XCTAssertEqual(machine.snapshot?.wantsPlayback, true)

        // Last command wins for the eventual restore seek.
        XCTAssertEqual(
            machine.handle(.itemsReady),
            .seekBothPlayers(to: 730, resume: false, rate: 1)
        )
        XCTAssertEqual(
            machine.handle(.restoreSeekSucceeded),
            .resumePlayback(rate: 1)
        )
    }

    func testPrepareTimeoutRequestsSingleDowngrade() {
        var machine = YTPlaybackRecoveryMachine()
        _ = machine.handle(
            .beginItemReplace(
                snapshot: YTPlaybackRecoverySnapshot(
                    position: 73,
                    wantsPlayback: true,
                    rate: 1
                )
            )
        )
        XCTAssertEqual(
            machine.handle(.prepareWatchdogFired),
            .requestDowngrade(position: 73, wantsPlayback: true)
        )
        XCTAssertEqual(machine.handle(.prepareWatchdogFired), .none)
    }

    func testLegacyWatchdogDelayConstantsMatchRecoveryMachine() {
        XCTAssertEqual(
            YTPlaybackStallRecoveryPolicy.watchdogDelay(allItemsReady: false),
            25
        )
        XCTAssertEqual(
            YTPlaybackStallRecoveryPolicy.watchdogDelay(allItemsReady: true),
            8
        )
    }

    private func primedActiveMachine(
        position: TimeInterval,
        wantsPlayback: Bool
    ) -> YTPlaybackRecoveryMachine {
        var machine = YTPlaybackRecoveryMachine()
        _ = machine.handle(
            .beginItemReplace(
                snapshot: YTPlaybackRecoverySnapshot(
                    position: position,
                    wantsPlayback: wantsPlayback,
                    rate: 1
                )
            )
        )
        _ = machine.handle(.itemsReady)
        _ = machine.handle(.restoreSeekSucceeded)
        _ = machine.handle(.firstSustainablePlayback)
        XCTAssertEqual(machine.phase, .active)
        return machine
    }
}
