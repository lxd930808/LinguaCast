import Foundation
import Testing
@testable import DomainModels

@Suite("AssistantV2 models contract")
struct AssistantV2ModelsTests {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/AssistantV2")

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

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    @Test("research create, list, and snapshot fixtures decode")
    func decodeResearchFixtures() throws {
        let request = try Self.decoder().decode(
            AssistantV2ResearchCreateRequest.self,
            from: Self.fixture("research-create-request.json")
        )
        #expect(request.sharedAliases == ["notes"])
        #expect(request.translationQuality == .quality)

        let created = try Self.decoder().decode(
            AssistantV2Research.self,
            from: Self.fixture("research-created.json")
        )
        #expect(created.status == .ready)
        #expect(created.researchId == "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        #expect(created.grants?.first?.permission == .read)
        #expect(created.artifactCounts?.webSearch == 0)

        let list = try Self.decoder().decode(
            AssistantV2ResearchListResponse.self,
            from: Self.fixture("research-list.json")
        )
        #expect(list.researches.count == 1)
        #expect(list.nextCursor == nil)

        let snapshot = try Self.decoder().decode(
            AssistantV2ResearchSnapshot.self,
            from: Self.fixture("research-snapshot-happy.json")
        )
        #expect(snapshot.artifacts.count == 6)
        #expect(snapshot.latestReportArtifactId == "01ARZ3NDEKTSV4RRFFQ69G5FD5")
        #expect(snapshot.memory?.proposals.first?.status == .pending)
        #expect(snapshot.messages.first?.role == .user)

        let partial = try Self.decoder().decode(
            AssistantV2ResearchSnapshot.self,
            from: Self.fixture("research-snapshot-partial.json")
        )
        #expect(partial.artifacts.contains(where: { $0.status == .failed && $0.kind == .youtubeSearch }))
        #expect(partial.latestReportArtifactId == nil)
    }

    @Test("turn, artifact, memory, transcript, and grep fixtures decode")
    func decodeSupportingFixtures() throws {
        let turnRequest = try Self.decoder().decode(
            AssistantV2TurnCreateRequest.self,
            from: Self.fixture("turn-create-research.json")
        )
        #expect(turnRequest.mode == .research)
        #expect(turnRequest.message.contains("accounting"))

        let accepted = try Self.decoder().decode(
            AssistantV2TurnAcceptedResponse.self,
            from: Self.fixture("turn-accepted-research.json")
        )
        #expect(accepted.eventsURL.contains("/v2/assistant/turns/"))
        #expect(accepted.status == .queued)

        let artifacts = try Self.decoder().decode(
            AssistantV2ArtifactListResponse.self,
            from: Self.fixture("artifact-list.json")
        )
        #expect(artifacts.artifacts.first?.kind == .webPage)
        #expect(artifacts.artifacts.first?.evidenceLevel == .primaryContent)

        let body = try Self.decoder().decode(
            AssistantV2ArtifactBody.self,
            from: Self.fixture("artifact-body-web-page.json")
        )
        #expect(body.encoding == .utf8)
        #expect(body.truncated == false)

        let corrupt = try Self.decoder().decode(
            AssistantV2WorkspaceArtifact.self,
            from: Self.fixture("artifact-corrupt.json")
        )
        #expect(corrupt.status == .corrupt)

        let grant = try Self.decoder().decode(
            AssistantV2WorkspaceGrant.self,
            from: Self.fixture("workspace-grant.json")
        )
        #expect(grant.alias == "notes")

        let memory = try Self.decoder().decode(
            AssistantV2MemorySnapshot.self,
            from: Self.fixture("memory-snapshot.json")
        )
        #expect(memory.entries.first?.scope == .research)
        #expect(memory.proposals.first?.status == .pending)

        let confirmed = try Self.decoder().decode(
            AssistantV2MemoryEntry.self,
            from: Self.fixture("memory-proposal-confirmed.json")
        )
        #expect(confirmed.scope == .global)
        #expect(confirmed.status == "confirmed")

        let transcription = try Self.decoder().decode(
            AssistantV2TranscriptionCreateRequest.self,
            from: Self.fixture("transcription-create-request.json")
        )
        #expect(transcription.confirmed)

        let job = try Self.decoder().decode(
            AssistantV2TranscriptJob.self,
            from: Self.fixture("transcript-job-ready.json")
        )
        #expect(job.status == .ready)
        #expect(job.progress == 1)

        let citation = try Self.decoder().decode(
            AssistantV2Citation.self,
            from: Self.fixture("citation-transcript.json")
        )
        #expect(citation.evidenceLevel == .transcript)
        #expect(citation.startMilliseconds == 1_112_000)

        let grepRequest = try Self.decoder().decode(
            AssistantV2GrepFilesRequest.self,
            from: Self.fixture("grep-files-request.json")
        )
        #expect(grepRequest.root.hasPrefix("research://"))
        #expect(grepRequest.mode == .literal)

        let grepResult = try Self.decoder().decode(
            AssistantV2GrepFilesResult.self,
            from: Self.fixture("grep-files-result.json")
        )
        #expect(grepResult.matches.first?.uri.hasPrefix("research://") == true)
    }

