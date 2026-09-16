import Foundation

// V18 account service wire models (docs/contracts/account-v1.openapi.yaml).
// Timestamps stay as ISO-8601 strings on the wire; `AccountDates` parses them.

public enum AccountAuthMode: String, Codable, Equatable, Sendable {
    case apple
    case selfhost
}

public struct AccountSummary: Codable, Equatable, Sendable {
    public var accountId: String
    public var authMode: AccountAuthMode
    public var status: String
    public var createdAt: String

    public init(accountId: String, authMode: AccountAuthMode, status: String, createdAt: String) {
        self.accountId = accountId
        self.authMode = authMode
        self.status = status
        self.createdAt = createdAt
    }
}

public struct AccountSessionTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var accessTokenExpiresAt: String
    public var refreshToken: String
    public var sessionExpiresAt: String
    public var sessionId: String
    public var account: AccountSummary

    public init(
        accessToken: String,
        accessTokenExpiresAt: String,
        refreshToken: String,
        sessionExpiresAt: String,
        sessionId: String,
        account: AccountSummary
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.sessionExpiresAt = sessionExpiresAt
        self.sessionId = sessionId
        self.account = account
    }
}

public struct AppleSignInChallenge: Codable, Equatable, Sendable {
    public var challengeId: String
    public var nonce: String
    public var expiresAt: String

    public init(challengeId: String, nonce: String, expiresAt: String) {
        self.challengeId = challengeId
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

public struct AccountServiceEndpoints: Codable, Equatable, Sendable {
    public var accountBaseUrl: String
    public var contentBaseUrl: String
    public var assistantBaseUrl: String
    public var mediaBaseUrl: String?

    public init(accountBaseUrl: String, contentBaseUrl: String, assistantBaseUrl: String, mediaBaseUrl: String?) {
        self.accountBaseUrl = accountBaseUrl
        self.contentBaseUrl = contentBaseUrl
        self.assistantBaseUrl = assistantBaseUrl
        self.mediaBaseUrl = mediaBaseUrl
    }
}

public struct AccountCapabilities: Codable, Equatable, Sendable {
    public var contentJobs: Bool
    public var assistantV2: Bool
    public var videoMedia: Bool
    public var quota: Bool
    public var accountDeletion: Bool

    public init(contentJobs: Bool, assistantV2: Bool, videoMedia: Bool, quota: Bool, accountDeletion: Bool) {
        self.contentJobs = contentJobs
        self.assistantV2 = assistantV2
        self.videoMedia = videoMedia
        self.quota = quota
        self.accountDeletion = accountDeletion
    }
}

public struct AccountLimits: Codable, Equatable, Sendable {
    public var maxMediaDurationSeconds: Int

    public init(maxMediaDurationSeconds: Int) {
        self.maxMediaDurationSeconds = maxMediaDurationSeconds
    }
}

/// `GET /v1/me/config`: service endpoints and capabilities. Never contains service secrets.
public struct AccountConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var account: AccountSummary
    public var services: AccountServiceEndpoints
    public var capabilities: AccountCapabilities
    public var limits: AccountLimits

    public init(
        schemaVersion: Int,
        account: AccountSummary,
        services: AccountServiceEndpoints,
        capabilities: AccountCapabilities,
        limits: AccountLimits
    ) {
        self.schemaVersion = schemaVersion
        self.account = account
        self.services = services
        self.capabilities = capabilities
        self.limits = limits
    }
}

public struct QuotaBucket: Codable, Equatable, Sendable {
    public var kind: String
    public var unit: String
    public var limit: Int
    public var used: Int
    public var reserved: Int
    public var remaining: Int

    public init(kind: String, unit: String, limit: Int, used: Int, reserved: Int, remaining: Int) {
        self.kind = kind
        self.unit = unit
        self.limit = limit
        self.used = used
        self.reserved = reserved
        self.remaining = remaining
    }
}

public struct QuotaConcurrency: Codable, Equatable, Sendable {
    public var kind: String
    public var limit: Int
    public var running: Int
    public var queued: Int

    public init(kind: String, limit: Int, running: Int, queued: Int) {
        self.kind = kind
        self.limit = limit
        self.running = running
        self.queued = queued
    }
}

/// `GET /v1/me/quota`: today's limits in the Asia/Shanghai period.
public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public var timezone: String
    public var periodKey: String
    public var resetAt: String
    public var enforced: Bool
    public var buckets: [QuotaBucket]
    public var concurrency: [QuotaConcurrency]

    public init(
        timezone: String,
        periodKey: String,
        resetAt: String,
        enforced: Bool,
        buckets: [QuotaBucket],
        concurrency: [QuotaConcurrency]
    ) {
        self.timezone = timezone
        self.periodKey = periodKey
        self.resetAt = resetAt
        self.enforced = enforced
        self.buckets = buckets
        self.concurrency = concurrency
    }
}

struct AccountServiceErrorEnvelope: Decodable {
    struct Body: Decodable {
        var code: String
        var message: String?
        var retryable: Bool?
        var retryAfterSeconds: Int?
    }

    var error: Body
}

public enum AccountErrorCodes {
    /// Contract error code carried by a response body, if any.
    public static func code(in data: Data) -> String? {
        try? JSONDecoder().decode(AccountServiceErrorEnvelope.self, from: data).error.code
    }

    public static func isExpiredAccessToken(_ data: Data) -> Bool {
        code(in: data) == "ACCESS_TOKEN_EXPIRED"
    }
}

public enum AccountDates {
    public static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
