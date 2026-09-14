#if canImport(PodcastEnglishStudio) && os(iOS)
import XCTest
@testable import PodcastEnglishStudio

final class PlayerDeepLinkTests: XCTestCase {
    func testValidPlayLink() {
        let url = URL(string: "linguacast://play?content_key=video%3Ayoutube%3AdQw4w9WgXcQ&start_ms=2700")!
        let parsed = PlayerDeepLink.parse(url)
        XCTAssertEqual(parsed?.contentKey, "video:youtube:dQw4w9WgXcQ")
        XCTAssertEqual(parsed?.startMs, 2700)
    }

    func testRejectsUnknownHostDuplicateAndOverflow() {
        XCTAssertNil(PlayerDeepLink.parse(URL(string: "linguacast://search?q=x")!))
        XCTAssertNil(PlayerDeepLink.parse(URL(string: "https://example.com")!))
        XCTAssertNil(PlayerDeepLink.parse(URL(string: "linguacast://play?content_key=a&start_ms=-1")!))
        XCTAssertNil(PlayerDeepLink.parse(URL(string: "linguacast://play?content_key=a&start_ms=1&start_ms=2")!))
    }

    func testAssistantTabIsIOSOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PodcastEnglishStudio/Features/Root/RootView.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(source.contains("#if os(iOS)"))
        XCTAssertTrue(source.contains("case assistant"))
        XCTAssertTrue(source.contains("tab.assistant"))
    }

    @MainActor
    func testConsumePendingClearsStoredLink() {
        let coordinator = PlaybackDeepLinkCoordinator()
        let url = URL(string: "linguacast://play?content_key=video%3Ayoutube%3Aabc&start_ms=1200")!
        _ = coordinator.handle(url)
        let first = coordinator.consumePending()
        XCTAssertEqual(first?.contentKey, "video:youtube:abc")
        XCTAssertEqual(first?.startMs, 1200)
        XCTAssertNil(coordinator.consumePending())
    }
}

#endif
