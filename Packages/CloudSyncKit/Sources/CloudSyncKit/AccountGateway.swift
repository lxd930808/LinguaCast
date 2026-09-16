import Foundation

// Client for the V18 account service public API. Credentials and Apple
// tokens are never logged; error bodies are reduced to their contract code.

public enum AccountGatewayError: Error, Equatable, Sendable {
    case transport(String)
    case http(status: Int, code: String?, retryAfterSeconds: Int?)
    case decoding(String)
    case configuration(String)

    public var code: String? {
        if case .http(_, let code, _) = self { return code }
        return nil
    }

    /// The stored session or token can no longer be used; the user must sign in again.
    public var endsSession: Bool {
        guard let code else { return false }
        return Self.sessionEndingCodes.contains(code)
    }

    static let sessionEndingCodes: Set<String> = [
        "SESSION_REVOKED",
        "REFRESH_TOKEN_INVALID",
        "REFRESH_TOKEN_REUSED",
        "AUTH_REQUIRED",
        "UNAUTHORIZED",
        "ACCOUNT_DISABLED",
        "ACCOUNT_DELETING"
    ]
}

public protocol AccountGatewaying: Sendable {
    func createChallenge(platform: String) async throws -> AppleSignInChallenge
    func exchange(
        challengeId: String,
        identityToken: String,
        authorizationCode: String,
        platform: String,
        deviceName: String?
    ) async throws -> AccountSessionTokens
    func refresh(refreshToken: String) async throws -> AccountSessionTokens
    func logout(accessToken: String) async throws
    func config(accessToken: String) async throws -> AccountConfig
    func quota(accessToken: String) async throws -> QuotaSnapshot
    func deleteAccount(accessToken: String) async throws
}

public final class AccountGateway: AccountGatewaying, Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func createChallenge(platform: String) async throws -> AppleSignInChallenge {
        try await send("POST", "/v1/auth/apple/challenge", body: ["platform": platform], token: nil)
    }

    public func exchange(
        challengeId: String,
        identityToken: String,
        authorizationCode: String,
        platform: String,
        deviceName: String?
    ) async throws -> AccountSessionTokens {
        var body = [
            "challengeId": challengeId,
            "identityToken": identityToken,
            "authorizationCode": authorizationCode,
            "platform": platform
        ]
        if let deviceName, !deviceName.isEmpty { body["deviceName"] = String(deviceName.prefix(80)) }
        return try await send("POST", "/v1/auth/apple/exchange", body: body, token: nil)
    }

    public func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        try await send("POST", "/v1/auth/refresh", body: ["refreshToken": refreshToken], token: nil)
    }

    public func logout(accessToken: String) async throws {
        _ = try await sendData("POST", "/v1/auth/logout", body: nil, token: accessToken)
    }

    public func config(accessToken: String) async throws -> AccountConfig {
        try await send("GET", "/v1/me/config", body: nil, token: accessToken)
    }

    public func quota(accessToken: String) async throws -> QuotaSnapshot {
        try await send("GET", "/v1/me/quota", body: nil, token: accessToken)
    }

    public func deleteAccount(accessToken: String) async throws {
        _ = try await sendData("DELETE", "/v1/me", body: nil, token: accessToken)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: String]?, token: String?) async throws -> T {
        let data = try await sendData(method, path, body: body, token: token)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AccountGatewayError.decoding(String(describing: T.self))
        }
    }

    private func sendData(_ method: String, _ path: String, body: [String: String]?, token: String?) async throws -> Data {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw AccountGatewayError.configuration("invalid account service URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AccountGatewayError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AccountGatewayError.transport("missing HTTP response")
        }
        if (200..<300).contains(http.statusCode) { return data }
        let envelope = try? JSONDecoder().decode(AccountServiceErrorEnvelope.self, from: data)
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) } ?? envelope?.error.retryAfterSeconds
        throw AccountGatewayError.http(status: http.statusCode, code: envelope?.error.code, retryAfterSeconds: retryAfter)
    }
}
