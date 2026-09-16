#if canImport(PodcastEnglishStudio) && os(iOS)
import XCTest
import DomainModels
import CloudSyncKit
@testable import PodcastEnglishStudio

final class FakeAssistantV2Gateway: AssistantV2Gatewaying, @unchecked Sendable {
    var researches: [AssistantV2Research] = []
    var snapshot: AssistantV2ResearchSnapshot?
    var memory: AssistantV2MemorySnapshot?
    var transcriptionRequests: [(sourceId: String, request: AssistantV2TranscriptionCreateRequest)] = []
    var confirmedProposals: [String] = []
    var rejectedProposals: [String] = []
    var createdTurns: [AssistantV2TurnCreateRequest] = []
    var artifactBodies: [String: AssistantV2ArtifactBody] = [:]
    var listError: AssistantGatewayError?
    var createError: AssistantGatewayError?
    var transcriptionResult: AssistantV2TranscriptJob?
    var transcriptJobsList: [AssistantV2TranscriptJob] = []

    func createResearch(_ request: AssistantV2ResearchCreateRequest, idempotencyKey: String?) async throws -> AssistantV2Research {
        if let createError { throw createError }
        let research = try Self.decodeResearch()
        researches.insert(research, at: 0)
        return research
    }

    func listResearches(cursor: String?, limit: Int) async throws -> AssistantV2ResearchListResponse {
        if let listError { throw listError }
        return try Self.roundTrip(ResearchListBox(researches: researches), as: AssistantV2ResearchListResponse.self)
    }

    func getResearch(id: String) async throws -> AssistantV2ResearchSnapshot {
        if let snapshot { return snapshot }
        return try Self.decodeSnapshot()
    }

    func deleteResearch(id: String, idempotencyKey: String?) async throws -> AssistantV2Research? {
        researches.removeAll { $0.researchId == id }
        return nil
    }

    func createTurn(researchId: String, request: AssistantV2TurnCreateRequest, idempotencyKey: String?) async throws -> AssistantV2TurnAcceptedResponse {
        createdTurns.append(request)
        return try JSONDecoder.assistantV2Test.decode(
            AssistantV2TurnAcceptedResponse.self,
            from: try Self.fixture("turn-accepted-research.json")
        )
    }

    func cancelTurn(id: String, idempotencyKey: String?) async throws -> AssistantV2TurnSummary {
        try JSONDecoder.assistantV2Test.decode(
            AssistantV2TurnSummary.self,
            from: Data("""
            {"turnId":"\(id)","researchId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","mode":"research","status":"cancelled","createdAt":"2026-09-03T01:00:00Z"}
            """.utf8)
        )
    }

    func listArtifacts(
        researchId: String,
        kind: AssistantV2ArtifactKind?,
        status: AssistantV2ArtifactStatus?,
        cursor: String?,
        limit: Int
    ) async throws -> AssistantV2ArtifactListResponse {
        try JSONDecoder.assistantV2Test.decode(
            AssistantV2ArtifactListResponse.self,
            from: try Self.fixture("artifact-list.json")
        )
    }

    func getArtifact(researchId: String, artifactId: String) async throws -> AssistantV2ArtifactBody {
        if let body = artifactBodies[artifactId] { return body }
        throw AssistantGatewayError.http(status: 404, server: nil)
    }

    func requestTranscription(
        researchId: String,
        sourceId: String,
        request: AssistantV2TranscriptionCreateRequest,
        idempotencyKey: String?
    ) async throws -> AssistantV2TranscriptJob {
        transcriptionRequests.append((sourceId, request))
        if let transcriptionResult { return transcriptionResult }
        return try Self.decodeJob()
    }

    func getTranscription(researchId: String, jobId: String) async throws -> AssistantV2TranscriptJob {
        try transcriptionResult ?? Self.decodeJob()
    }

    func listTranscriptions(researchId: String) async throws -> [AssistantV2TranscriptJob] {
        transcriptJobsList
    }

