import Foundation
import DomainModels

public protocol AssistantV2Gatewaying: Sendable {
    func createResearch(_ request: AssistantV2ResearchCreateRequest, idempotencyKey: String?) async throws -> AssistantV2Research
    func listResearches(cursor: String?, limit: Int) async throws -> AssistantV2ResearchListResponse
    func getResearch(id: String) async throws -> AssistantV2ResearchSnapshot
    func deleteResearch(id: String, idempotencyKey: String?) async throws -> AssistantV2Research?
    func createTurn(researchId: String, request: AssistantV2TurnCreateRequest, idempotencyKey: String?) async throws -> AssistantV2TurnAcceptedResponse
    func cancelTurn(id: String, idempotencyKey: String?) async throws -> AssistantV2TurnSummary
    func listArtifacts(
        researchId: String,
        kind: AssistantV2ArtifactKind?,
        status: AssistantV2ArtifactStatus?,
        cursor: String?,
        limit: Int
    ) async throws -> AssistantV2ArtifactListResponse
    func getArtifact(researchId: String, artifactId: String) async throws -> AssistantV2ArtifactBody
    func requestTranscription(
        researchId: String,
        sourceId: String,
        request: AssistantV2TranscriptionCreateRequest,
        idempotencyKey: String?
    ) async throws -> AssistantV2TranscriptJob
    func getTranscription(researchId: String, jobId: String) async throws -> AssistantV2TranscriptJob
    func listTranscriptions(researchId: String) async throws -> [AssistantV2TranscriptJob]
    func getMemory(researchId: String) async throws -> AssistantV2MemorySnapshot
    func confirmMemoryProposal(id: String, idempotencyKey: String?) async throws -> AssistantV2MemoryEntry
    func rejectMemoryProposal(id: String, idempotencyKey: String?) async throws -> AssistantV2MemoryProposal
}

extension AssistantGatewayError {
    public var v2Code: AssistantV2ErrorCode? {
        guard case .http(_, let server) = self, let code = server?.code else { return nil }
        return AssistantV2ErrorCode(rawValue: code)
    }

    public var shouldRefreshSnapshot: Bool {
        v2Code?.shouldRefreshSnapshot == true
    }
}

