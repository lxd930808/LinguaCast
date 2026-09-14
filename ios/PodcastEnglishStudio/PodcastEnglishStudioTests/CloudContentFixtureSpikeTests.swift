import Foundation
import XCTest

/// WP0/WP9 spike: the shared golden fixtures must be readable from the app
/// test bundle so CloudContent gateway tests (WP10) can replay them without a
/// live server. Detailed decode assertions live in DomainModels tests.
final class CloudContentFixtureSpikeTests: XCTestCase {
    private static let requiredFixtures = [
        "job-queued.json",
        "job-running-fetching-audio.json",
        "job-running-transcribing.json",
        "job-running-translating.json",
        "job-ready-podcast.json",
        "job-ready-video.json",
        "job-ready-partial-optional-artifact.json",
        "job-failed-retryable.json",
        "job-failed-non-retryable.json",
        "job-cancelled.json",
        "job-expired.json",
        "job-unknown-field.json",
        "job-unknown-enum.json",
        "job-schema-too-new.json",
        "audio-playback-url-response.json",
        "video-playback-url-request.json",
        "video-playback-url-response.json",
        "video-playback-url-unknown-field.json",
        "error-envelope-media-not-found.json",
        "error-envelope-media-not-ready.json",
        "error-envelope-media-integrity-failed.json",
        "artifact-manifest-podcast.json",
        "artifact-manifest-video.json",
        "learning-segments-bilingual.json",
        "lookup-response-hit.json",
        "lookup-response-miss.json",
        "error-envelope-invalid-request.json",
        "content-key-vectors.json",
        "create-request-podcast.json",
        "create-request-video.json"
    ]

    func testAllGoldenFixturesAreBundledAndParseAsJSON() throws {
        for name in Self.requiredFixtures {
            let url = Bundle.module.url(
                forResource: name, withExtension: nil, subdirectory: "Fixtures/CloudContent"
            )
            XCTAssertNotNil(url, "fixture \(name) missing from test bundle")
            let data = try Data(contentsOf: try XCTUnwrap(url))
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), "fixture \(name) is not valid JSON")
        }
    }
}