    func getMemory(researchId: String) async throws -> AssistantV2MemorySnapshot {
        if let memory { return memory }
        if let snapshotMemory = snapshot?.memory { return snapshotMemory }
        return try JSONDecoder.assistantV2Test.decode(
            AssistantV2MemorySnapshot.self,
            from: try Self.fixture("memory-snapshot.json")
        )
    }

    func confirmMemoryProposal(id: String, idempotencyKey: String?) async throws -> AssistantV2MemoryEntry {
        confirmedProposals.append(id)
        return try JSONDecoder.assistantV2Test.decode(
            AssistantV2MemoryEntry.self,
            from: try Self.fixture("memory-proposal-confirmed.json")
        )
    }

    func rejectMemoryProposal(id: String, idempotencyKey: String?) async throws -> AssistantV2MemoryProposal {
        rejectedProposals.append(id)
        return try JSONDecoder.assistantV2Test.decode(
            AssistantV2MemoryProposal.self,
            from: Data("""
            {"proposalId":"\(id)","researchId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","content":"rejected","reason":"user","status":"rejected","createdAt":"2026-09-03T01:08:00Z","expiresAt":"2026-09-10T01:00:00Z"}
            """.utf8)
        )
    }

    private struct ResearchListBox: Encodable {
        var researches: [AssistantV2Research]
    }

    private static func roundTrip<Encoded: Encodable, Decoded: Decodable>(
        _ value: Encoded,
        as type: Decoded.Type
    ) throws -> Decoded {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder.assistantV2Test.decode(type, from: encoder.encode(value))
    }

    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AssistantV2/\(name)")
        return try Data(contentsOf: url)
    }

    private static func decodeResearch() throws -> AssistantV2Research {
        try JSONDecoder.assistantV2Test.decode(AssistantV2ResearchListResponse.self, from: try fixture("research-list.json")).researches[0]
    }

    private static func decodeSnapshot() throws -> AssistantV2ResearchSnapshot {
        try JSONDecoder.assistantV2Test.decode(AssistantV2ResearchSnapshot.self, from: try fixture("research-snapshot-happy.json"))
    }

    private static func decodeJob() throws -> AssistantV2TranscriptJob {
        try JSONDecoder.assistantV2Test.decode(AssistantV2TranscriptJob.self, from: try fixture("transcript-job-ready.json"))
    }
}

private extension JSONDecoder {
    static var assistantV2Test: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: value)
        }
        return decoder
    }
}

final class AssistantV2ViewModelTests: XCTestCase {
    func testUnknownEventsRefreshSnapshot() {
        XCTAssertTrue(AssistantV2ViewModel.shouldRefreshSnapshot(for: .unknown("agent.thought")))
        XCTAssertTrue(AssistantV2SseEventType.unknown("agent.thought").shouldRefreshSnapshot)
        XCTAssertFalse(AssistantV2ViewModel.shouldRefreshSnapshot(for: .reportDelta))
        XCTAssertFalse(AssistantV2ViewModel.shouldRefreshSnapshot(for: .heartbeat))
        XCTAssertTrue(AssistantV2ViewModel.shouldRefreshSnapshot(for: .reportCompleted))
        XCTAssertTrue(AssistantV2ViewModel.shouldRefreshSnapshot(for: .sourceSaved))
        XCTAssertTrue(AssistantV2ViewModel.shouldRefreshSnapshot(for: .turnCompleted))
    }

    func testCursorExpiredRecoveryRefreshesSnapshot() {
        let error = AssistantGatewayError.http(
            status: 409,
            server: AssistantErrorBody(
                code: "EVENT_CURSOR_EXPIRED",
                message: "replay window elapsed",
                retryable: false,
                traceId: "t"
            )
        )
        XCTAssertEqual(AssistantV2StreamRecovery.action(for: error), .refreshSnapshot)
        XCTAssertTrue(error.shouldRefreshSnapshot)
    }

