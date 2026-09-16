import CryptoKit
import Foundation
import Security

// V18 WP05 account session: server profiles, device-only credential storage
// partitioned per server, and a single-flight refreshing session manager.

// MARK: - Server profile

public enum AccountServerKind: String, Codable, Equatable, Sendable {
    case official
    case selfHosted
}

public struct AccountServerProfile: Equatable, Sendable {
    public let kind: AccountServerKind
    public let accountBaseURL: URL

    public init(kind: AccountServerKind, accountBaseURL: URL) {
        self.kind = kind
        self.accountBaseURL = accountBaseURL
    }

    /// Credential partition key: credentials of one server are never visible to another.
    public var id: String {
        "\(kind.rawValue)|\(accountBaseURL.absoluteString.lowercased())"
    }

    /// Parses a server address. https is required; plain http is only accepted
    /// for loopback and `.local` development hosts.
    public static func normalizedURL(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") { return url }
        return nil
    }
}

/// Device-local server selection (UserDefaults, never iCloud-synced).
public final class AccountServerPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let kindKey = "account.server.kind"
    private static let selfHostedURLKey = "account.server.selfHostedURL"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var kind: AccountServerKind {
        get { AccountServerKind(rawValue: defaults.string(forKey: Self.kindKey) ?? "") ?? .official }
        set { defaults.set(newValue.rawValue, forKey: Self.kindKey) }
    }

    public var selfHostedURL: String {
        get { defaults.string(forKey: Self.selfHostedURLKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.selfHostedURLKey) }
    }

    public func profile(officialURL: URL?) -> AccountServerProfile? {
        switch kind {
        case .official:
            return officialURL.map { AccountServerProfile(kind: .official, accountBaseURL: $0) }
        case .selfHosted:
            return AccountServerProfile.normalizedURL(selfHostedURL).map {
                AccountServerProfile(kind: .selfHosted, accountBaseURL: $0)
            }
        }
    }
}

// MARK: - Credential storage

public struct StoredAccountCredentials: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case appleSession
        case selfHostedToken
    }

    public var kind: Kind
    public var accessToken: String
    public var accessTokenExpiresAt: Date?
    public var refreshToken: String?
    public var sessionExpiresAt: Date?
    public var accountId: String?

    public init(
        kind: Kind,
        accessToken: String,
        accessTokenExpiresAt: Date?,
        refreshToken: String?,
        sessionExpiresAt: Date?,
        accountId: String?
    ) {
        self.kind = kind
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.sessionExpiresAt = sessionExpiresAt
        self.accountId = accountId
    }
}

public protocol AccountCredentialStoring: Sendable {
    func load(profileID: String) throws -> StoredAccountCredentials?
    func save(_ credentials: StoredAccountCredentials, profileID: String) throws
    func delete(profileID: String) throws
}

