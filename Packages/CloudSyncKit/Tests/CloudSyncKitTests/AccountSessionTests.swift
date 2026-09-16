import DomainModels
import Foundation
import XCTest
@testable import CloudSyncKit

private let officialProfile = AccountServerProfile(kind: .official, accountBaseURL: URL(string: "https://account.example.com")!)
private let selfHostedProfile = AccountServerProfile(kind: .selfHosted, accountBaseURL: URL(string: "https://my-server.example.org")!)

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func sessionTokens(access: String, refresh: String, expiresIn: TimeInterval, now: Date) -> AccountSessionTokens {
    AccountSessionTokens(
        accessToken: access,
        accessTokenExpiresAt: iso(now.addingTimeInterval(expiresIn)),
        refreshToken: refresh,
        sessionExpiresAt: iso(now.addingTimeInterval(30 * 86_400)),
        sessionId: "ses_1",
        account: AccountSummary(accountId: "acc_01K0000000000000000000000A", authMode: .apple, status: "active", createdAt: iso(now))
    )
}

private func sampleConfig(accountId: String = "acc_01K0000000000000000000000A", content: String = "https://content.example.com/") -> AccountConfig {
    AccountConfig(
        schemaVersion: 1,
        account: AccountSummary(accountId: accountId, authMode: .apple, status: "active", createdAt: "2026-09-14T08:00:00Z"),
        services: AccountServiceEndpoints(
            accountBaseUrl: "https://account.example.com",
            contentBaseUrl: content,
            assistantBaseUrl: "https://assistant.example.com",
            mediaBaseUrl: nil
        ),
        capabilities: AccountCapabilities(contentJobs: true, assistantV2: true, videoMedia: false, quota: true, accountDeletion: true),
        limits: AccountLimits(maxMediaDurationSeconds: 14_400)
    )
}

private final class StubAccountGateway: AccountGatewaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshCount = 0
    private var _logoutCount = 0
    private var _deleteCount = 0
    private var _configTokens: [String] = []
    private var configResults: [Result<AccountConfig, AccountGatewayError>]
    let exchangeResult: AccountSessionTokens
    var refreshResult: Result<AccountSessionTokens, AccountGatewayError>
    var refreshDelayNanoseconds: UInt64 = 0

    init(
        exchange: AccountSessionTokens,
        refresh: Result<AccountSessionTokens, AccountGatewayError> = .failure(.transport("unused")),
        configs: [Result<AccountConfig, AccountGatewayError>] = [.success(sampleConfig())]
    ) {
        exchangeResult = exchange
        refreshResult = refresh
        configResults = configs
    }

    var refreshCount: Int { lock.withLock { _refreshCount } }
    var logoutCount: Int { lock.withLock { _logoutCount } }
    var deleteCount: Int { lock.withLock { _deleteCount } }
    var configTokens: [String] { lock.withLock { _configTokens } }

    func createChallenge(platform: String) async throws -> AppleSignInChallenge {
        AppleSignInChallenge(challengeId: "ach_1", nonce: "nonce-0123456789", expiresAt: "2026-09-14T08:05:00Z")
    }

    func exchange(challengeId: String, identityToken: String, authorizationCode: String, platform: String, deviceName: String?) async throws -> AccountSessionTokens {
        exchangeResult
    }

    func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        lock.withLock { _refreshCount += 1 }
        if refreshDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: refreshDelayNanoseconds) }
        return try refreshResult.get()
    }

    func logout(accessToken: String) async throws {
        lock.withLock { _logoutCount += 1 }
    }

    func config(accessToken: String) async throws -> AccountConfig {
        let result: Result<AccountConfig, AccountGatewayError> = lock.withLock {
            _configTokens.append(accessToken)
            return configResults.count > 1 ? configResults.removeFirst() : configResults[0]
        }
        return try result.get()
    }

    func quota(accessToken: String) async throws -> QuotaSnapshot {
        QuotaSnapshot(timezone: "Asia/Shanghai", periodKey: "2026-09-14", resetAt: "2026-09-14T16:00:00.000Z", enforced: true, buckets: [], concurrency: [])
    }

    func deleteAccount(accessToken: String) async throws {
        lock.withLock { _deleteCount += 1 }
    }
}

