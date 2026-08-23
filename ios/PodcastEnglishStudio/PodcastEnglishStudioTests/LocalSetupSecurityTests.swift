import XCTest
@testable import PodcastEnglishStudioCore

final class LocalSetupSecurityTests: XCTestCase {
    func testAccessGrantExpiresAndCanBeInvalidatedAfterSuccessfulSubmission() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var grant = LocalSetupAccessGrant(
            token: "one-time-token",
            issuedAt: issuedAt,
            lifetime: 600
        )

        XCTAssertTrue(grant.accepts("one-time-token", at: issuedAt.addingTimeInterval(599)))
        XCTAssertFalse(grant.accepts("wrong-token", at: issuedAt))
        XCTAssertFalse(grant.accepts("one-time-token", at: issuedAt.addingTimeInterval(601)))

        grant.invalidate()
        XCTAssertFalse(grant.accepts("one-time-token", at: issuedAt.addingTimeInterval(1)))
    }

    func testAccessGrantCanBeConsumedOnlyOnce() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var grant = LocalSetupAccessGrant(token: "one-time-token", issuedAt: issuedAt, lifetime: 600)

        XCTAssertTrue(grant.consume("one-time-token", at: issuedAt))
        XCTAssertFalse(grant.consume("one-time-token", at: issuedAt))
    }

    func testLocalMediaAllowlistRejectsTokenEvenWhenPostedDirectly() {
        let filtered = LocalSetupFormPolicy.filteredLocalMediaFields([
            "localMediaEnabled": "true",
            "localMediaBaseURL": "https://media.example.com",
            "localMediaToken": "must-not-cross-http",
            "localMediaMode": "mp4",
            "localMediaPreferredHeight": "720"
        ])

        XCTAssertEqual(filtered, [
            "localMediaEnabled": "true",
            "localMediaBaseURL": "https://media.example.com",
            "localMediaMode": "mp4",
            "localMediaPreferredHeight": "720"
        ])
    }
}
