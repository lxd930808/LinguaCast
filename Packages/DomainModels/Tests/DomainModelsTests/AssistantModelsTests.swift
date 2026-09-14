import Foundation
import Testing
@testable import DomainModels

@Suite("AssistantModels contract")
struct AssistantModelsTests {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/Assistant")

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

    @Test("session list and snapshot fixtures decode")
    func decodeSessionFixtures() throws {
        let created = try Self.decoder().decode(AssistantSessionSummary.self, from: Self.fixture("session-created.json"))
        #expect(created.phase == .researching)
        let list = try Self.decoder().decode(AssistantSessionListResponse.self, from: Self.fixture("session-list.json"))
        #expect(list.sessions.count == 1)
        var snapshot = try Self.decoder().decode(
            AssistantSessionSnapshot.self,
            from: Self.fixture("session-snapshot-research-happy.json")
        )
        #expect(snapshot.phase == .reportReady)
        #expect(snapshot.report?.sources.isEmpty == false)
        #expect(snapshot.sourceGroups?.count == 1)
        #expect(snapshot.resolvedSourceGroups.first?.sources.count == 2)

        snapshot = try Self.decoder().decode(
            AssistantSessionSnapshot.self,
            from: Self.fixture("session-snapshot-source-groups.json")
        )
        #expect(snapshot.sourceGroups?.count == 2)
        #expect(snapshot.resolvedSourceGroups.map(\.reportId) == ["rp_accounting02", "rp_accounting01"])
        #expect(snapshot.resolvedSourceGroups[0].sources.map(\.searchResultId).contains("sr_01ARZ3NDEKTSV4RRFFQ69G5FD0"))
        #expect(snapshot.resolvedSourceGroups[1].sources.map(\.searchResultId) == ["sr_01ARZ3NDEKTSV4RRFFQ69G5FD1"])
    }

    @Test("unknown enum values decode without crashing")
    func unknownEnumTolerance() throws {
        let snapshot = try Self.decoder().decode(
            AssistantSessionSnapshot.self,
            from: Self.fixture("session-unknown-enum.json")
        )
        guard case .unknown(let phase) = snapshot.phase else {
            Issue.record("unknown phase should map to .unknown")
            return
        }
        #expect(phase == "awaiting_operator")
        guard case .unknown(let status)? = snapshot.activeTurn?.status else {
            Issue.record("unknown turn status should map to .unknown")
            return
        }
        #expect(status == "waiting_quota")
        #expect(snapshot.sourceGroups == nil)
        #expect(snapshot.resolvedSourceGroups.isEmpty)
    }

