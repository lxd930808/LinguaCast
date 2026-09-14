import Foundation
import SwiftData
import Testing
@testable import DomainModels

// Contract tests for the V10 cloud content models (WP9). Fixtures are the
// same golden samples the TypeScript service validates; both sides must agree.

@Suite("CloudContentModels contract")
struct CloudContentModelsTests {

    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DomainModelsTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // DomainModels
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/CloudContent")

    static func fixture(_ name: String) -> Data {
        let url = fixturesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            Issue.record("missing fixture \(name) at \(url.path)")
            return Data()
        }
        return data
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("all job fixtures decode with expected statuses")
    func decodeJobFixtures() throws {
        let expectations: [(String, CloudJobStatus)] = [
            ("job-queued.json", .queued),
            ("job-running-fetching-audio.json", .running),
            ("job-running-transcribing.json", .running),
            ("job-running-translating.json", .running),
            ("job-ready-podcast.json", .ready),
            ("job-ready-video.json", .ready),
            ("job-ready-partial-optional-artifact.json", .ready),
            ("job-failed-retryable.json", .failed),
            ("job-failed-non-retryable.json", .failed),
            ("job-cancelled.json", .cancelled),
            ("job-expired.json", .expired)
        ]
        for (name, expected) in expectations {
            let job = try Self.decoder().decode(CloudContentJobResponse.self, from: Self.fixture(name))
            #expect(job.status == expected, "\(name) status")
        }
    }

