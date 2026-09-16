import Foundation

// Shared assistant DTOs still used by the V2 client, playback preparation and deep
// links. The V1 session API they came from was removed in V18. Unknown enum values
// decode to .unknown(raw) and never crash. Unknown JSON fields are ignored.

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