/// Keychain storage that never syncs: session credentials are per device.
public final class KeychainAccountCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    private let service = "LinguaCastAccountSession"

    public init() {}

    private func account(for profileID: String) -> String {
        let digest = SHA256.hash(data: Data(profileID.utf8))
        return "session." + digest.map { String(format: "%02x", $0) }.joined().prefix(32)
    }

    private func baseQuery(_ profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: profileID),
            kSecAttrSynchronizable as String: false
        ]
    }

    public func load(profileID: String) throws -> StoredAccountCredentials? {
        var query = baseQuery(profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.unexpectedStatus(status) }
        return try? JSONDecoder().decode(StoredAccountCredentials.self, from: data)
    }

    public func save(_ credentials: StoredAccountCredentials, profileID: String) throws {
        try delete(profileID: profileID)
        var query = baseQuery(profileID)
        query[kSecValueData as String] = try JSONEncoder().encode(credentials)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func delete(profileID: String) throws {
        let status = SecItemDelete(baseQuery(profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}

public final class InMemoryAccountCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: StoredAccountCredentials] = [:]

    public init() {}

    public func load(profileID: String) throws -> StoredAccountCredentials? {
        lock.withLock { items[profileID] }
    }

    public func save(_ credentials: StoredAccountCredentials, profileID: String) throws {
        lock.withLock { items[profileID] = credentials }
    }

    public func delete(profileID: String) throws {
        lock.withLock { items[profileID] = nil }
    }
}

// MARK: - Session manager

public enum AccountSessionError: Error, Equatable, Sendable {
    case signedOut
    case gateway(AccountGatewayError)
}

/// Token providers that can renew the credential after the server reported
/// ACCESS_TOKEN_EXPIRED; gateways retry such a request once.
public protocol RefreshableBearerTokenProviding: Sendable {
    func refreshBearerToken() async throws -> String
}

public actor AccountSessionManager {
    public nonisolated let profile: AccountServerProfile
    private let gateway: AccountGatewaying
    private let store: AccountCredentialStoring
    private let now: @Sendable () -> Date
    private var credentials: StoredAccountCredentials?
    private var refreshTask: Task<AccountSessionTokens, Error>?
    private var cachedConfig: AccountConfig?
    private var generation = 0

    /// Access tokens are renewed when they expire within this interval.
    static let refreshMargin: TimeInterval = 60

    public init(
        profile: AccountServerProfile,
        gateway: AccountGatewaying,
        store: AccountCredentialStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profile = profile
        self.gateway = gateway
        self.store = store
        self.now = now
        self.credentials = try? store.load(profileID: profile.id)
    }

    public var isSignedIn: Bool { credentials != nil }
    public var accountId: String? { credentials?.accountId }
    public var credentialKind: StoredAccountCredentials.Kind? { credentials?.kind }
    public var cachedAccountConfig: AccountConfig? { cachedConfig }

    public func beginAppleSignIn(platform: String) async throws -> AppleSignInChallenge {
        do {
            return try await gateway.createChallenge(platform: platform)
        } catch let error as AccountGatewayError {
            throw AccountSessionError.gateway(error)
        }
    }

    public func completeAppleSignIn(
        challengeId: String,
        identityToken: String,
        authorizationCode: String,
        platform: String,
        deviceName: String?
    ) async throws -> AccountConfig {
        let tokens: AccountSessionTokens
        do {
            tokens = try await gateway.exchange(
                challengeId: challengeId,
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                platform: platform,
                deviceName: deviceName
            )
        } catch let error as AccountGatewayError {
            throw AccountSessionError.gateway(error)
        }
        generation += 1
        try adopt(tokens)
        return try await config(forceRefresh: true)
    }

    /// Verifies a self-hosted deployment token against that server before storing it.
    public func connectSelfHosted(token: String) async throws -> AccountConfig {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let verified: AccountConfig
        do {
            verified = try await gateway.config(accessToken: trimmed)
        } catch let error as AccountGatewayError {
            throw AccountSessionError.gateway(error)
        }
        let stored = StoredAccountCredentials(
            kind: .selfHostedToken,
            accessToken: trimmed,
            accessTokenExpiresAt: nil,
            refreshToken: nil,
            sessionExpiresAt: nil,
            accountId: verified.account.accountId
        )
        try store.save(stored, profileID: profile.id)
        generation += 1
        credentials = stored
        cachedConfig = verified
        return verified
    }

    public func bearerToken() async throws -> String {
        guard let current = credentials else { throw AccountSessionError.signedOut }
        if current.kind == .selfHostedToken { return current.accessToken }
        if let expiresAt = current.accessTokenExpiresAt, expiresAt.timeIntervalSince(now()) <= Self.refreshMargin {
            return try await refresh()
        }
        return current.accessToken
    }

    public func refreshBearerToken() async throws -> String {
        guard let current = credentials else { throw AccountSessionError.signedOut }
        if current.kind == .selfHostedToken {
            throw AccountSessionError.gateway(.http(status: 401, code: "AUTH_REQUIRED", retryAfterSeconds: nil))
        }
        return try await refresh()
    }

    public func config(forceRefresh: Bool = false) async throws -> AccountConfig {
        if !forceRefresh, let cachedConfig { return cachedConfig }
        let gateway = self.gateway
        let value = try await authorized { token in try await gateway.config(accessToken: token) }
        cachedConfig = value
        return value
    }

    public func quota() async throws -> QuotaSnapshot {
        let gateway = self.gateway
        return try await authorized { token in try await gateway.quota(accessToken: token) }
    }

    public func signOut() async {
        if let current = credentials, current.kind == .appleSession {
            try? await gateway.logout(accessToken: current.accessToken)
        }
        clearLocal()
    }

    public func deleteAccount() async throws {
        let gateway = self.gateway
        _ = try await authorized { token -> Bool in
            try await gateway.deleteAccount(accessToken: token)
            return true
        }
        clearLocal()
    }

    private func authorized<T: Sendable>(_ operation: @escaping @Sendable (String) async throws -> T) async throws -> T {
        let token = try await bearerToken()
        do {
            return try await operation(token)
        } catch let error as AccountGatewayError {
            guard error.code == "ACCESS_TOKEN_EXPIRED" else {
                if error.endsSession { clearLocal() }
                throw AccountSessionError.gateway(error)
            }
            let renewed = try await refreshBearerToken()
            do {
                return try await operation(renewed)
            } catch let retryError as AccountGatewayError {
                if retryError.endsSession { clearLocal() }
                throw AccountSessionError.gateway(retryError)
            }
        }
    }

    /// Single-flight rotation: concurrent callers share one refresh request.
    private func refresh() async throws -> String {
        if let running = refreshTask {
            do {
                return try await running.value.accessToken
            } catch let error as AccountGatewayError {
                throw AccountSessionError.gateway(error)
            }
        }
        guard let refreshToken = credentials?.refreshToken else { throw AccountSessionError.signedOut }
        let startedGeneration = generation
        let gateway = self.gateway
        let task = Task { try await gateway.refresh(refreshToken: refreshToken) }
        refreshTask = task
        do {
            let tokens = try await task.value
            refreshTask = nil
            guard startedGeneration == generation else { throw AccountSessionError.signedOut }
            try adopt(tokens)
            return tokens.accessToken
        } catch let error as AccountGatewayError {
            refreshTask = nil
            if error.endsSession, startedGeneration == generation { clearLocal() }
            throw AccountSessionError.gateway(error)
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func adopt(_ tokens: AccountSessionTokens) throws {
        let stored = StoredAccountCredentials(
            kind: .appleSession,
            accessToken: tokens.accessToken,
            accessTokenExpiresAt: AccountDates.parse(tokens.accessTokenExpiresAt),
            refreshToken: tokens.refreshToken,
            sessionExpiresAt: AccountDates.parse(tokens.sessionExpiresAt),
            accountId: tokens.account.accountId
        )
        try store.save(stored, profileID: profile.id)
        credentials = stored
    }

    private func clearLocal() {
        credentials = nil
        cachedConfig = nil
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        try? store.delete(profileID: profile.id)
    }
}

/// Bearer token provider backed by the account session; usable by every service gateway.
public struct AccountSessionTokenProvider: CloudContentTokenProviding, AssistantTokenProviding, RefreshableBearerTokenProviding {
    public let manager: AccountSessionManager

    public init(manager: AccountSessionManager) {
        self.manager = manager
    }

    public func bearerToken() async throws -> String {
        try await manager.bearerToken()
    }

    public func refreshBearerToken() async throws -> String {
        try await manager.refreshBearerToken()
    }
}

// MARK: - Published access

public struct AccountServiceAccessSnapshot: Equatable, Sendable {
    public var profileID: String
    public var accountId: String
    public var contentBaseURL: String
    public var assistantBaseURL: String
    public var mediaBaseURL: String?
    public var capabilities: AccountCapabilities

    public init(profileID: String, config: AccountConfig) {
        func trimmed(_ value: String) -> String {
            var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while result.hasSuffix("/") { result.removeLast() }
            return result
        }
        self.profileID = profileID
        self.accountId = config.account.accountId
        self.contentBaseURL = trimmed(config.services.contentBaseUrl)
        self.assistantBaseURL = trimmed(config.services.assistantBaseUrl)
        self.mediaBaseURL = config.services.mediaBaseUrl.map(trimmed)
        self.capabilities = config.capabilities
    }
}

/// Account-scoped service access published by the app after sign-in. Gateways
/// take base URLs and credentials together from here, so a request always pairs
/// one server's configuration with that server's token.
public enum AccountServiceAccess {
    private static let lock = NSLock()
    private static var current: (snapshot: AccountServiceAccessSnapshot, tokenProvider: AccountSessionTokenProvider)?

    public static var snapshot: AccountServiceAccessSnapshot? {
        lock.withLock { current?.snapshot }
    }

    public static var tokenProvider: AccountSessionTokenProvider? {
        lock.withLock { current?.tokenProvider }
    }

    public static func publish(_ snapshot: AccountServiceAccessSnapshot, tokenProvider: AccountSessionTokenProvider) {
        lock.withLock { current = (snapshot, tokenProvider) }
    }

    public static func clear() {
        lock.withLock { current = nil }
    }
}
