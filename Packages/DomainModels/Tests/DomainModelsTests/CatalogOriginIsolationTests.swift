import XCTest
@testable import DomainModels

final class CatalogOriginIsolationTests: XCTestCase {
    func testNilOriginAppearsInSubscriptionLibrary() {
        XCTAssertTrue(CatalogIsolationPolicy.appearsInSubscriptionLibrary(originRaw: nil))
        XCTAssertFalse(CatalogIsolationPolicy.isPinnedAssistantHomeItem(originRaw: nil, pinnedToHome: true))
    }

    func testAssistantOriginIsHiddenFromLibraryUntilPinned() {
        XCTAssertFalse(CatalogIsolationPolicy.appearsInSubscriptionLibrary(originRaw: CatalogOrigin.assistant.rawValue))
        XCTAssertFalse(
            CatalogIsolationPolicy.isPinnedAssistantHomeItem(
                originRaw: CatalogOrigin.assistant.rawValue,
                pinnedToHome: false
            )
        )
        XCTAssertTrue(
            CatalogIsolationPolicy.isPinnedAssistantHomeItem(
                originRaw: CatalogOrigin.assistant.rawValue,
                pinnedToHome: true
            )
        )
    }

    func testEpisodeAndVideoHelpers() {
        let episode = EpisodeRecord(
            showTitle: "Show",
            episodeTitle: "Ep",
            episodeGUID: "guid-1",
            enclosureURL: "https://example.com/a.mp3",
            originRaw: CatalogOrigin.assistant.rawValue,
            pinnedToHome: true,
            assistantFeedURL: "https://example.com/feed.xml"
        )
        XCTAssertEqual(episode.catalogOrigin, .assistant)
        XCTAssertFalse(episode.appearsInSubscriptionLibrary)
        XCTAssertTrue(episode.isPinnedAssistantHomeItem)

        let video = YTVideoRecord(
            id: "vid-1",
            channelRecordID: CatalogOrigin.assistantChannelRecordID,
            channelID: CatalogOrigin.assistantChannelRecordID,
            title: "Video",
            url: "https://www.youtube.com/watch?v=vid-1",
            originRaw: CatalogOrigin.assistant.rawValue
        )
        XCTAssertFalse(video.appearsInSubscriptionLibrary)
        XCTAssertFalse(video.isPinnedAssistantHomeItem)
        video.pinnedToHome = true
        XCTAssertTrue(video.isPinnedAssistantHomeItem)
    }

    func testHomeShelfExcludesSubscriptionPins() {
        XCTAssertFalse(
            CatalogIsolationPolicy.isPinnedAssistantHomeItem(
                originRaw: nil,
                pinnedToHome: true
            )
        )
    }
}