final class AccountSessionTests: XCTestCase {
    override func tearDown() {
        AccountServiceAccess.clear()
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    private func signIn(_ manager: AccountSessionManager) async throws {
        _ = try await manager.completeAppleSignIn(
            challengeId: "ach_1",
            identityToken: "identity-token",
            authorizationCode: "code",
            platform: "ios",
            deviceName: "Test iPhone"
        )
    }

    func testAppleSessionIsStoredPerServerAndNeverUsedForAnotherServer() async throws {
        let clock = TestClock(Date())
        let store = InMemoryAccountCredentialStore()
        let gateway = StubAccountGateway(exchange: sessionTokens(access: "official-access", refresh: "r1", expiresIn: 900, now: clock.now))
        let official = AccountSessionManager(profile: officialProfile, gateway: gateway, store: store, now: { clock.now })
        try await signIn(official)

        let bearer = try await official.bearerToken()
        XCTAssertEqual(bearer, "official-access")
        XCTAssertEqual(try store.load(profileID: officialProfile.id)?.kind, .appleSession)

        let other = AccountSessionManager(profile: selfHostedProfile, gateway: gateway, store: store, now: { clock.now })
        do {
            _ = try await other.bearerToken()
            XCTFail("a different server must not see the official session")
        } catch {
            XCTAssertEqual(error as? AccountSessionError, .signedOut)
        }

        let restored = AccountSessionManager(profile: officialProfile, gateway: gateway, store: store, now: { clock.now })
        let restoredSignedIn = await restored.isSignedIn
        XCTAssertTrue(restoredSignedIn, "cold start restores the stored session")
    }

    func testNearExpiryRefreshIsSingleFlight() async throws {
        let clock = TestClock(Date())
        let gateway = StubAccountGateway(
            exchange: sessionTokens(access: "old", refresh: "r1", expiresIn: 900, now: clock.now),
            refresh: .success(sessionTokens(access: "new", refresh: "r2", expiresIn: 1800, now: clock.now))
        )
        gateway.refreshDelayNanoseconds = 50_000_000
        let manager = AccountSessionManager(profile: officialProfile, gateway: gateway, store: InMemoryAccountCredentialStore(), now: { clock.now })
        try await signIn(manager)
        clock.advance(870)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await manager.bearerToken() } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(tokens), ["new"])
        XCTAssertEqual(gateway.refreshCount, 1)
    }

    func testReusedRefreshTokenEndsTheSession() async throws {
        let clock = TestClock(Date())
        let store = InMemoryAccountCredentialStore()
        let gateway = StubAccountGateway(
            exchange: sessionTokens(access: "old", refresh: "r1", expiresIn: 900, now: clock.now),
            refresh: .failure(.http(status: 401, code: "REFRESH_TOKEN_REUSED", retryAfterSeconds: nil))
        )
        let manager = AccountSessionManager(profile: officialProfile, gateway: gateway, store: store, now: { clock.now })
        try await signIn(manager)
        clock.advance(900)
        do {
            _ = try await manager.bearerToken()
            XCTFail("expected refresh failure")
        } catch {
            XCTAssertEqual(error as? AccountSessionError, .gateway(.http(status: 401, code: "REFRESH_TOKEN_REUSED", retryAfterSeconds: nil)))
        }
        let signedIn = await manager.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try store.load(profileID: officialProfile.id))
    }

    func testExpiredAccessTokenIsRenewedOnceThenRetried() async throws {
        let clock = TestClock(Date())
        let gateway = StubAccountGateway(
            exchange: sessionTokens(access: "old", refresh: "r1", expiresIn: 900, now: clock.now),
            refresh: .success(sessionTokens(access: "new", refresh: "r2", expiresIn: 900, now: clock.now)),
            configs: [
                .success(sampleConfig()),
                .failure(.http(status: 401, code: "ACCESS_TOKEN_EXPIRED", retryAfterSeconds: nil)),
                .success(sampleConfig(content: "https://content-2.example.com"))
            ]
        )
        let manager = AccountSessionManager(profile: officialProfile, gateway: gateway, store: InMemoryAccountCredentialStore(), now: { clock.now })
        try await signIn(manager)
        let config = try await manager.config(forceRefresh: true)
        XCTAssertEqual(config.services.contentBaseUrl, "https://content-2.example.com")
        XCTAssertEqual(gateway.configTokens, ["old", "old", "new"])
        XCTAssertEqual(gateway.refreshCount, 1)
    }

    func testSelfHostedTokenIsVerifiedBeforeItIsStored() async throws {
        let store = InMemoryAccountCredentialStore()
        let rejecting = StubAccountGateway(
            exchange: sessionTokens(access: "unused", refresh: "unused", expiresIn: 900, now: Date()),
            configs: [.failure(.http(status: 401, code: "AUTH_REQUIRED", retryAfterSeconds: nil))]
        )
        let manager = AccountSessionManager(profile: selfHostedProfile, gateway: rejecting, store: store)
        do {
            _ = try await manager.connectSelfHosted(token: "wrong-token")
            XCTFail("expected rejection")
        } catch {}
        XCTAssertNil(try store.load(profileID: selfHostedProfile.id))

        let accepting = StubAccountGateway(
            exchange: sessionTokens(access: "unused", refresh: "unused", expiresIn: 900, now: Date()),
            configs: [.success(sampleConfig(accountId: "selfhost"))]
        )
        let connected = AccountSessionManager(profile: selfHostedProfile, gateway: accepting, store: store)
        let config = try await connected.connectSelfHosted(token: "  deployment-token  ")
        XCTAssertEqual(config.account.accountId, "selfhost")
        let bearer = try await connected.bearerToken()
        XCTAssertEqual(bearer, "deployment-token")
        XCTAssertEqual(try store.load(profileID: selfHostedProfile.id)?.kind, .selfHostedToken)
        XCTAssertNil(try store.load(profileID: officialProfile.id))
    }

    func testSignOutAndDeletionClearCredentials() async throws {
        let store = InMemoryAccountCredentialStore()
        let gateway = StubAccountGateway(exchange: sessionTokens(access: "a", refresh: "r", expiresIn: 900, now: Date()))
        let manager = AccountSessionManager(profile: officialProfile, gateway: gateway, store: store)
        try await signIn(manager)
        await manager.signOut()
        XCTAssertEqual(gateway.logoutCount, 1)
        XCTAssertNil(try store.load(profileID: officialProfile.id))

        try await signIn(manager)
        try await manager.deleteAccount()
        XCTAssertEqual(gateway.deleteCount, 1)
        let signedIn = await manager.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testAccountGatewayWireShapesAndErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let gateway = AccountGateway(baseURL: URL(string: "https://account.example.com/")!, session: URLSession(configuration: configuration))
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/apple/exchange")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: String]
            XCTAssertEqual(body?["challengeId"], "ach_1")
            XCTAssertEqual(body?["identityToken"], "id-token")
            XCTAssertEqual(body?["authorizationCode"], "auth-code")
            XCTAssertEqual(body?["platform"], "tvos")
            let error = #"{"error":{"code":"APPLE_TOKEN_INVALID","message":"x","retryable":false,"params":{"check":"nonce"},"traceId":"tr_1"}}"#
            return (401, Data(error.utf8), ["Retry-After": "7"])
        }
        do {
            _ = try await gateway.exchange(challengeId: "ach_1", identityToken: "id-token", authorizationCode: "auth-code", platform: "tvos", deviceName: nil)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccountGatewayError, .http(status: 401, code: "APPLE_TOKEN_INVALID", retryAfterSeconds: 7))
        }

        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/me/quota")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lca_token")
            let body = #"{"timezone":"Asia/Shanghai","periodKey":"2026-09-14","resetAt":"2026-09-14T16:00:00.000Z","enforced":true,"buckets":[{"kind":"media","unit":"seconds","limit":1800,"used":300,"reserved":900,"remaining":600}],"concurrency":[{"kind":"media","limit":1,"running":1,"queued":0}]}"#
            return (200, Data(body.utf8), [:])
        }
        let quota = try await gateway.quota(accessToken: "lca_token")
        XCTAssertEqual(quota.buckets.first?.remaining, 600)
    }

    func testContentClientRenewsAnExpiredAccessTokenExactlyOnce() async throws {
        let clock = TestClock(Date())
        let gateway = StubAccountGateway(
            exchange: sessionTokens(access: "old", refresh: "r1", expiresIn: 900, now: clock.now),
            refresh: .success(sessionTokens(access: "new", refresh: "r2", expiresIn: 900, now: clock.now))
        )
        let manager = AccountSessionManager(profile: officialProfile, gateway: gateway, store: InMemoryAccountCredentialStore(), now: { clock.now })
        try await signIn(manager)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let client = try CloudContentJobClient.makeDefault(
            baseURLString: "https://content.example.com",
            tokenProvider: AccountSessionTokenProvider(manager: manager),
            session: URLSession(configuration: configuration)
        )
        let job = try Data(contentsOf: CloudContentGatewayTests.fixturesDir.appendingPathComponent("job-queued.json"))
        let expired = Data(#"{"error":{"code":"ACCESS_TOKEN_EXPIRED","message":"expired","retryable":true,"traceId":"tr"}}"#.utf8)
        ScriptedURLProtocol.handler = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? (200, job, [:]) : (401, expired, [:])
        }
        _ = try await client.getJob(jobID: "cj_01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 2)
        XCTAssertEqual(gateway.refreshCount, 1)

        ScriptedURLProtocol.reset()
        let denied = Data(#"{"error":{"code":"SESSION_REVOKED","message":"revoked","retryable":false,"traceId":"tr"}}"#.utf8)
        ScriptedURLProtocol.handler = { _ in (401, denied, [:]) }
        do {
            _ = try await client.getJob(jobID: "cj_01ARZ3NDEKTSV4RRFFQ69G5FAV")
            XCTFail("expected 401")
        } catch {
            XCTAssertTrue((error as? CloudContentError)?.isUnauthorized == true)
        }
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1, "only ACCESS_TOKEN_EXPIRED is retried")
    }

    func testConfigurationFollowsPublishedAccountAccess() async throws {
        var configuration = AppConfiguration()
        configuration.contentServiceEnabled = false
        XCTAssertFalse(configuration.isCloudGenerationUsable)

        let manager = AccountSessionManager(
            profile: officialProfile,
            gateway: StubAccountGateway(exchange: sessionTokens(access: "a", refresh: "r", expiresIn: 900, now: Date())),
            store: InMemoryAccountCredentialStore()
        )
        AccountServiceAccess.publish(
            AccountServiceAccessSnapshot(profileID: officialProfile.id, config: sampleConfig()),
            tokenProvider: AccountSessionTokenProvider(manager: manager)
        )
        XCTAssertTrue(configuration.isCloudGenerationUsable)
        XCTAssertTrue(configuration.isAssistantServiceUsable)
        XCTAssertEqual(configuration.normalizedContentServiceBaseURL, "https://content.example.com")
        XCTAssertEqual(configuration.normalizedAssistantServiceBaseURL, "https://assistant.example.com")

        AccountServiceAccess.clear()
        XCTAssertFalse(configuration.isCloudGenerationUsable)
        XCTAssertEqual(configuration.normalizedContentServiceBaseURL, AppConfiguration.defaultContentServiceBaseURL)
    }

    func testServerAddressNormalization() {
        XCTAssertEqual(AccountServerProfile.normalizedURL(" https://my.example.org/ ")?.absoluteString, "https://my.example.org")
        XCTAssertNil(AccountServerProfile.normalizedURL("http://my.example.org"))
        XCTAssertEqual(AccountServerProfile.normalizedURL("http://localhost:3240")?.absoluteString, "http://localhost:3240")
        XCTAssertNil(AccountServerProfile.normalizedURL(""))
        XCTAssertNil(AccountServerProfile.normalizedURL("ftp://server"))
        XCTAssertNotEqual(officialProfile.id, selfHostedProfile.id)
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