    @Test("legacy snapshot without sourceGroups falls back to the latest report")
    func legacySnapshotFallsBackToReport() throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixture("session-snapshot-research-happy.json")) as? [String: Any]
        object?.removeValue(forKey: "sourceGroups")
        let data = try JSONSerialization.data(withJSONObject: object ?? [:])
        let snapshot = try Self.decoder().decode(AssistantSessionSnapshot.self, from: data)
        #expect(snapshot.sourceGroups == nil)
        #expect(snapshot.resolvedSourceGroups.count == 1)
        #expect(snapshot.resolvedSourceGroups[0].title == "AI and accounting")
        #expect(snapshot.resolvedSourceGroups[0].sources.count == 2)
    }

    @Test("error envelope and citations decode")
    func decodeErrorsAndCitations() throws {
        let error = try Self.decoder().decode(
            AssistantErrorEnvelope.self,
            from: Self.fixture("error-envelope-transcript-not-ready.json")
        )
        #expect(error.error.code == "TRANSCRIPT_NOT_READY")
        #expect(error.error.retryable)
        let message = try Self.decoder().decode(
            AssistantMessage.self,
            from: Self.fixture("qa-answer-with-citations.json")
        )
        #expect(message.citations?.count == 1)
        #expect(message.citations?.first?.deepLink.contains("linguacast://play") == true)
    }

    @Test("V14 search run fixtures decode including podcast platform")
    func decodeSearchRunFixtures() throws {
        let run = try Self.decoder().decode(
            AssistantSearchRun.self,
            from: Self.fixture("search-run-success.json")
        )
        #expect(run.searchRunId.hasPrefix("srun_"))
        #expect(run.results?.first?.platform == .podcast)
        #expect(run.results?.first?.sourceType == .podcastEpisode)
        #expect(run.results?.first?.matchReason == "person_tag_and_episode_title")
        let partial = try Self.decoder().decode(
            AssistantSearchRun.self,
            from: Self.fixture("search-run-partial.json")
        )
        #expect(partial.providerStatus?.contains(where: { $0.status != "success" }) == true)
        let list = try Self.decoder().decode(
            AssistantSearchRunListResponse.self,
            from: Self.fixture("search-run-list.json")
        )
        #expect(list.runs.isEmpty == false)
        let error = try Self.decoder().decode(
            AssistantErrorEnvelope.self,
            from: Self.fixture("error-envelope-search-run-not-found.json")
        )
        #expect(error.error.code == "SEARCH_RUN_NOT_FOUND")
    }

    @Test("youtube fallback and podcast RSS fixtures decode")
    func decodeSearchFixtures() throws {
        let youtube = try Self.decoder().decode(
            AssistantSearchResultListResponse.self,
            from: Self.fixture("search-results-youtube-fallback.json")
        )
        #expect(youtube.results.first?.fallback == true)
        let podcasts = try Self.decoder().decode(
            AssistantSearchResultListResponse.self,
            from: Self.fixture("search-results-podcast-rss.json")
        )
        #expect(podcasts.results.contains(where: { $0.sourceType == .podcastEpisode }))
        let episode = try #require(podcasts.results.first { $0.sourceType == .podcastEpisode })
        #expect(episode.enclosureUrl == "https://cdn.example.com/ai-ledger.mp3")
        #expect(episode.playbackAudioURL == "https://cdn.example.com/ai-ledger.mp3")
        #expect(episode.canonicalURL.contains("podcasts.apple.com"))
    }

    @Test("source card phase matches binding by searchResultId and V10 status")
    func sourceCardPhase() {
        let idle = AssistantSourceCardPolicy.phase(searchResultId: "sr_1", binding: nil)
        #expect(idle == .idle)

        let other = AssistantSourceCardPolicy.phase(
            searchResultId: "sr_1",
            binding: makeBinding(searchResultId: "sr_other", status: "running")
        )
        #expect(other == .idle)

        let preparing = AssistantSourceCardPolicy.phase(
            searchResultId: "sr_1",
            binding: makeBinding(status: "running", stage: "translating")
        )
        #expect(preparing == .preparing)

        let readyByStatus = AssistantSourceCardPolicy.phase(
            searchResultId: "sr_1",
            binding: makeBinding(status: "ready", stage: "packaging", indexStatus: "pending")
        )
        #expect(readyByStatus == .ready)

        let readyByStage = AssistantSourceCardPolicy.phase(
            searchResultId: "sr_1",
            binding: makeBinding(status: "running", stage: "completed", indexStatus: "pending")
        )
        #expect(readyByStage == .ready)

        let failed = AssistantSourceCardPolicy.phase(
            searchResultId: "sr_1",
            binding: makeBinding(status: "failed", error: AssistantErrorBody(
                code: "V10_FAILED",
                message: "boom",
                retryable: true,
                traceId: "t"
            ))
        )
        #expect(failed == .failed)
    }

    private func makeBinding(
        searchResultId: String = "sr_1",
        status: String = "running",
        stage: String? = "transcribing",
        indexStatus: String = "pending",
        error: AssistantErrorBody? = nil
    ) -> AssistantContentBinding {
        AssistantContentBinding(
            bindingId: "b1",
            sessionId: "s1",
            searchResultId: searchResultId,
            contentKey: "video:youtube:abc",
            contentType: .video,
            targetLanguage: "zh-Hans",
            translationQuality: .quality,
            v10JobId: "job1",
            status: status,
            stage: stage,
            progress: 0.4,
            indexStatus: indexStatus,
            error: error,
            reused: nil,
            updatedAt: nil
        )
    }
}
