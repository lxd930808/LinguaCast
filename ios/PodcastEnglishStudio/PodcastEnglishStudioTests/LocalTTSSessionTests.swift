import XCTest
@testable import PodcastEnglishStudioCore

final class LocalTTSSessionTests: XCTestCase {
    func testPauseDuringPreparationPreventsAutomaticPlayback() throws {
        var session = TTSAudioSessionState(episodeID: "e", isPlaying: true)
        let request = session.request(.chinese)
        XCTAssertEqual(session.selectedMode, .original)
        XCTAssertTrue(session.isPlaying)
        XCTAssertTrue(session.beginPreparation(request))
        XCTAssertFalse(session.isPlaying)
        session.pause()
        XCTAssertTrue(session.finishPreparation(request))
        XCTAssertEqual(session.selectedMode, .chinese)
        XCTAssertFalse(session.isPlaying)
    }
    func testOldTransitionCannotResumeAfterNewRequestOrEpisodeChange() {
        var session = TTSAudioSessionState(episodeID: "one", isPlaying: true)
        let first = session.request(.chinese)
        XCTAssertTrue(session.beginPreparation(first))
        let second = session.request(.original)
        XCTAssertFalse(session.finishPreparation(first))
        XCTAssertTrue(session.beginPreparation(second))
        XCTAssertTrue(session.finishPreparation(second))
        XCTAssertTrue(session.isPlaying)
        let third = session.request(.chinese)
        session.changeEpisode(to: "two")
        XCTAssertFalse(session.beginPreparation(third))
        XCTAssertFalse(session.finishPreparation(third))
        XCTAssertEqual(session.selectedMode, .original)
        XCTAssertFalse(session.isPlaying)
    }

    func testDownloadCancellationPreservesOriginalButHandoverFailurePauses() {
        var session = TTSAudioSessionState(episodeID: "e", isPlaying: true)
        let download = session.request(.chinese)
        XCTAssertTrue(session.fail(download))
        XCTAssertTrue(session.isPlaying)
        let handover = session.request(.chinese)
        XCTAssertTrue(session.beginPreparation(handover))
        XCTAssertTrue(session.fail(handover))
        XCTAssertFalse(session.isPlaying)
        XCTAssertEqual(session.selectedMode, .original)
        XCTAssertFalse(session.finishPreparation(handover))
    }

    func testReplacementMustPassItsOwnPreflightBeforeItCanFinish() {
        var session = TTSAudioSessionState(episodeID: "e", isPlaying: true)
        let first = session.request(.chinese)
        XCTAssertTrue(session.beginPreparation(first))
        let replacement = session.request(.original)
        XCTAssertFalse(session.finishPreparation(replacement))
        XCTAssertFalse(session.isPlaying)
        XCTAssertTrue(session.beginPreparation(replacement))
        XCTAssertTrue(session.finishPreparation(replacement))
        XCTAssertTrue(session.isPlaying)
    }

}
