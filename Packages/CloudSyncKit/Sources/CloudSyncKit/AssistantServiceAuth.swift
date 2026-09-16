import Foundation
import DomainModels

// Shared assistant service error and bearer-token types used by the V2 gateway and
// event stream (the V1 gateway that originally hosted them was removed in V18).

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
