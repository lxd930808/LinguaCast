import Foundation

// Assistant API DTOs (V13 / WP9). Wire format is frozen by
// docs/contracts/assistant-v1.openapi.yaml. Unknown enum values decode to
// .unknown(raw) and never crash. Unknown JSON fields are ignored.

public enum AssistantSessionPhase: Hashable, Sendable {
    case researching
    case reportReady
    case sourceSelected
    case preparingContent
    case transcriptReady
    case qaReady
    case recoverableError
    case deleting
    case deleted
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .researching: return "researching"
        case .reportReady: return "report_ready"
        case .sourceSelected: return "source_selected"
        case .preparingContent: return "preparing_content"
        case .transcriptReady: return "transcript_ready"
        case .qaReady: return "qa_ready"
        case .recoverableError: return "recoverable_error"
        case .deleting: return "deleting"
        case .deleted: return "deleted"
        case .unknown(let raw): return raw
        }
    }
}

extension AssistantSessionPhase: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "researching": self = .researching
        case "report_ready": self = .reportReady
        case "source_selected": self = .sourceSelected
        case "preparing_content": self = .preparingContent
        case "transcript_ready": self = .transcriptReady
        case "qa_ready": self = .qaReady
        case "recoverable_error": self = .recoverableError
        case "deleting": self = .deleting
        case "deleted": self = .deleted
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantTurnKind: String, Codable, Hashable, Sendable {
    case research
    case qa
}

public enum AssistantTurnStatus: Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case unknown(String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .unknown: return false
        }
    }

    public var rawValue: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .unknown(let raw): return raw
        }
    }
}

extension AssistantTurnStatus: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "queued": self = .queued
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantPlatform: Hashable, Sendable {
    case youtube
    case applePodcasts
    case podcast
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .youtube: return "youtube"
        case .applePodcasts: return "apple_podcasts"
        case .podcast: return "podcast"
        case .unknown(let raw): return raw
        }
    }
}

extension AssistantPlatform: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "youtube": self = .youtube
        case "apple_podcasts": self = .applePodcasts
        case "podcast": self = .podcast
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantSourceType: Hashable, Sendable {
    case video
    case podcastShow
    case podcastEpisode
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .video: return "video"
        case .podcastShow: return "podcast_show"
        case .podcastEpisode: return "podcast_episode"
        case .unknown(let raw): return raw
        }
    }
}

extension AssistantSourceType: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "video": self = .video
        case "podcast_show": self = .podcastShow
        case "podcast_episode": self = .podcastEpisode
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AssistantErrorBody: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public var retryAfterSeconds: Int?
    public var traceId: String
    public var params: [String: String]?

    public init(
        code: String,
        message: String,
        retryable: Bool,
        retryAfterSeconds: Int? = nil,
        traceId: String,
        params: [String: String]? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.retryAfterSeconds = retryAfterSeconds
        self.traceId = traceId
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        retryAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
        traceId = try container.decodeIfPresent(String.self, forKey: .traceId) ?? ""
        if let raw = try container.decodeIfPresent([String: AssistantJSONValue].self, forKey: .params) {
            params = raw.mapValues(\.stringValue)
        } else {
            params = nil
        }
    }
}

private enum AssistantJSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        self = .string((try? container.decode(String.self)) ?? "")
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        }
    }
}

public struct AssistantErrorEnvelope: Codable, Hashable, Sendable {
    public var error: AssistantErrorBody
}

public struct AssistantSessionCreateRequest: Codable, Hashable, Sendable {
    public var outputLanguage: String?
    public var storefront: String?
    public var targetLanguage: String?
    public var translationQuality: CloudTranslationQuality?
    public var title: String?

    public init(
        outputLanguage: String? = nil,
        storefront: String? = nil,
        targetLanguage: String? = nil,
        translationQuality: CloudTranslationQuality? = nil,
        title: String? = nil
    ) {
        self.outputLanguage = outputLanguage
        self.storefront = storefront
        self.targetLanguage = targetLanguage
        self.translationQuality = translationQuality
        self.title = title
    }
}

public struct AssistantClientContext: Codable, Hashable, Sendable {
    public var outputLanguage: String?
    public var storefront: String?
    public var locale: String?

    public init(outputLanguage: String? = nil, storefront: String? = nil, locale: String? = nil) {
        self.outputLanguage = outputLanguage
        self.storefront = storefront
        self.locale = locale
    }
}

public struct AssistantTurnCreateRequest: Codable, Hashable, Sendable {
    public var kind: AssistantTurnKind
    public var text: String
    public var clientContext: AssistantClientContext?

    public init(kind: AssistantTurnKind, text: String, clientContext: AssistantClientContext? = nil) {
        self.kind = kind
        self.text = text
        self.clientContext = clientContext
    }
}

