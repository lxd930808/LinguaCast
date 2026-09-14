import Foundation
import XCTest
@testable import CloudSyncKit
import DomainModels

final class AssistantGatewayTests: XCTestCase {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/Assistant")

    func fixture(_ name: String) -> Data {
        let url = Self.fixturesDir.appendingPathComponent(name)
        return (try? Data(contentsOf: url)) ?? Data()
    }

    override func setUp() {
        super.setUp()
        ScriptedURLProtocol.reset()
    }

    func makeClient() -> AssistantGateway {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return try! AssistantGateway.makeDefault(
            baseURLString: "https://assistant.example.com/",
            tokenProvider: StaticAssistantTokenProvider(token: "assistant-token"),
            session: session
        )
    }

    func testCreateSessionSendsBearerToAssistantHost() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "assistant.example.com")
            XCTAssertEqual(request.url?.path, "/v1/assistant/sessions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer assistant-token")
            return (201, self.fixture("session-created.json"), [:])
        }
        let session = try await makeClient().createSession(AssistantSessionCreateRequest(outputLanguage: "zh-Hans"))
        XCTAssertEqual(session.phase, .researching)
    }

    func testUnauthorizedDoesNotDecodeAsSuccess() async {
        ScriptedURLProtocol.handler = { _ in (401, self.fixture("error-envelope-unauthorized.json"), [:]) }
        do {
            _ = try await makeClient().listSessions()
            XCTFail("expected 401")
        } catch let error as AssistantGatewayError {
            XCTAssertTrue(error.isUnauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSSEParserHandlesMultilineDataAndHeartbeat() {
        var parser = AssistantSSEParser()
        let payload = """
        id: 1
        event: turn.accepted
        data: {"schemaVersion":1,"sessionId":"as_01ARZ3NDEKTSV4RRFFQ69G5FAV","turnId":"at_01ARZ3NDEKTSV4RRFFQ69G5FB0","sequence":1,"occurredAt":"2026-08-31T01:00:01Z","payload":{"kind":"research"}}

        event: heartbeat
        data: {"t":"2026-08-31T01:00:16Z"}

        """
        var events = parser.push(payload)
        events.append(contentsOf: parser.finish())
        XCTAssertEqual(events.first?.type, .turnAccepted)
        XCTAssertTrue(events.contains(where: { $0.type == .heartbeat }))
    }

    func testSSEParserReassemblesSplitChunks() {
        var parser = AssistantSSEParser()
        var events = parser.push("id: 2\nevent: turn.star")
        XCTAssertTrue(events.isEmpty)
        events.append(contentsOf: parser.push("ted\ndata: {\"schemaVersion\":1,\"sessionId\":\"as_01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"turnId\":\"at_01ARZ3NDEKTSV4RRFFQ69G5FB0\",\"sequence\":2,\"occurredAt\":\"2026-08-31T01:00:02Z\",\"payload\":{}}\n\n"))
        XCTAssertEqual(events.first?.type, .turnStarted)
    }

    func testSSEParserMapsSessionTitleUpdated() {
        var parser = AssistantSSEParser()
        let payload = """
        id: 1
        event: session.title_updated
        data: {"schemaVersion":1,"sessionId":"as_01ARZ3NDEKTSV4RRFFQ69G5FAV","turnId":"at_01ARZ3NDEKTSV4RRFFQ69G5FB0","sequence":1,"occurredAt":"2026-08-31T01:00:01Z","payload":{"title":"英文慢速新闻"}}

        """
        var events = parser.push(payload)
        events.append(contentsOf: parser.finish())
        XCTAssertEqual(events.first?.type, .sessionTitleUpdated)
        if case .string(let title) = events.first?.data?.payload["title"] {
            XCTAssertEqual(title, "英文慢速新闻")
        } else {
            XCTFail("expected title payload")
        }
    }

    func testListSearchRunsUsesSessionPath() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/assistant/sessions/as_01ARZ3NDEKTSV4RRFFQ69G5FAV/search-runs")
            return (200, self.fixture("search-run-list.json"), [:])
        }
        let list = try await makeClient().listSearchRuns(sessionId: "as_01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertFalse(list.runs.isEmpty)
    }

    func testGetSearchRunDecodesPodcastEpisode() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/assistant/search-runs/srun_01ARZ3NDEKTSV4RRFFQ69G5FE0")
            return (200, self.fixture("search-run-success.json"), [:])
        }
        let run = try await makeClient().getSearchRun(id: "srun_01ARZ3NDEKTSV4RRFFQ69G5FE0")
        XCTAssertEqual(run.results?.first?.platform, .podcast)
        XCTAssertEqual(run.results?.first?.sourceType, .podcastEpisode)
    }
}