    @Test("unknown enum values decode without crashing")
    func unknownEnumTolerance() throws {
        let job = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-unknown-enum.json")
        )
        guard case .unknown(let raw) = job.status else {
            Issue.record("unknown status should map to .unknown")
            return
        }
        #expect(raw == "processing_remotely")
        #expect(!job.status.isTerminal, "unknown status is non-terminal")
        if case .unknown(let stageRaw)? = job.stage {
            #expect(stageRaw == "aligning_words")
        } else {
            Issue.record("unknown stage should map to .unknown")
        }
    }

    @Test("unknown JSON fields are ignored")
    func unknownFieldTolerance() throws {
        let job = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-unknown-field.json")
        )
        #expect(job.status == .running)
    }

    @Test("schema-too-new manifest is flagged incompatible")
    func schemaTooNew() throws {
        let job = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-schema-too-new.json")
        )
        #expect(job.artifacts?.schemaVersion == 2)
        #expect(job.artifacts?.isCompatibleWithClient == false)
    }

    @Test("ready podcast manifest carries verified file refs")
    func readyManifest() throws {
        let job = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-ready-podcast.json")
        )
        let artifacts = try #require(job.artifacts)
        #expect(artifacts.isCompatibleWithClient)
        #expect(artifacts.files.count == 4)
        #expect(artifacts.files.allSatisfy { $0.sha256.count == 64 })
        #expect(artifacts.audio?.mimeType == "audio/mpeg")
    }

    @Test("error fixtures decode code, retryable and traceId")
    func errorDecoding() throws {
        let retryable = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-failed-retryable.json")
        )
        #expect(retryable.error?.code == "SOURCE_RATE_LIMITED")
        #expect(retryable.error?.retryable == true)
        #expect(retryable.error?.retryAfterSeconds == 120)
        #expect(retryable.error?.traceId.hasPrefix("tr_") == true)

        let fatal = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-failed-non-retryable.json")
        )
        #expect(fatal.error?.retryable == false)
        #expect(fatal.error?.failedStage == .validatingSource)

        let envelope = try Self.decoder().decode(
            CloudErrorEnvelope.self, from: Self.fixture("error-envelope-invalid-request.json")
        )
        #expect(envelope.error.code == "INVALID_REQUEST")
    }

    @Test("audio playback URL response decodes")
    func playbackURL() throws {
        let response = try Self.decoder().decode(
            CloudAudioPlaybackURLResponse.self, from: Self.fixture("audio-playback-url-response.json")
        )
        #expect(response.acceptRanges == "bytes")
        #expect(response.expiresAt > response.expiresAt.addingTimeInterval(-3601))
    }

    @Test("video playback URL request and ready response decode")
    func videoPlaybackURL() throws {
        let request = try JSONDecoder().decode(
            CloudVideoPlaybackURLRequest.self, from: Self.fixture("video-playback-url-request.json")
        )
        #expect(request.contentType == .video)
        #expect(request.contentKey == "video:youtube:dQw4w9WgXcQ")
        #expect(request.preferredHeight == 720)

        let response = try Self.decoder().decode(
            CloudVideoPlaybackURLResponse.self, from: Self.fixture("video-playback-url-response.json")
        )
        #expect(response.schemaVersion == 1)
        #expect(response.mediaId.hasPrefix("cm_"))
        #expect(response.acceptRanges == "bytes")
        #expect(response.height == 720)
        #expect(response.videoCodec == "avc1")
        #expect(response.sha256.count == 64)
    }

    @Test("video playback URL unknown optional fields are ignored")
    func videoPlaybackURLUnknownFields() throws {
        let response = try Self.decoder().decode(
            CloudVideoPlaybackURLResponse.self, from: Self.fixture("video-playback-url-unknown-field.json")
        )
        #expect(response.mediaId == "cm_01JFXB2C4E6G8J0M2P4R")
        #expect(response.mediaVersion == "mp4-720-avc1-aac")
    }

    @Test("video playback URL schema too new is a decoding error")
    func videoPlaybackURLSchemaTooNew() throws {
        var json = try JSONSerialization.jsonObject(
            with: Self.fixture("video-playback-url-response.json")
        ) as? [String: Any]
        json?["schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: json as Any)
        do {
            _ = try Self.decoder().decode(CloudVideoPlaybackURLResponse.self, from: data)
            Issue.record("expected decoding error for schemaVersion 2")
        } catch is DecodingError {
            // Expected: clients must refuse a newer required schema.
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("content media error envelopes decode")
    func contentMediaErrorEnvelopes() throws {
        let missing = try Self.decoder().decode(
            CloudErrorEnvelope.self, from: Self.fixture("error-envelope-media-not-found.json")
        )
        #expect(missing.error.code == "MEDIA_NOT_FOUND")
        #expect(missing.error.retryable == false)

        let notReady = try Self.decoder().decode(
            CloudErrorEnvelope.self, from: Self.fixture("error-envelope-media-not-ready.json")
        )
        #expect(notReady.error.code == "MEDIA_NOT_READY")
        #expect(notReady.error.retryable == true)
        #expect(notReady.error.retryAfterSeconds == 8)

        let integrity = try Self.decoder().decode(
            CloudErrorEnvelope.self, from: Self.fixture("error-envelope-media-integrity-failed.json")
        )
        #expect(integrity.error.code == "MEDIA_INTEGRITY_FAILED")
    }

    @Test("lookup responses decode hit and miss")
    func lookup() throws {
        let hit = try Self.decoder().decode(
            CloudContentJobLookupResponse.self, from: Self.fixture("lookup-response-hit.json")
        )
        #expect(hit.job != nil)
        let miss = try Self.decoder().decode(
            CloudContentJobLookupResponse.self, from: Self.fixture("lookup-response-miss.json")
        )
        #expect(miss.job == nil)
    }

    struct KeyVector: Decodable {
        let name: String
        let contentType: String
        let input: [String: String]
        let expectedContentKey: String?
        let expectedDedupeKey: String?
    }

    @Test("content key golden vectors match the TypeScript reference")
    func contentKeyVectors() throws {
        struct Doc: Decodable { let vectors: [KeyVector] }
        let doc = try JSONDecoder().decode(Doc.self, from: Self.fixture("content-key-vectors.json"))
        for vector in doc.vectors where vector.expectedContentKey != nil {
            let actual: String
            if vector.contentType == "podcast_episode" {
                actual = CloudContentKeyPolicy.podcastContentKey(
                    feedURL: vector.input["feedUrl"]!,
                    episodeGUID: vector.input["episodeGuid"]!
                )
            } else {
                actual = CloudContentKeyPolicy.videoContentKey(
                    platform: vector.input["platform"]!,
                    videoID: vector.input["videoId"]!
                )
            }
            #expect(actual == vector.expectedContentKey, "vector \(vector.name)")
        }
    }

    @Test("assistant feed identity wins over an Apple episode page enclosure")
    func assistantFeedIdentityBeatsAppleEnclosure() {
        let apple =
            "https://podcasts.apple.com/us/podcast/andrew-ng-the-biggest-opportunities-in-ai-arent-where/id1819090545?i=1000786527866"
        let feed = "https://anchor.fm/s/105af30ec/podcast/rss"
        let identity = CloudContentKeyPolicy.podcastFeedIdentity(
            subscriptionFeedURL: nil,
            assistantFeedURL: feed,
            enclosureURL: apple
        )
        #expect(identity == feed)
        let key = CloudContentKeyPolicy.podcastContentKey(feedURL: identity, episodeGUID: "1000786527866")
        #expect(key == "podcast:e4c551b0b9db3d04:29ee3cf9252cf054")
    }

    @Test("progress merge never regresses")
    func progressMerge() {
        #expect(CloudProgressMergePolicy.merged(existing: 0.5, incoming: 0.2) == 0.5)
        #expect(CloudProgressMergePolicy.merged(existing: 0.5, incoming: 0.8) == 0.8)
        #expect(CloudPollPolicy.nextIntervalSeconds(serverHint: 0) == 1)
        #expect(CloudPollPolicy.nextIntervalSeconds(serverHint: 5000) == 60)
    }

    @Test("RemoteContentJobRecord applies server state with monotone progress")
    @MainActor
    func remoteRecordApply() throws {
        let container = try ModelContainer(
            for: RemoteContentJobRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let job = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-running-transcribing.json")
        )
        let record = RemoteContentJobRecord(
            stableKey: job.stableKey,
            contentKind: job.contentType.rawValue,
            contentKey: job.contentKey,
            jobID: job.jobId,
            statusRaw: job.status.rawValue,
            targetLanguage: job.targetLanguage,
            translationQuality: job.translationQuality.rawValue,
            pipelineVersion: job.pipelineVersion
        )
        context.insert(record)
        record.apply(job)
        #expect(record.progress == 0.48)
        #expect(record.audioReady)

        // A stale, older update must not regress progress or readiness.
        record.progress = 0.9
        record.apply(job)
        #expect(record.progress == 0.9)

        try context.save()
        let fetched = try context.fetch(FetchDescriptor<RemoteContentJobRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.jobID == job.jobId)
    }

    @Test("SwiftData store created before V10 migrates when the new model is added")
    @MainActor
    func schemaUpgradeCompatibility() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("legacy.store")

        // Legacy container: no RemoteContentJobRecord.
        do {
            let legacySchema = Schema([EpisodeRecord.self])
            let legacy = try ModelContainer(
                for: legacySchema,
                configurations: ModelConfiguration(url: storeURL)
            )
            let episode = EpisodeRecord(
                showTitle: "Legacy Show",
                episodeTitle: "Legacy Episode",
                episodeGUID: "legacy-1",
                enclosureURL: "https://example.com/a.mp3",
                status: "completed",
                pipelineStep: "completed"
            )
            legacy.mainContext.insert(episode)
            try legacy.mainContext.save()
        }

        // V10 container adds RemoteContentJobRecord; old rows must survive.
        let upgraded = try ModelContainer(
            for: Schema([EpisodeRecord.self, RemoteContentJobRecord.self]),
            configurations: ModelConfiguration(url: storeURL)
        )
        let episodes = try upgraded.mainContext.fetch(FetchDescriptor<EpisodeRecord>())
        #expect(episodes.count == 1)
        #expect(episodes.first?.status == "completed")

        // Absence of a remote record means legacy local content (WP9 rule).
        let remotes = try upgraded.mainContext.fetch(FetchDescriptor<RemoteContentJobRecord>())
        #expect(remotes.isEmpty)
    }

    @Test("podcast projection maps cloud stages onto existing display vocabulary")
    func podcastProjection() throws {
        let ready = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-ready-podcast.json")
        )
        #expect(CloudPodcastProjectionPolicy.project(ready).pipelineStep == "completed")
        #expect(CloudPodcastProjectionPolicy.project(ready).status == "completed")

        let transcribing = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-running-transcribing.json")
        )
        #expect(CloudPodcastProjectionPolicy.project(transcribing).pipelineStep == "transcribe")

        let failed = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-failed-retryable.json")
        )
        let projection = CloudPodcastProjectionPolicy.project(failed)
        #expect(projection.status == "failed")
        #expect(projection.errorMessage?.contains("SOURCE_RATE_LIMITED") == true)
    }

    @Test("video projection maps cloud job states onto YTVideoRecord display fields")
    func videoProjection() throws {
        let queued = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-queued.json")
        )
        let queuedProjection = CloudYTProjectionPolicy.project(queued)
        #expect(queuedProjection.subtitleStatus == "generating")
        #expect(queuedProjection.sourceGenerationStep == "queued")
        #expect(queuedProjection.sourceGenerationProgress == 0)

        let transcribing = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-running-transcribing.json")
        )
        let runningProjection = CloudYTProjectionPolicy.project(transcribing)
        #expect(runningProjection.subtitleStatus == "generating")
        #expect(runningProjection.sourceGenerationStep == "transcribing")
        #expect(runningProjection.sourceGenerationProgress == 0.48)

        let ready = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-ready-video.json")
        )
        let readyProjection = CloudYTProjectionPolicy.project(ready)
        #expect(readyProjection.subtitleStatus == "ready")
        #expect(readyProjection.sourceGenerationStep == "completed")
        #expect(readyProjection.sourceGenerationProgress == 1)

        let failed = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-failed-retryable.json")
        )
        let failedProjection = CloudYTProjectionPolicy.project(failed)
        #expect(failedProjection.subtitleStatus == "failed")
        #expect(failedProjection.sourceGenerationStep == "fetching_audio")
        #expect(failed.error?.code == "SOURCE_RATE_LIMITED")

        let expired = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-expired.json")
        )
        let expiredProjection = CloudYTProjectionPolicy.project(expired)
        #expect(expiredProjection.subtitleStatus == "failed")
        #expect(expiredProjection.sourceGenerationStep == "expired")

        let cancelled = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-cancelled.json")
        )
        let cancelledProjection = CloudYTProjectionPolicy.project(cancelled)
        #expect(cancelledProjection.subtitleStatus == "not_requested")
        #expect(cancelledProjection.sourceGenerationStep == nil)
        #expect(cancelledProjection.sourceGenerationProgress == nil)

        let unknown = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-unknown-enum.json")
        )
        let unknownProjection = CloudYTProjectionPolicy.project(unknown)
        #expect(unknownProjection.subtitleStatus == "generating")
        #expect(unknownProjection.sourceGenerationStep == "aligning_words")
    }

    @Test("job stable key matches the persisted record identity for restart recovery")
    func stableKeyRecoveryIdentity() throws {
        let job = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-running-transcribing.json")
        )
        // The response-derived stable key must equal the record identity built
        // from the same variant fields; this is what lets a relaunched app
        // re-attach to the persisted RemoteContentJobRecord after an idempotent
        // re-submit returns the same server job.
        #expect(job.stableKey == RemoteContentJobRecord.makeStableKey(
            contentKind: "podcast_episode",
            contentKey: job.contentKey,
            targetLanguage: job.targetLanguage,
            translationQuality: job.translationQuality.rawValue,
            pipelineVersion: job.pipelineVersion
        ))
        #expect(!job.status.isTerminal)

        // A ready terminal update for the same variant keeps the same identity,
        // so recovery after restart converges on one record per variant.
        let ready = try Self.decoder().decode(
            CloudContentJobResponse.self, from: Self.fixture("job-ready-podcast.json")
        )
        #expect(ready.stableKey == job.stableKey)
        #expect(ready.status.isTerminal)
    }

    @Test("error presentation categories are stable")
    func errorCategories() {
        #expect(CloudErrorPresentationPolicy.category(forCode: "PIPELINE_VERSION_UNSUPPORTED") == .needsUpgrade)
        #expect(CloudErrorPresentationPolicy.category(forCode: "SOURCE_RATE_LIMITED") == .rateLimited)
        #expect(CloudErrorPresentationPolicy.category(forCode: "ASR_SUBMISSION_UNCERTAIN") == .fatalFailure)
        #expect(CloudErrorPresentationPolicy.category(forCode: "SOME_FUTURE_CODE") == .unknown)
    }
}
