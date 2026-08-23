import XCTest
@testable import DomainModels

final class YTVideoRecordSubtitleCompletionTests: XCTestCase {
    func testTranslatingWithBothPathsIsNotCompleted() {
        let video = makeVideo(status: "translating", enPath: "/tmp/en.vtt", zhPath: "/tmp/zh.vtt")
        XCTAssertTrue(video.enReady)
        XCTAssertTrue(video.zhReady)
        XCTAssertFalse(video.bilingualSubtitlesCompleted)
    }

    func testReadyStatusIsCompleted() {
        let video = makeVideo(status: "ready", enPath: "/tmp/en.vtt", zhPath: "/tmp/zh.vtt")
        XCTAssertTrue(video.bilingualSubtitlesCompleted)
    }

    func testLegacyUnknownStatusWithBothPathsIsCompleted() {
        let video = makeVideo(status: "legacy_complete", enPath: "/tmp/en.vtt", zhPath: "/tmp/zh.vtt")
        XCTAssertTrue(video.bilingualSubtitlesCompleted)
    }

    func testPartialStatusWithBothPathsIsNotCompleted() {
        let video = makeVideo(status: "partial", enPath: "/tmp/en.vtt", zhPath: "/tmp/zh.vtt")
        XCTAssertFalse(video.bilingualSubtitlesCompleted)
    }

    private func makeVideo(status: String, enPath: String?, zhPath: String?) -> YTVideoRecord {
        let video = YTVideoRecord(
            id: "video-1",
            channelRecordID: "channel-1",
            channelID: "UCabc",
            title: "Demo",
            url: "https://www.youtube.com/watch?v=video-1"
        )
        video.subtitleStatus = status
        video.enVTTPath = enPath
        video.zhVTTPath = zhPath
        return video
    }
}
