import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

final class PodcastFeedConditionalRefreshTests: XCTestCase {
    private let feedURL = URL(string: "https://example.com/feed.xml")!

    func testConditionalHeadersRequireMatchingURLBaselineAndRecentMode() {
        let validators = PodcastFeedValidators(
            etag: "\"abc\"",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            feedURL: feedURL.absoluteString
        )

        let headers = PodcastFeedConditionalRequestPolicy.conditionalHeaders(
            validators: validators,
            currentFeedURL: feedURL,
            mode: .recent(limit: 50),
            hasLocalCatalogBaseline: true
        )
        XCTAssertEqual(headers?.ifNoneMatch, "\"abc\"")
        XCTAssertEqual(headers?.ifModifiedSince, "Mon, 01 Jan 2024 00:00:00 GMT")
    }

    func testConditionalHeadersSkipWhenURLDoesNotMatch() {
        let validators = PodcastFeedValidators(
            etag: "\"abc\"",
            lastModified: nil,
            feedURL: "https://example.com/old-feed.xml"
        )
        let headers = PodcastFeedConditionalRequestPolicy.conditionalHeaders(
            validators: validators,
            currentFeedURL: feedURL,
            mode: .recent(limit: 50),
            hasLocalCatalogBaseline: true
        )
        XCTAssertNil(headers)
    }

    func testFullHistoryRefreshBypassesConditionalHeaders() {
        let validators = PodcastFeedValidators(
            etag: "\"abc\"",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            feedURL: feedURL.absoluteString
        )
        let headers = PodcastFeedConditionalRequestPolicy.conditionalHeaders(
            validators: validators,
            currentFeedURL: feedURL,
            mode: .all,
            hasLocalCatalogBaseline: true
        )
        XCTAssertNil(headers)
    }

    func testMissingBaselineSkipsConditionalHeaders() {
        let validators = PodcastFeedValidators(
            etag: "\"abc\"",
            feedURL: feedURL.absoluteString
        )
        let headers = PodcastFeedConditionalRequestPolicy.conditionalHeaders(
            validators: validators,
            currentFeedURL: feedURL,
            mode: .recent(limit: 50),
            hasLocalCatalogBaseline: false
        )
        XCTAssertNil(headers)
    }

    func testResponseActionAccepts304OnlyWithBaseline() {
        XCTAssertEqual(
            PodcastFeedConditionalRequestPolicy.responseAction(
                statusCode: 304,
                hasLocalCatalogBaseline: true
            ),
            .acceptNotModified
        )
        XCTAssertEqual(
            PodcastFeedConditionalRequestPolicy.responseAction(
                statusCode: 304,
                hasLocalCatalogBaseline: false
            ),
            .retryUnconditionally
        )
    }

    func testResponseActionRetriesOn412() {
        XCTAssertEqual(
            PodcastFeedConditionalRequestPolicy.responseAction(
                statusCode: 412,
                hasLocalCatalogBaseline: true
            ),
            .retryUnconditionally
        )
    }

    func testResponseActionAccepts200() {
        XCTAssertEqual(
            PodcastFeedConditionalRequestPolicy.responseAction(
                statusCode: 200,
                hasLocalCatalogBaseline: true
            ),
            .acceptModified
        )
    }

    func testValidatorsFrom200ReplaceAndClearMissingHeaders() throws {
        let previous = PodcastFeedValidators(
            etag: "\"old\"",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            feedURL: feedURL.absoluteString
        )
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: feedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"new\""]
            )
        )
        let next = PodcastFeedConditionalRequestPolicy.validators(
            from: response,
            feedURL: feedURL,
            previous: previous
        )
        XCTAssertEqual(next.etag, "\"new\"")
        XCTAssertNil(next.lastModified)
        XCTAssertEqual(next.feedURL, feedURL.absoluteString)
    }

    func testValidatorsFrom304PreserveMissingHeaders() throws {
        let previous = PodcastFeedValidators(
            etag: "\"old\"",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            feedURL: feedURL.absoluteString
        )
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: feedURL,
                statusCode: 304,
                httpVersion: nil,
                headerFields: ["ETag": "\"refreshed\""]
            )
        )
        let next = PodcastFeedConditionalRequestPolicy.validators(
            from: response,
            feedURL: feedURL,
            previous: previous
        )
        XCTAssertEqual(next.etag, "\"refreshed\"")
        XCTAssertEqual(next.lastModified, "Mon, 01 Jan 2024 00:00:00 GMT")
    }

    func testConditionalHeadersApplyToURLRequest() {
        var request = URLRequest(url: feedURL)
        PodcastFeedConditionalHeaders(
            ifNoneMatch: "\"abc\"",
            ifModifiedSince: "Mon, 01 Jan 2024 00:00:00 GMT"
        ).applying(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-Modified-Since"),
            "Mon, 01 Jan 2024 00:00:00 GMT"
        )
    }
}