public final class AssistantV2Gateway: AssistantV2Gatewaying, Sendable {
    public let baseURL: URL
    public let clientVersion: String?
    private let tokenProvider: AssistantTokenProviding
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        baseURL: URL,
        tokenProvider: AssistantTokenProviding,
        session: URLSession = .shared,
        clientVersion: String? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
        self.clientVersion = clientVersion
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date \(value)")
        }
        self.encoder = JSONEncoder()
    }

    public static func makeDefault(
        baseURLString: String,
        tokenProvider: AssistantTokenProviding,
        session: URLSession = .shared,
        clientVersion: String? = nil
    ) throws -> AssistantV2Gateway {
        guard let url = URL(string: baseURLString) else {
            throw AssistantGatewayError.configuration("invalid assistant base URL")
        }
        return AssistantV2Gateway(
            baseURL: url,
            tokenProvider: tokenProvider,
            session: session,
            clientVersion: clientVersion
        )
    }

    public func createResearch(
        _ request: AssistantV2ResearchCreateRequest,
        idempotencyKey: String? = nil
    ) async throws -> AssistantV2Research {
        try await send(method: "POST", path: "/v2/assistant/researches", body: request, idempotencyKey: idempotencyKey)
    }

    public func listResearches(cursor: String? = nil, limit: Int = 20) async throws -> AssistantV2ResearchListResponse {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(50, max(1, limit))))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(method: "GET", path: "/v2/assistant/researches", query: items)
    }

    public func getResearch(id: String) async throws -> AssistantV2ResearchSnapshot {
        try await send(method: "GET", path: "/v2/assistant/researches/\(id)")
    }

    public func deleteResearch(id: String, idempotencyKey: String? = nil) async throws -> AssistantV2Research? {
        let data = try await sendData(
            method: "DELETE",
            path: "/v2/assistant/researches/\(id)",
            idempotencyKey: idempotencyKey,
            allowEmpty: true
        )
        if data.isEmpty || data == Data("{}".utf8) { return nil }
        return try decode(data)
    }

    public func createTurn(
        researchId: String,
        request: AssistantV2TurnCreateRequest,
        idempotencyKey: String? = nil
    ) async throws -> AssistantV2TurnAcceptedResponse {
        try await send(
            method: "POST",
            path: "/v2/assistant/researches/\(researchId)/turns",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func cancelTurn(id: String, idempotencyKey: String? = nil) async throws -> AssistantV2TurnSummary {
        try await send(method: "POST", path: "/v2/assistant/turns/\(id)/cancel", idempotencyKey: idempotencyKey)
    }

    public func listArtifacts(
        researchId: String,
        kind: AssistantV2ArtifactKind? = nil,
        status: AssistantV2ArtifactStatus? = nil,
        cursor: String? = nil,
        limit: Int = 20
    ) async throws -> AssistantV2ArtifactListResponse {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(50, max(1, limit))))]
        if let kind { items.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        if let status { items.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(
            method: "GET",
            path: "/v2/assistant/researches/\(researchId)/artifacts",
            query: items
        )
    }

    public func getArtifact(researchId: String, artifactId: String) async throws -> AssistantV2ArtifactBody {
        try await send(
            method: "GET",
            path: "/v2/assistant/researches/\(researchId)/artifacts/\(artifactId)"
        )
    }

    public func requestTranscription(
        researchId: String,
        sourceId: String,
        request: AssistantV2TranscriptionCreateRequest,
        idempotencyKey: String? = nil
    ) async throws -> AssistantV2TranscriptJob {
        try await send(
            method: "POST",
            path: "/v2/assistant/researches/\(researchId)/sources/\(sourceId)/transcription",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func getTranscription(researchId: String, jobId: String) async throws -> AssistantV2TranscriptJob {
        try await send(
            method: "GET",
            path: "/v2/assistant/researches/\(researchId)/transcriptions/\(jobId)"
        )
    }

    public func listTranscriptions(researchId: String) async throws -> [AssistantV2TranscriptJob] {
        let response: AssistantV2TranscriptJobListResponse = try await send(
            method: "GET",
            path: "/v2/assistant/researches/\(researchId)/transcriptions"
        )
        return response.transcriptJobs
    }

    public func getMemory(researchId: String) async throws -> AssistantV2MemorySnapshot {
        try await send(method: "GET", path: "/v2/assistant/researches/\(researchId)/memory")
    }

    public func confirmMemoryProposal(id: String, idempotencyKey: String? = nil) async throws -> AssistantV2MemoryEntry {
        try await send(
            method: "POST",
            path: "/v2/assistant/memory-proposals/\(id)/confirm",
            idempotencyKey: idempotencyKey
        )
    }

    public func rejectMemoryProposal(id: String, idempotencyKey: String? = nil) async throws -> AssistantV2MemoryProposal {
        try await send(
            method: "POST",
            path: "/v2/assistant/memory-proposals/\(id)/reject",
            idempotencyKey: idempotencyKey
        )
    }

    public func eventsURL(turnId: String) -> URL {
        baseURL.appending(path: "/v2/assistant/turns/\(turnId)/events")
    }

    public func resolveEventsURL(_ eventsURL: String) -> URL? {
        if let absolute = URL(string: eventsURL), absolute.scheme != nil {
            return absolute
        }
        return URL(string: eventsURL, relativeTo: baseURL)?.absoluteURL
    }

    private func send<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> T {
        try decode(try await sendData(method: method, path: path, query: query, body: nil, idempotencyKey: idempotencyKey))
    }

    private func send<T: Decodable, B: Encodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: B,
        idempotencyKey: String? = nil
    ) async throws -> T {
        try decode(
            try await sendData(
                method: method,
                path: path,
                query: query,
                body: try encoder.encode(body),
                idempotencyKey: idempotencyKey
            )
        )
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AssistantGatewayError.decoding(String(describing: error))
        }
    }

    private func sendData(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        idempotencyKey: String? = nil,
        allowEmpty: Bool = false
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw AssistantGatewayError.configuration("invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let token = try await tokenProvider.bearerToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let clientVersion {
            request.setValue(clientVersion, forHTTPHeaderField: "X-Client-Version")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        var (data, response) = try await transmit(request)
        if let first = response as? HTTPURLResponse, first.statusCode == 401,
           let refreshable = tokenProvider as? RefreshableBearerTokenProviding,
           AccountErrorCodes.isExpiredAccessToken(data),
           let renewed = try? await refreshable.refreshBearerToken() {
            request.setValue("Bearer \(renewed)", forHTTPHeaderField: "Authorization")
            (data, response) = try await transmit(request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AssistantGatewayError.transport("missing HTTP response")
        }
        if (200..<300).contains(http.statusCode) {
            if allowEmpty && data.isEmpty { return Data("{}".utf8) }
            return data
        }
        let server = try? decoder.decode(AssistantErrorEnvelope.self, from: data).error
        throw AssistantGatewayError.http(status: http.statusCode, server: server)
    }

    private func transmit(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AssistantGatewayError.transport(error.localizedDescription)
        }
    }
}
