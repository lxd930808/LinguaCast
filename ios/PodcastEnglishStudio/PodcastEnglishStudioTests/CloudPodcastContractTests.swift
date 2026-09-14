import Foundation
import XCTest

/// WP11 contract pinning: the Podcast cloud orchestration relies on specific
/// shapes in the shared golden fixtures (services/content-pipeline/fixtures/contract).
/// These tests run in the SPM test target, which intentionally cannot link
/// CloudSyncKit/DomainModels (package cycle), so they validate the wire contract
/// via JSONSerialization. DTO-level decoding is covered by DomainModels tests;
/// gateway behavior by CloudSyncKit tests.
final class CloudPodcastContractTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures/CloudContent"
        )
        let data = try Data(contentsOf: try XCTUnwrap(url, "fixture \(name) missing"))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "fixture \(name) is not a JSON object"
        )
    }

    // MARK: - Ready job carries an installable manifest

    func testReadyPodcastJobCarriesInstallableArtifactManifest() throws {
        let job = try fixture("job-ready-podcast.json")
        XCTAssertEqual(job["status"] as? String, "ready")
        // audioReady / subtitlesReady are tracked separately by the client (WP11).
        XCTAssertEqual(job["audioReady"] as? Bool, true)
        XCTAssertEqual(job["subtitlesReady"] as? Bool, true)
        // stableKey inputs must all be present for RemoteContentJobRecord.
        for key in ["jobId", "contentType", "contentKey", "targetLanguage", "translationQuality", "pipelineVersion"] {
            XCTAssertNotNil(job[key] as? String, "missing \(key)")
        }

        let artifacts = try XCTUnwrap(job["artifacts"] as? [String: Any])
        let schemaVersion = try XCTUnwrap(artifacts["schemaVersion"] as? Int)
        XCTAssertLessThanOrEqual(schemaVersion, 1, "client supports artifact schema v1 only")
        let files = try XCTUnwrap(artifacts["files"] as? [[String: Any]])
        var requiredRoles: Set<String> = []
        for file in files {
            let name = try XCTUnwrap(file["name"] as? String)
            let role = try XCTUnwrap(file["role"] as? String)
            XCTAssertEqual(file["status"] as? String, "ready", name)
            if file["required"] as? Bool == true {
                requiredRoles.insert(role)
                // SHA-256 verification happens per file before cache replace.
                let sha256 = try XCTUnwrap(file["sha256"] as? String, name)
                XCTAssertEqual(sha256.count, 64, name)
                // ETag enables 304 reuse on re-install.
                XCTAssertNotNil(file["etag"] as? String, name)
            }
        }
        XCTAssertEqual(requiredRoles, ["segments", "sourceVtt", "targetVtt"])
    }

    // MARK: - Segments envelope shape matches the local segment model

    func testSegmentsEnvelopeMatchesLocalLearningSegmentShape() throws {
        let envelope = try fixture("learning-segments-bilingual.json")
        XCTAssertEqual(envelope["schemaVersion"] as? Int, 1)
        let segments = try XCTUnwrap(envelope["segments"] as? [[String: Any]])
        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            XCTAssertNotNil(segment["sequence"] as? Int)
            XCTAssertNotNil(segment["startMS"] as? Int)
            XCTAssertNotNil(segment["endMS"] as? Int)
            XCTAssertNotNil(segment["text"] as? String)
            let translation = try XCTUnwrap(segment["translation"] as? String)
            XCTAssertFalse(translation.isEmpty, "cloud artifacts are fully translated")
        }
    }

    // MARK: - Failed jobs carry retry semantics for error mapping

    func testFailedFixturesCarryErrorCodeAndRetrySemantics() throws {
        let retryable = try fixture("job-failed-retryable.json")
        XCTAssertEqual(retryable["status"] as? String, "failed")
        let error = try XCTUnwrap(retryable["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "SOURCE_RATE_LIMITED")
        XCTAssertEqual(error["retryable"] as? Bool, true)
        XCTAssertEqual(error["retryAfterSeconds"] as? Int, 120)
        XCTAssertEqual(error["failedStage"] as? String, "fetching_audio")
        XCTAssertNotNil(error["traceId"] as? String)

        let fatal = try fixture("job-failed-non-retryable.json")
        let fatalError = try XCTUnwrap(fatal["error"] as? [String: Any])
        XCTAssertEqual(fatalError["retryable"] as? Bool, false)
    }

    // MARK: - Lookup drives restart recovery

    func testLookupFixturesCoverHitAndMiss() throws {
        let hit = try fixture("lookup-response-hit.json")
        XCTAssertNotNil(hit["job"] as? [String: Any], "hit carries the adopted job")
        let miss = try fixture("lookup-response-miss.json")
        XCTAssertTrue(miss["job"] is NSNull, "miss carries a null job")
    }

    // MARK: - Create request shape matches what PipelineRunner submits

    func testCreateRequestPodcastMatchesClientSubmissionShape() throws {
        let request = try fixture("create-request-podcast.json")
        XCTAssertEqual(request["contentType"] as? String, "podcast_episode")
        XCTAssertTrue((request["contentKey"] as? String)?.hasPrefix("podcast:") ?? false)
        let source = try XCTUnwrap(request["source"] as? [String: Any])
        XCTAssertEqual(source["platform"] as? String, "rss")
        XCTAssertNotNil(source["sourceId"] as? String)
        XCTAssertNotNil(source["url"] as? String)
        XCTAssertEqual(request["sourceLanguage"] as? String, "en")
        XCTAssertNotNil(request["targetLanguage"] as? String)
        XCTAssertNotNil(request["translationQuality"] as? String)
        XCTAssertEqual(request["clientArtifactSchemaVersion"] as? Int, 1)
    }

    // MARK: - Cancel / expired jobs are terminal and never block regeneration

    func testCancelledAndExpiredJobsAreTerminalWithoutArtifacts() throws {
        for name in ["job-cancelled.json", "job-expired.json"] {
            let job = try fixture(name)
            XCTAssertNotNil(job["jobId"] as? String, name)
            XCTAssertTrue(job["artifacts"] is NSNull, name)
        }
        XCTAssertEqual(try fixture("job-cancelled.json")["status"] as? String, "cancelled")
        XCTAssertEqual(try fixture("job-expired.json")["status"] as? String, "expired")
    }
}
