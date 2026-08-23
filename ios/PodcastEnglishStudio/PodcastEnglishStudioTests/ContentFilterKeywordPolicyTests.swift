import XCTest
@testable import PodcastEnglishStudioCore

final class ContentFilterKeywordPolicyTests: XCTestCase {
    func testParsesKeywordsAcrossCommaCJKSemicolonAndWhitespaceSeparators() {
        let policy = ContentFilterKeywordPolicy(rawKeywords: "Prank, 整蛊、挑战; vlog\n短剧  DIY")

        XCTAssertEqual(
            policy.keywords,
            ["prank", "整蛊", "挑战", "vlog", "短剧", "diy"]
        )
    }

    func testEmptyAndWhitespaceOnlyInputYieldsNoKeywords() {
        XCTAssertTrue(ContentFilterKeywordPolicy(rawKeywords: "").isEmpty)
        XCTAssertTrue(ContentFilterKeywordPolicy(rawKeywords: "  , ，、; \n\t ").isEmpty)
    }

    func testMatchesTitleCaseInsensitively() {
        let policy = ContentFilterKeywordPolicy(rawKeywords: "prank")

        XCTAssertTrue(policy.matches(title: "Top 10 PRANK ideas", channel: nil))
        XCTAssertTrue(policy.matches(title: "prank", channel: nil))
        XCTAssertFalse(policy.matches(title: "Daily English listening", channel: nil))
    }

    func testMatchesChannelOrShowName() {
        let policy = ContentFilterKeywordPolicy(rawKeywords: "prank channel")

        XCTAssertTrue(policy.matches(title: "Episode 5", channel: "The Prank Channel"))
        XCTAssertFalse(policy.matches(title: "Episode 5", channel: "English Pod"))
    }

    func testMatchesCJKKeywordAgainstTitle() {
        let policy = ContentFilterKeywordPolicy(rawKeywords: "整蛊")

        XCTAssertTrue(policy.matches(title: "办公室整蛊大作战", channel: nil))
        XCTAssertFalse(policy.matches(title: "每日英语听力", channel: nil))
    }

    func testNoKeywordsNeverMatches() {
        let policy = ContentFilterKeywordPolicy(rawKeywords: "")

        XCTAssertFalse(policy.matches(title: "prank video", channel: "prank channel"))
    }

    func testNilChannelIsTreatedAsEmpty() {
        let policy = ContentFilterKeywordPolicy(rawKeywords: "vlog")

        XCTAssertTrue(policy.matches(title: "My vlog", channel: nil))
        XCTAssertFalse(policy.matches(title: "Lecture", channel: nil))
    }
}
