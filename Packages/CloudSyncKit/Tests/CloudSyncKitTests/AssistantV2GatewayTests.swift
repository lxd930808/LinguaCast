import Foundation
import XCTest
@testable import CloudSyncKit
import DomainModels

final class AssistantV2GatewayTests: XCTestCase {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/AssistantV2")

    func fixture(_ name: String) -> Data {
        let url = Self.fixturesDir.appendingPathComponent(name)
        return (try? Data(contentsOf: url)) ?? Data()
    }

    override func setUp() {
        super.setUp()
        ScriptedURLProtocol.reset()
    }

    func makeClient() -> AssistantV2Gateway {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return try! AssistantV2Gateway.makeDefault(
            baseURLString: "https://assistant.example.com/",
            tokenProvider: StaticAssistantTokenProvider(token: "assistant-token"),
            session: session,
            clientVersion: "ios-tests/1"
        )
    }

    func testCreateResearchSendsBearerIdempotencyAndV2Path() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "https://assistant.example.com".split(separator: "/").last.map(String.init) ?? request.url?.host)
            XCTAssertEqual(request.url?.host, "assistant.example.com")
            XCTAssertEqual(request.url?.path, "/v2/assistant/researches")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer assistant-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-create")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Version"), "ios-tests/1")
            XCTAssertFalse((request.value(forHTTPHeaderField: "X-Request-ID") ?? "").isEmpty)
            XCTAssertNil(request.url?.query)
            return (201, self.fixture("research-created.json"), [:])
        }
        let research = try await makeClient().createResearch(
            AssistantV2ResearchCreateRequest(title: "AI and accounting", sharedAliases: ["notes"]),
            idempotencyKey: "idem-create"
        )
        XCTAssertEqual(research.status, .ready)
        XCTAssertEqual(research.grants?.first?.alias, "notes")
    }

    func testListAndGetResearchUseV2Paths() async throws {
        ScriptedURLProtocol.handler = { request in
            if request.url?.path == "/v2/assistant/researches" {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertTrue(request.url?.query?.contains("limit=20") == true)
                return (200, self.fixture("research-list.json"), [:])
            }
            XCTAssertEqual(request.url?.path, "/v2/assistant/researches/01ARZ3NDEKTSV4RRFFQ69G5FAV")
            return (200, self.fixture("research-snapshot-happy.json"), [:])
        }
        let list = try await makeClient().listResearches()
        XCTAssertEqual(list.researches.count, 1)
        let snapshot = try await makeClient().getResearch(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertEqual(snapshot.artifacts.count, 6)
        XCTAssertFalse(snapshot.artifacts.contains(where: \.artifactId.isEmpty))
    }

    func testCreateTurnAndCancelSendIdempotencyKeys() async throws {
        ScriptedURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/turns") == true {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/v2/assistant/researches/01ARZ3NDEKTSV4RRFFQ69G5FAV/turns")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-turn")
                return (202, self.fixture("turn-accepted-research.json"), [:])
            }
            XCTAssertEqual(request.url?.path, "/v2/assistant/turns/vt_01ARZ3NDEKTSV4RRFFQ69G5FB0/cancel")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-cancel")
            let body = """
            {
              "turnId": "vt_01ARZ3NDEKTSV4RRFFQ69G5FB0",
              "researchId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "mode": "research",
              "status": "cancelled",
              "createdAt": "2026-09-03T01:00:00Z"
            }
            """.data(using: .utf8)!
            return (200, body, [:])
        }
        let accepted = try await makeClient().createTurn(
            researchId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            request: AssistantV2TurnCreateRequest(message: "Research AI", mode: .research),
            idempotencyKey: "idem-turn"
        )
        XCTAssertEqual(accepted.eventsURL, "/v2/assistant/turns/vt_01ARZ3NDEKTSV4RRFFQ69G5FB0/events")
        let cancelled = try await makeClient().cancelTurn(
            id: "vt_01ARZ3NDEKTSV4RRFFQ69G5FB0",
            idempotencyKey: "idem-cancel"
        )
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testArtifactRoutesUseIdsNeverPaths() async throws {
        ScriptedURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/artifacts") == true {
                XCTAssertEqual(
                    request.url?.path,
                    "/v2/assistant/researches/01ARZ3NDEKTSV4RRFFQ69G5FAV/artifacts"
                )
                let query = request.url?.query ?? ""
                XCTAssertTrue(query.contains("kind=web_page"))
                XCTAssertTrue(query.contains("status=ready"))
                XCTAssertFalse(query.contains("path="))
                XCTAssertFalse(query.contains("uri="))
                return (200, self.fixture("artifact-list.json"), [:])
            }
            XCTAssertEqual(
                request.url?.path,
                "/v2/assistant/researches/01ARZ3NDEKTSV4RRFFQ69G5FAV/artifacts/01ARZ3NDEKTSV4RRFFQ69G5FD0"
            )
            return (200, self.fixture("artifact-body-web-page.json"), [:])
        }
        let list = try await makeClient().listArtifacts(
            researchId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            kind: .webPage,
            status: .ready
        )
        XCTAssertEqual(list.artifacts.first?.kind, .webPage)
        let body = try await makeClient().getArtifact(
            researchId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            artifactId: "01ARZ3NDEKTSV4RRFFQ69G5FD0"
        )
        XCTAssertEqual(body.encoding, .utf8)
    }

    func testTranscriptionAndMemoryRoutes() async throws {
        ScriptedURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/transcription") && request.httpMethod == "POST" {
                XCTAssertEqual(
                    path,
                    "/v2/assistant/researches/01ARZ3NDEKTSV4RRFFQ69G5FAV/sources/so_01ARZ3NDEKTSV4RRFFQ69G5FE0/transcription"
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-tx")
                return (202, self.fixture("transcript-job-ready.json"), [:])
            }
            if path.contains("/transcriptions/") {
                return (200, self.fixture("transcript-job-ready.json"), [:])
            }
            if path.hasSuffix("/memory") {
                return (200, self.fixture("memory-snapshot.json"), [:])
            }
            if path.hasSuffix("/confirm") {
                XCTAssertEqual(path, "/v2/assistant/memory-proposals/mp_01ARZ3NDEKTSV4RRFFQ69G5FH0/confirm")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-confirm")
                return (200, self.fixture("memory-proposal-confirmed.json"), [:])
            }
            if path.hasSuffix("/reject") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-reject")
                return (200, Data("""
                {
                  "proposalId": "mp_01ARZ3NDEKTSV4RRFFQ69G5FH0",
                  "researchId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                  "content": "Write future reports in Simplified Chinese by default.",
                  "reason": "User asked for Chinese output in this research.",
                  "status": "rejected",
                  "createdAt": "2026-09-03T01:08:00Z",
                  "expiresAt": "2026-09-10T01:00:00Z",
                  "confirmedAt": null,
                  "rejectedAt": "2026-09-03T01:09:00Z",
                  "memoryEntryId": null
                }
                """.utf8), [:])
            }
            return (404, Data(), [:])
        }
        let job = try await makeClient().requestTranscription(
            researchId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            sourceId: "so_01ARZ3NDEKTSV4RRFFQ69G5FE0",
            request: AssistantV2TranscriptionCreateRequest(
                targetLanguage: "zh-Hans",
                translationQuality: .quality
            ),
            idempotencyKey: "idem-tx"
        )
        XCTAssertEqual(job.status, .ready)
        let fetched = try await makeClient().getTranscription(
            researchId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            jobId: "tj_01ARZ3NDEKTSV4RRFFQ69G5FG0"
        )
        XCTAssertEqual(fetched.transcriptJobId, job.transcriptJobId)
        let memory = try await makeClient().getMemory(researchId: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertEqual(memory.proposals.count, 1)
        let confirmed = try await makeClient().confirmMemoryProposal(
            id: "mp_01ARZ3NDEKTSV4RRFFQ69G5FH0",
            idempotencyKey: "idem-confirm"
        )
        XCTAssertEqual(confirmed.scope, .global)
        let rejected = try await makeClient().rejectMemoryProposal(
            id: "mp_01ARZ3NDEKTSV4RRFFQ69G5FH0",
            idempotencyKey: "idem-reject"
        )
        XCTAssertEqual(rejected.status, .rejected)
    }

    func testV2ErrorMappingForDisabledIdempotencyAndCursor() async {
        ScriptedURLProtocol.handler = { _ in
            (503, Data("""
            {"error":{"code":"ASSISTANT_V2_DISABLED","message":"V2 is off","retryable":false,"traceId":"tr_1"}}
            """.utf8), [:])
        }
        do {
            _ = try await makeClient().listResearches()
            XCTFail("expected 503")
        } catch let error as AssistantGatewayError {
            XCTAssertEqual(error.v2Code, .assistantV2Disabled)
            XCTAssertFalse(error.shouldRefreshSnapshot)
        } catch {
            XCTFail("unexpected \(error)")
        }

        ScriptedURLProtocol.handler = { _ in (409, self.fixture("error-envelope-idempotency-conflict.json"), [:]) }
        do {
            _ = try await makeClient().createResearch(AssistantV2ResearchCreateRequest(), idempotencyKey: "x")
            XCTFail("expected 409")
        } catch let error as AssistantGatewayError {
            XCTAssertEqual(error.v2Code, .idempotencyConflict)
        } catch {
            XCTFail("unexpected \(error)")
        }

        ScriptedURLProtocol.handler = { _ in (409, self.fixture("error-envelope-event-cursor-expired.json"), [:]) }
        do {
            _ = try await makeClient().getResearch(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
            XCTFail("expected cursor expired")
        } catch let error as AssistantGatewayError {
            XCTAssertEqual(error.v2Code, .eventCursorExpired)
            XCTAssertTrue(error.shouldRefreshSnapshot)
            XCTAssertEqual(AssistantV2StreamRecovery.action(for: error), .refreshSnapshot)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnauthorizedDoesNotDecodeAsSuccess() async {
        ScriptedURLProtocol.handler = { _ in (401, self.fixture("error-envelope-unauthorized.json"), [:]) }
        do {
            _ = try await makeClient().listResearches()
            XCTFail("expected 401")
        } catch let error as AssistantGatewayError {
            XCTAssertTrue(error.isUnauthorized)
            XCTAssertEqual(error.v2Code, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCorruptArtifactMapsErrorCode() async {
        ScriptedURLProtocol.handler = { _ in (409, self.fixture("error-envelope-artifact-corrupt.json"), [:]) }
        do {
            _ = try await makeClient().getArtifact(
                researchId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                artifactId: "01ARZ3NDEKTSV4RRFFQ69G5FD0"
            )
            XCTFail("expected corrupt")
        } catch let error as AssistantGatewayError {
            XCTAssertEqual(error.v2Code, .artifactCorrupt)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testDeleteResearchAcceptsEmptyBody() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-del")
            return (204, Data(), [:])
        }
        let deleted = try await makeClient().deleteResearch(
            id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            idempotencyKey: "idem-del"
        )
        XCTAssertNil(deleted)
    }

    func testEventsURLAndRelativeResolution() {
        let client = makeClient()
        let url = client.eventsURL(turnId: "vt_01ARZ3NDEKTSV4RRFFQ69G5FB0")
        XCTAssertEqual(url.path, "/v2/assistant/turns/vt_01ARZ3NDEKTSV4RRFFQ69G5FB0/events")
        let resolved = client.resolveEventsURL("/v2/assistant/turns/vt_01ARZ3NDEKTSV4RRFFQ69G5FB0/events")
        XCTAssertEqual(resolved?.path, "/v2/assistant/turns/vt_01ARZ3NDEKTSV4RRFFQ69G5FB0/events")
        XCTAssertEqual(resolved?.host, "assistant.example.com")
    }

    func testSSEParserDecodesReplayFixtureAndHeartbeat() throws {
        var parser = AssistantV2SSEParser()
        var events = parser.push(try sseText(named: "sse-replay-events.json"))
        events.append(contentsOf: parser.push("""
        event: heartbeat
        data: {"t":"2026-09-03T01:00:16Z"}

        """))
        events.append(contentsOf: parser.finish())
        XCTAssertEqual(events.first?.type, .turnStarted)
        XCTAssertEqual(events.first?.data?.schemaVersion, 2)
        XCTAssertTrue(events.contains(where: { $0.type == .workspaceCreated }))
        XCTAssertTrue(events.contains(where: { $0.type == .reportCompleted }))
        XCTAssertTrue(events.contains(where: { $0.type == .heartbeat && $0.heartbeatAt != nil }))
        if case .string(let text) = events.first(where: { $0.type == .reportDelta })?.data?.payload["text"] {
            XCTAssertEqual(text, "## Theme\n")
        } else {
            XCTFail("expected report.delta text")
        }
    }

    func testSSEParserHandlesPartialWebFailureAndUnknownEvents() throws {
        var parser = AssistantV2SSEParser()
        var events = parser.push(try sseText(named: "sse-partial-web-failed.json"))
        events.append(contentsOf: parser.push("""
        id: 99
        event: agent.thought
        data: {"schemaVersion":2,"eventId":99,"sequence":99,"researchId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","turnId":"vt_01ARZ3NDEKTSV4RRFFQ69G5FB0","type":"agent.thought","occurredAt":"2026-09-03T01:00:04Z","payload":{}}

        """))
        events.append(contentsOf: parser.finish())
        XCTAssertTrue(events.contains(where: { $0.type == .webSearchFailed }))
        let unknown = try XCTUnwrap(events.first(where: { $0.type.isUnknown }))
        XCTAssertEqual(unknown.type.rawValue, "agent.thought")
        XCTAssertEqual(AssistantV2StreamRecovery.action(for: unknown), .refreshSnapshot)
    }

    func testSSEParserReassemblesSplitChunks() {
        var parser = AssistantV2SSEParser()
        var events = parser.push("id: 2\nevent: turn.star")
        XCTAssertTrue(events.isEmpty)
        events.append(contentsOf: parser.push("ted\ndata: {\"schemaVersion\":2,\"eventId\":2,\"sequence\":2,\"researchId\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"turnId\":\"vt_01ARZ3NDEKTSV4RRFFQ69G5FB0\",\"type\":\"turn.started\",\"occurredAt\":\"2026-09-03T01:00:02Z\",\"payload\":{\"mode\":\"research\"}}\n\n"))
        XCTAssertEqual(events.first?.type, .turnStarted)
        XCTAssertEqual(events.first?.data?.eventId, 2)
    }

    func testEventCursorDedupsDurableIdsAndKeepsHeartbeats() throws {
        var parser = AssistantV2SSEParser()
        let payload = try sseText(named: "sse-replay-events.json")
        var events = parser.push(payload)
        events.append(contentsOf: parser.push(payload))
        var cursor = AssistantV2EventCursor()
        let accepted = events.filter { cursor.accept($0) }
        XCTAssertEqual(accepted.filter { $0.type != .heartbeat }.count, 6)
        XCTAssertEqual(cursor.lastEventId, "6")
    }

    private func sseText(named name: String) throws -> String {
        let root = try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any]
        let events = try XCTUnwrap(root?["events"] as? [[String: Any]])
        return events.map { item in
            let id = item["id"] as? String ?? ""
            let event = item["event"] as? String ?? ""
            let data = (try? JSONSerialization.data(withJSONObject: item["data"] as Any))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "id: \(id)\nevent: \(event)\ndata: \(data)\n"
        }.joined(separator: "\n") + "\n"
    }
}
