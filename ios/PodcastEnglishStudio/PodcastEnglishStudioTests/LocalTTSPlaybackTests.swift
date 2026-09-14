import XCTest
@testable import PodcastEnglishStudioCore

final class LocalTTSPlaybackTests: XCTestCase {
    private func units(_ ready: [Double?]) -> [TTSPrefetchUnit] {
        ready.enumerated().map { TTSPrefetchUnit(cursor: TTSPlaybackCursor(segmentIndex: $0.offset), readySeconds: $0.element) }
    }

    func testHandoffLeadFollowsThePlaybackRate() {
        XCTAssertEqual(TTSHandoffSchedule.leadSeconds(duration: 4, currentTime: 1, rate: 1) ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(TTSHandoffSchedule.leadSeconds(duration: 4, currentTime: 1, rate: 1.25) ?? 0, 2.4, accuracy: 0.0001)
        XCTAssertEqual(TTSHandoffSchedule.leadSeconds(duration: 4, currentTime: 1, rate: 0.75) ?? 0, 4, accuracy: 0.0001)
    }

    func testHandoffRefusesToArmAStartItCannotHonour() {
        // Past the end, stopped rate, garbage input, or too little time to arm.
        XCTAssertNil(TTSHandoffSchedule.leadSeconds(duration: 4, currentTime: 4.5, rate: 1))
        XCTAssertNil(TTSHandoffSchedule.leadSeconds(duration: 4, currentTime: 1, rate: 0))
        XCTAssertNil(TTSHandoffSchedule.leadSeconds(duration: .nan, currentTime: 1, rate: 1))
        XCTAssertNil(TTSHandoffSchedule.leadSeconds(duration: 4, currentTime: 3.95, rate: 1))
    }

    func testCursorsOrderByFragmentWithinSegment() {
        XCTAssertLessThan(TTSPlaybackCursor(segmentIndex: 3, fragmentIndex: 0), TTSPlaybackCursor(segmentIndex: 3, fragmentIndex: 1))
        XCTAssertLessThan(TTSPlaybackCursor(segmentIndex: 3, fragmentIndex: 9), TTSPlaybackCursor(segmentIndex: 4))
    }

    func testLookaheadCoversTwoSegmentsAndTheWallClockCushion() {
        let policy = TTSPrefetchPolicy()
        XCTAssertEqual(policy.residentCount(units: units([3, 3, 3, 3, 3]), rate: 1, pressure: .normal), 4)
        // One-second sentences buy almost no time, so the window grows to its cap.
        XCTAssertEqual(policy.residentCount(units: units([1, 1, 1, 1, 1]), rate: 1, pressure: .normal), 4)
        XCTAssertEqual(policy.residentCount(units: units([3, 3]), rate: 1, pressure: .normal), 2)
        XCTAssertEqual(policy.residentCount(units: [], rate: 1, pressure: .normal), 0)
    }

    func testFasterPlaybackNeedsAtLeastAsMuchAudio() {
        let policy = TTSPrefetchPolicy()
        let clips = units([3, 3, 3, 3, 3])
        XCTAssertGreaterThanOrEqual(policy.residentCount(units: clips, rate: 1.25, pressure: .normal),
                                    policy.residentCount(units: clips, rate: 0.75, pressure: .normal))
    }

    func testWindowNeverGrowsWithTheTranscript() {
        let policy = TTSPrefetchPolicy()
        let long = units(Array(repeating: Double?.none, count: 500))
        XCTAssertLessThanOrEqual(policy.residentCount(units: long, rate: 1.25, pressure: .normal), policy.maxUnits)
    }

    func testThermalPressureKeepsOnlyTheSentenceBeingPlayed() {
        let policy = TTSPrefetchPolicy()
        XCTAssertEqual(policy.residentCount(units: units([3, 3, 3, 3]), rate: 1, pressure: .reduced), 1)
        XCTAssertEqual(policy.residentCount(units: units([3, 3, 3, 3]), rate: 1, pressure: .suspended), 1)
    }

    func testBackgroundPlaysCacheButNeverRunsTheModels() {
        let policy = TTSPrefetchPolicy()
        XCTAssertFalse(policy.allowsSynthesis(pressure: .normal, isForeground: false))
        XCTAssertFalse(policy.allowsSynthesis(pressure: .suspended, isForeground: true))
        XCTAssertTrue(policy.allowsSynthesis(pressure: .reduced, isForeground: true))
        XCTAssertEqual(TTSPrefetchPressure.from(.serious), .reduced)
        XCTAssertEqual(TTSPrefetchPressure.from(.critical), .suspended)
        XCTAssertEqual(TTSPrefetchPressure.from(.fair), .normal)
    }

    func testPreBufferWaitsForACushionButCanNeverDeadlock() {
        let policy = TTSPrefetchPolicy()
        XCTAssertFalse(policy.canStart(playheadSeconds: nil, nextIsReady: true, hasNext: true, rate: 1, waitedSeconds: 9))
        XCTAssertTrue(policy.canStart(playheadSeconds: 0.7, nextIsReady: false, hasNext: true, rate: 1.25, waitedSeconds: 0))
        XCTAssertTrue(policy.canStart(playheadSeconds: 0.7, nextIsReady: true, hasNext: true, rate: 1.25, waitedSeconds: 0))
        // The last sentence has nothing to buffer behind it.
        XCTAssertTrue(policy.canStart(playheadSeconds: 0.7, nextIsReady: false, hasNext: false, rate: 1, waitedSeconds: 0))
        // AC-10: waiting is capped, first sound never hostage to the lookahead.
        XCTAssertTrue(policy.canStart(playheadSeconds: 0.7, nextIsReady: false, hasNext: true, rate: 1,
                                      waitedSeconds: policy.startTimeoutSeconds))
        XCTAssertTrue(policy.canStart(playheadSeconds: 4, nextIsReady: false, hasNext: true, rate: 1, waitedSeconds: 0))
    }
    func testBufferOnlyCountsContinuousReadyAudioAndSubtractsPlayhead() {
        let policy = TTSPrefetchPolicy()
        XCTAssertEqual(policy.bufferedSeconds(units: units([6, 4, nil, 100]), currentTime: 2, rate: 2), 4)
        XCTAssertEqual(policy.bufferedSeconds(units: units([nil, 100]), currentTime: 0, rate: 1), 0)
        XCTAssertEqual(policy.bufferedSeconds(units: units([6]), currentTime: 0, rate: .nan), 0)
    }

}