public struct AssistantSourceBindRequest: Codable, Hashable, Sendable {
    public var searchResultId: String
    public var targetLanguage: String
    public var translationQuality: CloudTranslationQuality

    public init(searchResultId: String, targetLanguage: String, translationQuality: CloudTranslationQuality) {
        self.searchResultId = searchResultId
        self.targetLanguage = targetLanguage
        self.translationQuality = translationQuality
    }
}

public struct AssistantSessionSummary: Codable, Hashable, Sendable {
    public var sessionId: String
    public var title: String
    public var phase: AssistantSessionPhase
    public var createdAt: Date
    public var updatedAt: Date
    public var activeTurnId: String?
}

public struct AssistantSessionListResponse: Codable, Hashable, Sendable {
    public var sessions: [AssistantSessionSummary]
    public var nextCursor: String?
}

public struct AssistantTurnSummary: Codable, Hashable, Sendable {
    public var turnId: String
    public var sessionId: String
    public var kind: AssistantTurnKind
    public var status: AssistantTurnStatus
    public var eventsURL: String?
    public var error: AssistantErrorBody?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
}

public struct AssistantTurnAcceptedResponse: Codable, Hashable, Sendable {
    public var turnId: String
    public var sessionId: String
    public var kind: AssistantTurnKind
    public var status: AssistantTurnStatus
    public var eventsURL: String
    public var reused: Bool?
}

public struct AssistantPlayerTarget: Codable, Hashable, Sendable {
    public var contentKey: String
    public var startMs: Int
    public var endMs: Int

    public init(contentKey: String, startMs: Int, endMs: Int) {
        self.contentKey = contentKey
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct AssistantCitation: Codable, Hashable, Sendable {
    public var citationId: String
    public var contentKey: String
    public var startMs: Int
    public var endMs: Int
    public var quote: String
    public var playerTarget: AssistantPlayerTarget
    public var deepLink: String
}

public struct AssistantMessage: Codable, Hashable, Sendable {
    public var messageId: String
    public var sessionId: String
    public var turnId: String
    public var role: String
    public var markdown: String
    public var citations: [AssistantCitation]?
    public var createdAt: Date
}

public struct AssistantSearchResult: Codable, Hashable, Sendable {
    public var searchResultId: String
    public var platform: AssistantPlatform
    public var sourceType: AssistantSourceType
    public var sourceId: String
    public var canonicalURL: String
    public var feedURL: String?
    public var title: String
    public var publisher: String?
    public var publishedAt: Date?
    public var durationSeconds: Int?
    public var description: String?
    public var thumbnailURL: String?
    public var availability: String?
    public var provider: String?
    public var fallback: Bool?
    public var deepResearchAvailability: String
    public var warnings: [String]?
    public var searchRunId: String?
    public var rank: Int?
    public var relevanceScore: Double?
    public var matchReason: String?
    public var retrievedAt: Date?
    public var qualified: Bool?
    public var itunesId: String?
    public var guid: String?
    public var language: String?
    public var podcastIndexFeedId: Int?
    public var podcastIndexEpisodeId: Int?
    public var enclosureUrl: String? = nil
    public var enclosureType: String? = nil

    /// Audio to play or repair. Episode pages (Apple, show sites) stay on `canonicalURL`.
    public var playbackAudioURL: String {
        let enclosure = enclosureUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return enclosure.isEmpty ? canonicalURL : enclosure
    }
}

public struct AssistantSearchResultListResponse: Codable, Hashable, Sendable {
    public var results: [AssistantSearchResult]
}

public struct AssistantReportSource: Codable, Hashable, Sendable {
    public var searchResultId: String
    public var ordinal: Int
    public var reason: String?
}

public struct AssistantSourceGroup: Codable, Hashable, Sendable {
    public var reportId: String
    public var turnId: String
    public var title: String
    public var createdAt: Date?
    public var sources: [AssistantReportSource]
}

public struct AssistantReport: Codable, Hashable, Sendable {
    public var title: String
    public var summary: String
    public var stage: String
    public var markdown: String?
    public var sources: [AssistantReportSource]
    public var createdAt: Date?
}

public struct AssistantContentBinding: Codable, Hashable, Sendable {
    public var bindingId: String
    public var sessionId: String
    public var searchResultId: String
    public var contentKey: String
    public var contentType: CloudContentType
    public var targetLanguage: String
    public var translationQuality: CloudTranslationQuality
    public var v10JobId: String?
    public var status: String
    public var stage: String?
    public var progress: Double?
    public var indexStatus: String
    public var error: AssistantErrorBody?
    public var reused: Bool?
    public var updatedAt: Date?
}

public enum AssistantSourceCardPhase: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed
}

public enum AssistantSourceCardPolicy {
    /// Play is gated on V10 completion, not assistant FTS `indexStatus`.
    public static func isPlayReady(_ binding: AssistantContentBinding) -> Bool {
        binding.status == "ready" || binding.stage == "completed"
    }