    func testParsesAssistantSourceIdsFromSearchArtifact() {
        let text = """
        {"platform":"youtube","results":[{"sourceId":"dQw4w9WgXcQ","assistantSourceId":"so_01ARZ3NDEKTSV4RRFFQ69G5FAV","canonicalURL":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","title":"Demo"}]}
        """
        let hits = AssistantV2ViewModel.parseSearchHits(from: text, fallbackPlatform: "youtube")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].transcribeSourceId, "so_01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertTrue(AssistantV2ViewModel.isAssistantSourceId("so_01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        XCTAssertFalse(AssistantV2ViewModel.isAssistantSourceId("dQw4w9WgXcQ"))
        XCTAssertFalse(AssistantV2ViewModel.isAssistantSourceId("/tmp/research"))
    }

    func testPodcastShowsWithoutEnclosureCannotTranscribe() {
        let episodeText = """
        {"platform":"podcast","results":[{"sourceId":"ep-1","assistantSourceId":"so_01ARZ3NDEKTSV4RRFFQ69G5FAV","canonicalURL":"https://podcasts.apple.com/episode/id9","title":"Episode 9","enclosureUrl":"https://cdn.example.test/9.mp3"}]}
        """
        let showText = """
        {"platform":"podcast","results":[{"sourceId":"show-1","assistantSourceId":"so_01ARZ3NDEKTSV4RRFFQ69G5FB0","canonicalURL":"https://podcasts.apple.com/show/id1","title":"Show"}]}
        """
        let episodeHits = AssistantV2ViewModel.parseSearchHits(from: episodeText, fallbackPlatform: "podcast")
        let showHits = AssistantV2ViewModel.parseSearchHits(from: showText, fallbackPlatform: "podcast")
        let episodeRows = AssistantV2ViewModel.displayedSources(artifacts: [], hits: episodeHits)
        let showRows = AssistantV2ViewModel.displayedSources(artifacts: [], hits: showHits)
        XCTAssertEqual(episodeHits[0].enclosureUrl, "https://cdn.example.test/9.mp3")
        XCTAssertTrue(episodeRows[0].canTranscribe)
        XCTAssertFalse(showRows[0].canTranscribe)
    }

    func testDisplayedSourcesNeverExposeFilesystemPaths() throws {
        let snapshot = try JSONDecoder.assistantV2Test.decode(
            AssistantV2ResearchSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/research-snapshot-happy.json"))
        )
        let rows = AssistantV2ViewModel.displayedSources(artifacts: snapshot.artifacts, hits: [])
        for row in rows {
            XCTAssertFalse(row.title.contains("/var/"))
            XCTAssertFalse(row.title.contains("/tmp/"))
            XCTAssertFalse((row.canonicalURL ?? "").contains("file://"))
            XCTAssertNil(row.transcribeSourceId)
        }
    }

    @MainActor
    func testListCreateAndOpenResearch() async throws {
        let gateway = FakeAssistantV2Gateway()
        gateway.snapshot = try JSONDecoder.assistantV2Test.decode(
            AssistantV2ResearchSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/research-snapshot-happy.json"))
        )
        gateway.researches = [try JSONDecoder.assistantV2Test.decode(
            AssistantV2ResearchListResponse.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/research-list.json"))
        ).researches[0]]
        let model = AssistantV2ViewModel(gateway: gateway)
        await model.refreshList()
        XCTAssertEqual(model.researches.count, 1)
        let created = await model.createResearch(outputLanguage: "zh-Hans", targetLanguage: "zh-Hans", quality: .quality)
        XCTAssertEqual(created, gateway.researches[0].researchId)
        await model.openResearch(gateway.researches[0].researchId)
        XCTAssertEqual(model.snapshot?.title, "AI and accounting")
        XCTAssertEqual(model.pendingMemoryProposals.count, 1)
    }

    @MainActor
    func testTranscriptionSendsConfirmedWithoutClientToken() async throws {
        let gateway = FakeAssistantV2Gateway()
        gateway.snapshot = try JSONDecoder.assistantV2Test.decode(
            AssistantV2ResearchSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/research-snapshot-happy.json"))
        )
        gateway.transcriptionResult = try JSONDecoder.assistantV2Test.decode(
            AssistantV2TranscriptJob.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/transcript-job-ready.json"))
        )
        let model = AssistantV2ViewModel(gateway: gateway)
        await model.openResearch(gateway.snapshot!.researchId)
        await model.confirmTranscription(sourceId: "so_01ARZ3NDEKTSV4RRFFQ69G5FAV", targetLanguage: "zh-Hans", quality: .quality)
        XCTAssertEqual(gateway.transcriptionRequests.count, 1)
        XCTAssertEqual(gateway.transcriptionRequests[0].sourceId, "so_01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertTrue(gateway.transcriptionRequests[0].request.confirmed)
        XCTAssertEqual(model.transcriptJobs["so_01ARZ3NDEKTSV4RRFFQ69G5FAV"]?.status, .ready)
    }

    @MainActor
    func testOpenResearchReconcilesTranscriptJobsFromTheServer() async throws {
        let gateway = FakeAssistantV2Gateway()
        gateway.snapshot = try JSONDecoder.assistantV2Test.decode(
            AssistantV2ResearchSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/research-snapshot-happy.json"))
        )
        let job = try JSONDecoder.assistantV2Test.decode(
            AssistantV2TranscriptJob.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/transcript-job-ready.json"))
        )
        gateway.transcriptJobsList = [job]
        let model = AssistantV2ViewModel(gateway: gateway)
        // No confirmTranscription call here: this exercises reopening a research picking up a
        // transcription that was already started (e.g. from a previous app launch), not one this
        // ViewModel instance kicked off itself.
        await model.openResearch(gateway.snapshot!.researchId)
        XCTAssertEqual(model.transcriptJobs[job.sourceId]?.status, .ready)
    }

    @MainActor
    func testMemoryConfirmAndReject() async throws {
        let gateway = FakeAssistantV2Gateway()
        gateway.snapshot = try JSONDecoder.assistantV2Test.decode(
            AssistantV2ResearchSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/research-snapshot-happy.json"))
        )
        let model = AssistantV2ViewModel(gateway: gateway)
        await model.openResearch(gateway.snapshot!.researchId)
        await model.confirmMemoryProposal("mp_01ARZ3NDEKTSV4RRFFQ69G5FH0")
        await model.rejectMemoryProposal("mp_other")
        XCTAssertEqual(gateway.confirmedProposals, ["mp_01ARZ3NDEKTSV4RRFFQ69G5FH0"])
        XCTAssertEqual(gateway.rejectedProposals, ["mp_other"])
    }

    @MainActor
    func testV2DisabledErrorIsDescribed() {
        let error = AssistantGatewayError.http(
            status: 503,
            server: AssistantErrorBody(code: "ASSISTANT_V2_DISABLED", message: "off", retryable: false, traceId: "t")
        )
        XCTAssertEqual(
            AssistantV2ViewModel.describe(error),
            "V15 research is turned off on the server."
        )
    }

    @MainActor
    func testQuotaExceededErrorIsDescribed() throws {
        let data = Data(#"{"code":"QUOTA_EXCEEDED","message":"daily limit","retryable":false,"retryAfterSeconds":3600,"params":{"kind":"assistant","limit":20,"remaining":0}}"#.utf8)
        let body = try JSONDecoder().decode(AssistantErrorBody.self, from: data)
        XCTAssertEqual(body.params?["limit"], "20")
        XCTAssertEqual(
            AssistantV2ViewModel.describe(.http(status: 429, server: body)),
            "You've used today's free assistant turns. They reset at midnight China Standard Time."
        )
    }

    // MARK: - Turn work (thinking cards + tool rows)

    private struct SSEFixtureEnvelope: Decodable {
        struct Entry: Decodable {
            var id: String
            var event: String
            var data: AssistantV2SseEventData
        }
        var events: [Entry]
    }

    private static func loadSSEFixtureEvents(_ name: String) throws -> [(type: AssistantV2SseEventType, data: AssistantV2SseEventData)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AssistantV2/\(name)")
        let envelope = try JSONDecoder.assistantV2Test.decode(SSEFixtureEnvelope.self, from: try Data(contentsOf: url))
        return envelope.events.map { (AssistantV2SseEventType(rawValue: $0.event), $0.data) }
    }

    func testReduceTurnWorkFoldsLiveSSEEventsLikeTheServerProjection() throws {
        let events = try Self.loadSSEFixtureEvents("sse-turn-work-events.json")
        var work: AssistantV2TurnWork?
        for (type, data) in events {
            switch type {
            case .thinkingStarted, .thinkingDelta, .thinkingCompleted, .toolStarted, .toolCompleted:
                work = AssistantV2ViewModel.reduceTurnWork(work, turnId: data.turnId, type: type, payload: data.payload)
            default:
                continue
            }
        }
        let final = try XCTUnwrap(work)
        XCTAssertEqual(final.turnId, "vt_01ARZ3NDEKTSV4RRFFQ69G5FB0")
        // A second thinking block starting after the first already completed doesn't reset the
        // fold back to "streaming" (matching services/research-assistant's projectTurnWork), so
        // the second block's redacted completion is what the turn ends up showing.
        XCTAssertEqual(final.thinking?.status, "redacted")
        XCTAssertEqual(final.thinking?.redacted, true)
        XCTAssertEqual(final.thinking?.text, "")
        XCTAssertEqual(final.thinking?.durationMs, 3000)
        XCTAssertEqual(final.tools.count, 2)
        XCTAssertEqual(final.tools[0].callId, "call_1")
        XCTAssertEqual(final.tools[0].tool, "search_youtube")
        XCTAssertEqual(final.tools[0].status, "completed")
        XCTAssertEqual(final.tools[0].query, "AI accounting for firms")
        XCTAssertEqual(final.tools[1].callId, "call_2")
        XCTAssertEqual(final.tools[1].tool, "retrieve_evidence")
        XCTAssertEqual(final.tools[1].status, "failed")
        XCTAssertNil(final.tools[1].query)
    }

    func testReduceTurnWorkTruncatesFoldedThinkingTextAt4096Characters() throws {
        let chunk = String(repeating: "x", count: 512)
        var work: AssistantV2TurnWork? = AssistantV2ViewModel.reduceTurnWork(
            nil, turnId: "vt_a", type: .thinkingStarted, payload: ["blockId": .string("th_0")]
        )
        for _ in 0..<10 {
            work = AssistantV2ViewModel.reduceTurnWork(
                work, turnId: "vt_a", type: .thinkingDelta,
                payload: ["blockId": .string("th_0"), "text": .string(chunk)]
            )
        }
        work = AssistantV2ViewModel.reduceTurnWork(
            work, turnId: "vt_a", type: .thinkingCompleted,
            payload: ["blockId": .string("th_0"), "durationMs": .number(9000)]
        )
        let final = try XCTUnwrap(work)
        XCTAssertEqual(final.thinking?.text?.count, 4096)
        XCTAssertEqual(final.thinking?.truncated, true)
        XCTAssertEqual(final.thinking?.durationMs, 9000)
        XCTAssertEqual(final.thinking?.redacted, false)
    }

    @MainActor
    func testOpenResearchSeedsTurnWorkFromTheSnapshotForFinishedTurns() async throws {
        let gateway = FakeAssistantV2Gateway()
        gateway.snapshot = try JSONDecoder.assistantV2Test.decode(
            AssistantV2ResearchSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/AssistantV2/research-snapshot-happy.json"))
        )
        let model = AssistantV2ViewModel(gateway: gateway)
        await model.openResearch(gateway.snapshot!.researchId)
        let work = try XCTUnwrap(model.turnWork["vt_01ARZ3NDEKTSV4RRFFQ69G5FB0"])
        XCTAssertFalse(work.isRunning)
        XCTAssertEqual(work.thinking?.status, "done")
        XCTAssertEqual(work.tools.map(\.labelKey), ["search_youtube", "retrieve_evidence"])
        XCTAssertEqual(work.tools[0].status, "completed")
        XCTAssertEqual(work.tools[1].status, "failed")
    }

    func testToolLabelIsAHumanSentenceNeverTheRawFunctionName() {
        XCTAssertEqual(AssistantV2ViewModel.toolLabel(for: "search_youtube"), "Searching YouTube")
        XCTAssertEqual(AssistantV2ViewModel.toolLabel(for: "fetch_web_page"), "Opening a web page")
        XCTAssertEqual(AssistantV2ViewModel.toolLabel(for: "grep_files"), "Looking at the workspace")
        XCTAssertEqual(AssistantV2ViewModel.toolLabel(for: "retrieve_evidence"), "Gathering evidence")
        // An unrecognized (but whitelisted) tool falls back to a generic sentence instead of
        // leaking its function name into the UI.
        XCTAssertEqual(AssistantV2ViewModel.toolLabel(for: "propose_global_memory"), "Working")
    }

    func testFoldSummaryIsGenericWhileRunningRegardlessOfWorkSoFar() {
        XCTAssertEqual(AssistantV2ViewModel.foldSummary(for: nil, isRunning: true), "Work in progress")
    }

    func testFoldSummaryJoinsDistinctSearchTargetsCindyStyle() {
        let work = AssistantV2TurnWork(
            turnId: "vt_a",
            thinking: AssistantV2TurnWorkThinking(status: "done", durationMs: 12_000),
            tools: [
                AssistantV2TurnWorkTool(callId: "c1", tool: "search_youtube", labelKey: "search_youtube", status: "completed"),
                AssistantV2TurnWorkTool(callId: "c2", tool: "search_podcasts", labelKey: "search_podcasts", status: "completed"),
                AssistantV2TurnWorkTool(callId: "c3", tool: "web_search", labelKey: "web_search", status: "completed")
            ]
        )
        XCTAssertEqual(
            AssistantV2ViewModel.foldSummary(for: work, isRunning: false, locale: Locale(identifier: "en_US")),
            "Thought · Searched YouTube, podcasts, and the web"
        )
    }

    func testFoldSummaryJoinsDistinctVerbCategoriesInFixedOrder() {
        let work = AssistantV2TurnWork(
            turnId: "vt_a",
            tools: [
                AssistantV2TurnWorkTool(callId: "c1", tool: "list_files", labelKey: "list_files", status: "completed"),
                AssistantV2TurnWorkTool(callId: "c2", tool: "search_youtube", labelKey: "search_youtube", status: "completed")
            ]
        )
        XCTAssertEqual(
            AssistantV2ViewModel.foldSummary(for: work, isRunning: false, locale: Locale(identifier: "en_US")),
            "Thought · Searched YouTube and Looked at the workspace"
        )
    }

    func testFoldSummaryFallsBackToPlainThoughtWithoutCategorizedTools() {
        let work = AssistantV2TurnWork(
            turnId: "vt_a",
            thinking: AssistantV2TurnWorkThinking(status: "done", durationMs: 1_000),
            tools: [AssistantV2TurnWorkTool(callId: "c1", tool: "save_research_report", labelKey: "save_research_report", status: "completed")]
        )
        XCTAssertEqual(AssistantV2ViewModel.foldSummary(for: work, isRunning: false), "Thought")
    }
}
#endif