    @Test("V2 error envelopes decode to stable codes")
    func decodeErrorEnvelopes() throws {
        let cases: [(String, AssistantV2ErrorCode)] = [
            ("error-envelope-unauthorized.json", .unauthorized),
            ("error-envelope-idempotency-conflict.json", .idempotencyConflict),
            ("error-envelope-event-cursor-expired.json", .eventCursorExpired),
            ("error-envelope-workspace-path-unsafe.json", .workspacePathUnsafe),
            ("error-envelope-grant-denied.json", .workspaceGrantDenied),
            ("error-envelope-artifact-corrupt.json", .artifactCorrupt),
            ("error-envelope-legacy-session-read-only.json", .legacySessionReadOnly)
        ]
        for (name, expected) in cases {
            let envelope = try Self.decoder().decode(AssistantErrorEnvelope.self, from: Self.fixture(name))
            #expect(AssistantV2ErrorCode(rawValue: envelope.error.code) == expected, "\(name)")
        }
        #expect(AssistantV2ErrorCode.eventCursorExpired.shouldRefreshSnapshot)
        #expect(
            AssistantV2ErrorCode(rawValue: "BRAND_NEW_CODE").isRetryable(httpStatus: 503, serverRetryable: false)
        )
        #expect(
            !AssistantV2ErrorCode(rawValue: "BRAND_NEW_CODE").isRetryable(httpStatus: 400, serverRetryable: false)
        )
    }

    @Test("SSE replay and partial fixtures decode envelopes")
    func decodeSseFixtures() throws {
        for name in ["sse-replay-events.json", "sse-partial-web-failed.json"] {
            let wrapped = try JSONSerialization.jsonObject(with: Self.fixture(name)) as? [String: Any]
            let events = try #require(wrapped?["events"] as? [[String: Any]])
            for event in events {
                let type = AssistantV2SseEventType(rawValue: event["event"] as? String ?? "")
                #expect(!type.isUnknown, "\(name) \(event["event"] ?? "")")
                let data = try JSONSerialization.data(withJSONObject: event["data"] as Any)
                let decoded = try Self.decoder().decode(AssistantV2SseEventData.self, from: data)
                #expect(decoded.schemaVersion == 2)
                #expect(decoded.researchId.isEmpty == false)
            }
        }
    }

    @Test("unknown enums and events decode without crashing")
    func unknownEnumTolerance() throws {
        let snapshotJSON = """
        {
          "researchId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
          "title": "x",
          "status": "awaiting_operator",
          "workspaceStatus": "ready",
          "createdAt": "2026-09-03T01:00:00Z",
          "updatedAt": "2026-09-03T01:00:00Z",
          "grants": [],
          "messages": [],
          "artifacts": [{
            "artifactId": "01ARZ3NDEKTSV4RRFFQ69G5FD0",
            "researchId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            "kind": "shared_note",
            "status": "quarantined",
            "mediaType": "text/plain",
            "bytes": 1,
            "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "producer": "test",
            "evidenceLevel": "custom_level",
            "createdAt": "2026-09-03T01:00:00Z",
            "updatedAt": "2026-09-03T01:00:00Z"
          }]
        }
        """.data(using: .utf8)!
        let snapshot = try Self.decoder().decode(AssistantV2ResearchSnapshot.self, from: snapshotJSON)
        guard case .unknown(let status) = snapshot.status else {
            Issue.record("unknown research status should map to .unknown")
            return
        }
        #expect(status == "awaiting_operator")
        guard case .unknown(let kind) = snapshot.artifacts[0].kind else {
            Issue.record("unknown artifact kind should map to .unknown")
            return
        }
        #expect(kind == "shared_note")
        guard case .unknown(let evidence) = snapshot.artifacts[0].evidenceLevel else {
            Issue.record("unknown evidence level should map to .unknown")
            return
        }
        #expect(evidence == "custom_level")

        let turnStatus = AssistantV2TurnStatus(rawValue: "waiting_quota")
        guard case .unknown(let raw) = turnStatus else {
            Issue.record("unknown turn status should map to .unknown")
            return
        }
        #expect(raw == "waiting_quota")
        #expect(!turnStatus.isTerminal)

        let eventType = AssistantV2SseEventType(rawValue: "agent.thought")
        #expect(eventType.isUnknown)
        #expect(eventType.shouldRefreshSnapshot)
    }

    @Test("REST artifact models never expose filesystem path fields")
    func artifactModelsHaveNoPathFields() throws {
        let names = [
            "research-snapshot-happy.json",
            "artifact-list.json",
            "artifact-body-web-page.json",
            "artifact-corrupt.json"
        ]
        for name in names {
            let root = try JSONSerialization.jsonObject(with: Self.fixture(name))
            for object in Self.collectObjects(root) {
                guard object["artifactId"] != nil, object["sha256"] != nil, object["kind"] != nil else { continue }
                for key in AssistantV2WirePolicy.forbiddenArtifactPathKeys {
                    #expect(object[key] == nil, "\(name) artifact must not expose \(key)")
                }
            }
        }

        let artifact = try Self.decoder().decode(
            AssistantV2WorkspaceArtifact.self,
            from: Self.fixture("artifact-corrupt.json")
        )
        let labels = Set(Mirror(reflecting: artifact).children.compactMap(\.label))
        for key in ["path", "relativePath", "uri", "fileName", "filename", "realPath", "absolutePath"] {
            #expect(!labels.contains(key))
        }
    }

    @Test("create request encodes camelCase wire keys including sharedAliases")
    func encodeCreateRequest() throws {
        let request = AssistantV2ResearchCreateRequest(
            outputLanguage: "zh-Hans",
            storefront: "US",
            targetLanguage: "zh-Hans",
            translationQuality: .quality,
            title: "AI and accounting",
            sharedAliases: ["notes"]
        )
        let data = try Self.encoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sharedAliases"] as? [String] == ["notes"])
        #expect(object["outputLanguage"] as? String == "zh-Hans")
        #expect(object["translationQuality"] as? String == "quality")
    }

    private static func collectObjects(_ value: Any, into found: inout [[String: Any]]) {
        if let array = value as? [Any] {
            for item in array { collectObjects(item, into: &found) }
        } else if let object = value as? [String: Any] {
            found.append(object)
            for nested in object.values { collectObjects(nested, into: &found) }
        }
    }

    private static func collectObjects(_ value: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        collectObjects(value, into: &found)
        return found
    }
}
