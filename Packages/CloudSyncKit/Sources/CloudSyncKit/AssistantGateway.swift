import Foundation
import DomainModels

public enum AssistantGatewayError: Error, Equatable, Sendable {
    case transport(String)
    case http(status: Int, server: AssistantErrorBody?)
    case decoding(String)
    case configuration(String)

    public var isUnauthorized: Bool {
        if case .http(let status, _) = self { return status == 401 || status == 403 }
        return false
    }

    public var retryAfterSeconds: Int? {
        if case .http(_, let server) = self { return server?.retryAfterSeconds }
        return nil
    }
}

public protocol AssistantTokenProviding: Sendable {
    func bearerToken() async throws -> String
}

public struct StaticAssistantTokenProvider: AssistantTokenProviding {
    private let token: String
    public init(token: String) { self.token = token }
    public func bearerToken() async throws -> String { token }
}

public struct KeychainAssistantTokenProvider: AssistantTokenProviding {
    private let store: AssistantServiceTokenStoring
    public init(store: AssistantServiceTokenStoring) { self.store = store }
    public func bearerToken() async throws -> String { try store.readAssistantServiceToken() }
}

public protocol AssistantGatewaying: Sendable {
    func createSession(_ request: AssistantSessionCreateRequest, idempotencyKey: String?) async throws -> AssistantSessionSummary
    func listSessions(cursor: String?, limit: Int) async throws -> AssistantSessionListResponse
    func getSession(id: String) async throws -> AssistantSessionSnapshot
    func deleteSession(id: String, idempotencyKey: String?) async throws
    func createTurn(sessionId: String, request: AssistantTurnCreateRequest, idempotencyKey: String?) async throws -> AssistantTurnAcceptedResponse
    func cancelTurn(id: String, idempotencyKey: String?) async throws -> AssistantTurnSummary
    func listSearchResults(sessionId: String) async throws -> AssistantSearchResultListResponse
    func listSearchRuns(sessionId: String, cursor: String?, limit: Int) async throws -> AssistantSearchRunListResponse
    func getSearchRun(id: String) async throws -> AssistantSearchRun
    func bindSource(sessionId: String, request: AssistantSourceBindRequest, idempotencyKey: String?) async throws -> AssistantContentBinding
    func getSources(sessionId: String) async throws -> AssistantSourceListResponse
}

public final class AssistantGateway: AssistantGatewaying, Sendable {
    public let baseURL: URL
    private let tokenProvider: AssistantTokenProviding
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, tokenProvider: AssistantTokenProviding, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
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
        session: URLSession = .shared
    ) throws -> AssistantGateway {
        guard let url = URL(string: baseURLString) else {
            throw AssistantGatewayError.configuration("invalid assistant base URL")
        }
        return AssistantGateway(baseURL: url, tokenProvider: tokenProvider, session: session)
    }

    public func createSession(_ request: AssistantSessionCreateRequest, idempotencyKey: String? = nil) async throws -> AssistantSessionSummary {
        try await send(method: "POST", path: "/v1/assistant/sessions", body: request, idempotencyKey: idempotencyKey)
    }

    public func listSessions(cursor: String? = nil, limit: Int = 20) async throws -> AssistantSessionListResponse {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(50, max(1, limit))))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(method: "GET", path: "/v1/assistant/sessions", query: items)
    }

    public func getSession(id: String) async throws -> AssistantSessionSnapshot {
        try await send(method: "GET", path: "/v1/assistant/sessions/\(id)")
    }

    public func deleteSession(id: String, idempotencyKey: String? = nil) async throws {
        let _: Data = try await sendData(method: "DELETE", path: "/v1/assistant/sessions/\(id)", idempotencyKey: idempotencyKey, allowEmpty: true)
    }

    public func createTurn(
        sessionId: String,
        request: AssistantTurnCreateRequest,
        idempotencyKey: String? = nil
    ) async throws -> AssistantTurnAcceptedResponse {
        try await send(
            method: "POST",
            path: "/v1/assistant/sessions/\(sessionId)/turns",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func cancelTurn(id: String, idempotencyKey: String? = nil) async throws -> AssistantTurnSummary {
        try await send(method: "POST", path: "/v1/assistant/turns/\(id)/cancel", idempotencyKey: idempotencyKey)
    }

    public func listSearchResults(sessionId: String) async throws -> AssistantSearchResultListResponse {
        try await send(method: "GET", path: "/v1/assistant/sessions/\(sessionId)/search-results")
    }

    public func listSearchRuns(sessionId: String, cursor: String? = nil, limit: Int = 20) async throws -> AssistantSearchRunListResponse {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(50, max(1, limit))))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(method: "GET", path: "/v1/assistant/sessions/\(sessionId)/search-runs", query: items)
    }

    public func getSearchRun(id: String) async throws -> AssistantSearchRun {
        try await send(method: "GET", path: "/v1/assistant/search-runs/\(id)")
    }

    public func bindSource(
        sessionId: String,
        request: AssistantSourceBindRequest,
        idempotencyKey: String? = nil
    ) async throws -> AssistantContentBinding {
        try await send(
            method: "POST",
            path: "/v1/assistant/sessions/\(sessionId)/sources",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func getSources(sessionId: String) async throws -> AssistantSourceListResponse {
        try await send(method: "GET", path: "/v1/assistant/sessions/\(sessionId)/sources")
    }

    public func eventsURL(turnId: String) -> URL {
        baseURL.appending(path: "/v1/assistant/turns/\(turnId)/events")
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
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AssistantGatewayError.transport(error.localizedDescription)
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
}
