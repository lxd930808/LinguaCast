import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

/// WP13: cloud video subtitle orchestration policies. The app glue in
/// YTLocalService delegates every guard decision to these Core types, so these
/// tests pin the behavior the cloud path relies on:
///  - a stale job (previous video / previous pass) can never write results
///  - the segments.json artifact envelope decodes the golden fixture
final class CloudVideoOrchestrationTests: XCTestCase {

    // MARK: Video-switch race guard

    private let contentKey = "video:youtube:dQw4w9WgXcQ"
    private let stableKey = "video|video:youtube:dQw4w9WgXcQ|zh-Hans|fast|v10.1"

    func testJobUpdateGuardAcceptsMatchingIdentity() {
        XCTAssertTrue(
            CloudVideoJobUpdateGuard.shouldApply(
                expectedContentKey: contentKey,
                expectedStableKey: stableKey,
                incomingContentKey: contentKey,
                incomingStableKey: stableKey
            )
        )
    }

    func testJobUpdateGuardRejectsPreviousVideoResult() {
        // Video switch: a job belonging to the previously opened video must
        // never write into the one now on screen.
        XCTAssertFalse(
            CloudVideoJobUpdateGuard.shouldApply(
                expectedContentKey: contentKey,
                expectedStableKey: stableKey,
                incomingContentKey: "video:youtube:oldVideoID",
                incomingStableKey: "video|video:youtube:oldVideoID|zh-Hans|fast|v10.1"
            )
        )
    }

    func testJobUpdateGuardRejectsStaleStableKeyAndEmptyExpectation() {
        XCTAssertFalse(
            CloudVideoJobUpdateGuard.shouldApply(
                expectedContentKey: contentKey,
                expectedStableKey: stableKey,
                incomingContentKey: contentKey,
                incomingStableKey: "video|video:youtube:dQw4w9WgXcQ|zh-Hans|quality|v10.0"
            )
        )
        XCTAssertFalse(
            CloudVideoJobUpdateGuard.shouldApply(
                expectedContentKey: "",
                expectedStableKey: "",
                incomingContentKey: contentKey,
                incomingStableKey: stableKey
            )
        )
    }

    // MARK: Segments artifact envelope

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/CloudContent")
        )
        return try Data(contentsOf: url)
    }

    func testSegmentsEnvelopeDecodesGoldenFixture() throws {
        let envelope = try CloudSegmentsArtifactEnvelope.decode(
            from: fixtureData("learning-segments-bilingual.json")
        )
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.sourceLanguage, "en")
        XCTAssertEqual(envelope.targetLanguage, "zh-Hans")
        XCTAssertEqual(envelope.segments.count, 3)
        let first = envelope.segments[0]
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.timingSource, .wordTimeline)
        XCTAssertEqual(first.playbackSentence?.id, 1)
        XCTAssertEqual(first.speaker, "S1")
        XCTAssertFalse(first.words.isEmpty)
        XCTAssertFalse(first.translation.isEmpty)
    }

    func testSegmentsEnvelopeRejectsTooNewSchema() throws {
        let json = "{\"schemaVersion\": 2, \"sourceLanguage\": \"en\", \"targetLanguage\": \"zh-Hans\", \"segments\": []}"
        XCTAssertThrowsError(try CloudSegmentsArtifactEnvelope.decode(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? CloudSegmentsArtifactError, .unsupportedSchemaVersion(2))
        }
    }

    func testSegmentsEnvelopeRejectsEmptySegments() throws {
        let json = "{\"schemaVersion\": 1, \"sourceLanguage\": \"en\", \"targetLanguage\": \"zh-Hans\", \"segments\": []}"
        XCTAssertThrowsError(try CloudSegmentsArtifactEnvelope.decode(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? CloudSegmentsArtifactError, .emptySegments)
        }
    }

    func testSegmentsEnvelopeRejectsMalformedData() throws {
        XCTAssertThrowsError(try CloudSegmentsArtifactEnvelope.decode(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? CloudSegmentsArtifactError, .malformed)
        }
        XCTAssertThrowsError(try CloudSegmentsArtifactEnvelope.decode(from: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? CloudSegmentsArtifactError, .malformed)
        }
    }
}