    public static func phase(
        searchResultId: String,
        binding: AssistantContentBinding?
    ) -> AssistantSourceCardPhase {
        guard let binding, binding.searchResultId == searchResultId else { return .idle }
        if binding.error != nil || binding.status == "failed" { return .failed }
        if isPlayReady(binding) { return .ready }
        return .preparing
    }

    public static func pipelineStep(for binding: AssistantContentBinding) -> String {
        CloudPodcastProjectionPolicy.mapStage(CloudJobStage(rawValue: binding.stage ?? ""))
    }
}

public struct AssistantSourceListResponse: Codable, Hashable, Sendable {
    public var binding: AssistantContentBinding?
}

public struct AssistantSessionSnapshot: Codable, Hashable, Sendable {
    public var sessionId: String
    public var title: String
    public var phase: AssistantSessionPhase
    public var outputLanguage: String?
    public var storefront: String?
    public var targetLanguage: String?
    public var translationQuality: CloudTranslationQuality?
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [AssistantMessage]
    public var report: AssistantReport?
    public var sourceGroups: [AssistantSourceGroup]?
    public var searchResults: [AssistantSearchResult]
    public var searchRuns: [AssistantSearchRun]?
    public var binding: AssistantContentBinding?
    public var activeTurn: AssistantTurnSummary?

    /// Newest-first recommended sources. Falls back to the latest `report` when
    /// talking to a server that does not yet send `sourceGroups`.
    public var resolvedSourceGroups: [AssistantSourceGroup] {
        if let sourceGroups {
            return sourceGroups
        }
        guard let report, !report.sources.isEmpty else { return [] }
        return [
            AssistantSourceGroup(
                reportId: "",
                turnId: "",
                title: report.title,
                createdAt: report.createdAt,
                sources: report.sources
            )
        ]
    }
}

public struct AssistantProviderStatus: Codable, Hashable, Sendable {
    public var provider: String
    public var status: String
    public var latencyMs: Int?
    public var cacheHit: Bool?
    public var errorCode: String?
    public var retryAfterSeconds: Int?
    public var acceptedCount: Int?
}

public struct AssistantSearchRun: Codable, Hashable, Sendable {
    public var searchRunId: String
    public var sessionId: String
    public var turnId: String
    public var provider: String
    public var query: String
    public var status: String
    public var createdAt: Date
    public var intent: String?
    public var results: [AssistantSearchResult]?
    public var providerStatus: [AssistantProviderStatus]?
    public var warnings: [String]?
    public var nextCursor: String?
}

public struct AssistantSearchRunListResponse: Codable, Hashable, Sendable {
    public var runs: [AssistantSearchRun]
    public var nextCursor: String?
}

public struct AssistantSseEventData: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var sessionId: String
    public var turnId: String
    public var sequence: Int
    public var occurredAt: Date
    public var payload: [String: AssistantJSONLeaf]
}

public enum AssistantJSONLeaf: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        self = .null
    }
}

public enum AssistantSseEventType: Hashable, Sendable {
    case turnAccepted
    case turnStarted
    case toolStarted
    case toolCompleted
    case messageDelta
    case reportReady
    case contentProgress
    case transcriptReady
    case citationReady
    case turnCompleted
    case turnFailed
    case turnCancelled
    case heartbeat
    case searchPlanReady
    case searchSourceStarted
    case searchSourceCompleted
    case searchResultsRanked
    case sessionTitleUpdated
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "turn.accepted": self = .turnAccepted
        case "turn.started": self = .turnStarted
        case "tool.started": self = .toolStarted
        case "tool.completed": self = .toolCompleted
        case "message.delta": self = .messageDelta
        case "report.ready": self = .reportReady
        case "content.progress": self = .contentProgress
        case "transcript.ready": self = .transcriptReady
        case "citation.ready": self = .citationReady
        case "turn.completed": self = .turnCompleted
        case "turn.failed": self = .turnFailed
        case "turn.cancelled": self = .turnCancelled
        case "heartbeat": self = .heartbeat
        case "search.plan_ready": self = .searchPlanReady
        case "search.source_started": self = .searchSourceStarted
        case "search.source_completed": self = .searchSourceCompleted
        case "search.results_ranked": self = .searchResultsRanked
        case "session.title_updated": self = .sessionTitleUpdated
        default: self = .unknown(rawValue)
        }
    }
}
