import XCTest
import PodcastEnglishStudioCore

final class LocalAudioProbeTests: XCTestCase {
    func testRejectsAppleEpisodePagesAsEnclosures() {
        XCTAssertFalse(
            LocalAudioProbe.isPlayableEnclosureURL(
                "https://podcasts.apple.com/us/podcast/andrew-ng/id1819090545?i=1000786527866"
            )
        )
        XCTAssertTrue(
            LocalAudioProbe.isPlayableEnclosureURL("https://traffic.megaphone.fm/APO4554511240.mp3")
        )
    }

    func testMagicBytesDistinguishMp3FromHTML() {
        XCTAssertTrue(LocalAudioProbe.looksLikeAudioMagic(Data([0x49, 0x44, 0x33, 0x04])))
        XCTAssertTrue(LocalAudioProbe.looksLikeAudioMagic(Data([0xFF, 0xFB, 0x90, 0x00])))
        XCTAssertFalse(LocalAudioProbe.looksLikeAudioMagic(Data("<!DOCTYPE html>".utf8)))
        XCTAssertFalse(LocalAudioProbe.looksLikeAudioMagic(Data("<html>".utf8)))
    }

    func testLooksLikeAudioFileReadsPrefixFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let html = dir.appending(path: "source.mp3")
        try Data("<!DOCTYPE html><html>Apple Podcasts</html>".utf8).write(to: html)
        XCTAssertFalse(LocalAudioProbe.looksLikeAudioFile(html))

        let mp3 = dir.appending(path: "real.mp3")
        try Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00]).write(to: mp3)
        XCTAssertTrue(LocalAudioProbe.looksLikeAudioFile(mp3))
    }
}
