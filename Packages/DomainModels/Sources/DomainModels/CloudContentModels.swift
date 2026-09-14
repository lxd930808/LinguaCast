import Foundation
import SwiftData
import CryptoKit

// Cloud content contract models (V10 / WP0-WP9).
// Wire format is frozen by docs/contracts/content-job-v1.openapi.yaml and
// validated against the golden fixtures in
// ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/CloudContent.
// Rules:
//  - unknown enum values decode to .unknown(raw) and never crash
//  - unknown JSON fields are ignored
//  - signed URLs are NEVER stored in RemoteContentJobRecord

// MARK: - Tolerant enums

public enum CloudContentType: String, Codable, Hashable, Sendable {
    case podcastEpisode = "podcast_episode"
    case video
}

public enum CloudTranslationQuality: String, Codable, Hashable, Sendable {
    case fast
    case quality
}

public enum CloudJobStatus: Hashable, Sendable {
    case queued
    case running
    case ready
    case failed
    case cancelled
    case expired
    /// Forward-compatible: server-added states map here and are treated as
    /// non-terminal (polling continues, no local state is overwritten).
    case unknown(String)

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .cancelled, .expired: return true
        case .queued, .running, .unknown: return false
        }
    }

    public var rawValue: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .ready: return "ready"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .expired: return "expired"
        case .unknown(let raw): return raw
        }
    }
}

extension CloudJobStatus: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "queued": self = .queued
        case "running": self = .running
        case "ready": self = .ready
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "expired": self = .expired
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CloudJobStage: Hashable, Sendable {
    case validatingSource
    case fetchingAudio
    case preparingAudio
    case transcribing
    case segmenting
    case translating
    case refiningSubtitles
    case packaging
    case completed
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .validatingSource: return "validating_source"
        case .fetchingAudio: return "fetching_audio"
        case .preparingAudio: return "preparing_audio"
        case .transcribing: return "transcribing"
        case .segmenting: return "segmenting"
        case .translating: return "translating"
        case .refiningSubtitles: return "refining_subtitles"
        case .packaging: return "packaging"
        case .completed: return "completed"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "validating_source": self = .validatingSource
        case "fetching_audio": self = .fetchingAudio
        case "preparing_audio": self = .preparingAudio
        case "transcribing": self = .transcribing
        case "segmenting": self = .segmenting
        case "translating": self = .translating
        case "refining_subtitles": self = .refiningSubtitles
        case "packaging": self = .packaging
        case "completed": self = .completed
        default: self = .unknown(rawValue)
        }
    }
}

extension CloudJobStage: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - API DTOs

public struct CloudContentSource: Codable, Hashable, Sendable {
    public var platform: String
    public var sourceId: String
    public var url: String
    public var feedUrl: String?
    public var title: String?

    public init(platform: String, sourceId: String, url: String, feedUrl: String? = nil, title: String? = nil) {
        self.platform = platform
        self.sourceId = sourceId
        self.url = url
        self.feedUrl = feedUrl
        self.title = title
    }
}

public struct CloudContentJobCreateRequest: Codable, Hashable, Sendable {
    public var contentType: CloudContentType
    public var contentKey: String
    public var source: CloudContentSource
    public var sourceLanguage: String
    public var targetLanguage: String
    public var translationQuality: CloudTranslationQuality
    public var clientArtifactSchemaVersion: Int

    public init(
        contentType: CloudContentType,
        contentKey: String,
        source: CloudContentSource,
        sourceLanguage: String,
        targetLanguage: String,
        translationQuality: CloudTranslationQuality,
        clientArtifactSchemaVersion: Int = 1
    ) {
        self.contentType = contentType
        self.contentKey = contentKey
        self.source = source
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.translationQuality = translationQuality
        self.clientArtifactSchemaVersion = clientArtifactSchemaVersion
    }
}

public struct CloudJobError: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public var retryAfterSeconds: Int?
    public var failedStage: CloudJobStage?
    public var traceId: String
    public var params: [String: CloudJSONValue]?

    public init(
        code: String,
        message: String,
        retryable: Bool,
        retryAfterSeconds: Int? = nil,
        failedStage: CloudJobStage? = nil,
        traceId: String,
        params: [String: CloudJSONValue]? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.retryAfterSeconds = retryAfterSeconds
        self.failedStage = failedStage
        self.traceId = traceId
        self.params = params
    }
}

/// Minimal JSON value for error params (string/number/bool).
public enum CloudJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

public struct CloudArtifactFileRef: Codable, Hashable, Sendable {
    public var name: String
    public var role: String
    public var required: Bool
    public var status: String
    public var mimeType: String
    public var bytes: Int
    public var sha256: String
    public var etag: String?
}

public struct CloudAudioMetadata: Codable, Hashable, Sendable {
    public var mimeType: String
    public var bytes: Int
    public var durationSeconds: Double
    public var sha256: String
    public var transcoded: Bool
}

public struct CloudArtifactManifestRef: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var pipelineVersion: String
    public var generatedAt: Date
    public var audioFingerprint: String
    public var sourceFingerprint: String?
    public var audio: CloudAudioMetadata?
    public var files: [CloudArtifactFileRef]

    /// Highest artifact schema this client can consume.
    public static let supportedSchemaVersion = 1

    public var isCompatibleWithClient: Bool {
        schemaVersion <= Self.supportedSchemaVersion
    }
}

public struct CloudContentJobResponse: Codable, Hashable, Sendable {
    public var jobId: String
    public var reused: Bool?
    public var contentType: CloudContentType
    public var contentKey: String
    public var source: CloudContentSource?
    public var sourceLanguage: String
    public var targetLanguage: String
    public var translationQuality: CloudTranslationQuality
    public var pipelineVersion: String
    public var status: CloudJobStatus
    public var stage: CloudJobStage?
    public var progress: Double
    public var stageProgress: Double?
    public var audioReady: Bool
    public var subtitlesReady: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var retryAfterSeconds: Int
    public var error: CloudJobError?
    public var artifacts: CloudArtifactManifestRef?

    /// The stable local key used by RemoteContentJobRecord.
    public var stableKey: String {
        RemoteContentJobRecord.makeStableKey(
            contentKind: contentType.rawValue,
            contentKey: contentKey,
            targetLanguage: targetLanguage,
            translationQuality: translationQuality.rawValue,
            pipelineVersion: pipelineVersion
        )
    }
}

public struct CloudContentJobLookupResponse: Codable, Hashable, Sendable {
    public var job: CloudContentJobResponse?
}

public struct CloudAudioPlaybackURLResponse: Codable, Hashable, Sendable {
    public var url: URL
    public var expiresAt: Date
    public var mimeType: String
    public var bytes: Int
    public var durationSeconds: Double
    public var sha256: String
    public var acceptRanges: String
}

public struct CloudVideoPlaybackURLRequest: Codable, Hashable, Sendable {
    public var contentType: CloudContentType
    public var contentKey: String
    public var preferredHeight: Int?

    public init(
        contentType: CloudContentType = .video,
        contentKey: String,
        preferredHeight: Int? = nil
    ) {
        self.contentType = contentType
        self.contentKey = contentKey
        self.preferredHeight = preferredHeight
    }
}

public struct CloudVideoPlaybackURLResponse: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var mediaId: String
    public var contentType: CloudContentType
    public var contentKey: String
    public var url: URL
    public var expiresAt: Date
    public var mimeType: String
    public var bytes: Int
    public var sha256: String
    public var durationSeconds: Double
    public var height: Int
    public var videoCodec: String
    public var audioCodec: String
    public var acceptRanges: String
    public var mediaVersion: String
    public var createdAt: Date

    public init(
        schemaVersion: Int,
        mediaId: String,
        contentType: CloudContentType,
        contentKey: String,
        url: URL,
        expiresAt: Date,
        mimeType: String,
        bytes: Int,
        sha256: String,
        durationSeconds: Double,
        height: Int,
        videoCodec: String,
        audioCodec: String,
        acceptRanges: String,
        mediaVersion: String,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.mediaId = mediaId
        self.contentType = contentType
        self.contentKey = contentKey
        self.url = url
        self.expiresAt = expiresAt
        self.mimeType = mimeType
        self.bytes = bytes
        self.sha256 = sha256
        self.durationSeconds = durationSeconds
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.acceptRanges = acceptRanges
        self.mediaVersion = mediaVersion
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mediaId, contentType, contentKey, url, expiresAt
        case mimeType, bytes, sha256, durationSeconds, height, videoCodec
        case audioCodec, acceptRanges, mediaVersion, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported video playback schemaVersion \(schemaVersion)"
            )
        }
        mediaId = try container.decode(String.self, forKey: .mediaId)
        contentType = try container.decode(CloudContentType.self, forKey: .contentType)
        contentKey = try container.decode(String.self, forKey: .contentKey)
        url = try container.decode(URL.self, forKey: .url)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        bytes = try container.decode(Int.self, forKey: .bytes)
        sha256 = try container.decode(String.self, forKey: .sha256)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        height = try container.decode(Int.self, forKey: .height)
        videoCodec = try container.decode(String.self, forKey: .videoCodec)
        audioCodec = try container.decode(String.self, forKey: .audioCodec)
        acceptRanges = try container.decode(String.self, forKey: .acceptRanges)
        mediaVersion = try container.decode(String.self, forKey: .mediaVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mediaId, forKey: .mediaId)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(contentKey, forKey: .contentKey)
        try container.encode(url, forKey: .url)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(height, forKey: .height)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(audioCodec, forKey: .audioCodec)
        try container.encode(acceptRanges, forKey: .acceptRanges)
        try container.encode(mediaVersion, forKey: .mediaVersion)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct CloudErrorEnvelope: Codable, Hashable, Sendable {
    public var error: CloudJobError
}

// MARK: - Persistent record (SwiftData)

/**
 * Remote job tracking record. Keyed by the generation variant stable key so
 * app restarts and cross-device handoff can reconcile via lookup. Signed
 * playback URLs are intentionally NOT persisted (security requirement).
 */
@Model
public final class RemoteContentJobRecord {
    @Attribute(.unique) public var stableKey: String
    public var contentKind: String
    public var contentKey: String
    public var jobID: String
    public var statusRaw: String
    public var stageRaw: String?
    public var progress: Double
    public var audioReady: Bool
    public var subtitlesReady: Bool
    public var targetLanguage: String
    public var translationQuality: String
    public var pipelineVersion: String
    public var errorCode: String?
    public var errorRetryable: Bool
    public var errorTraceID: String?
    public var manifestSchemaVersion: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        stableKey: String,
        contentKind: String,
        contentKey: String,
        jobID: String,
        statusRaw: String,
        stageRaw: String? = nil,
        progress: Double = 0,
        audioReady: Bool = false,
        subtitlesReady: Bool = false,
        targetLanguage: String,
        translationQuality: String,
        pipelineVersion: String,
        errorCode: String? = nil,
        errorRetryable: Bool = false,
        errorTraceID: String? = nil,
        manifestSchemaVersion: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.stableKey = stableKey
        self.contentKind = contentKind
        self.contentKey = contentKey
        self.jobID = jobID
        self.statusRaw = statusRaw
        self.stageRaw = stageRaw
        self.progress = progress
        self.audioReady = audioReady
        self.subtitlesReady = subtitlesReady
        self.targetLanguage = targetLanguage
        self.translationQuality = translationQuality
        self.pipelineVersion = pipelineVersion
        self.errorCode = errorCode
        self.errorRetryable = errorRetryable
        self.errorTraceID = errorTraceID
        self.manifestSchemaVersion = manifestSchemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func makeStableKey(
        contentKind: String,
        contentKey: String,
        targetLanguage: String,
        translationQuality: String,
        pipelineVersion: String
    ) -> String {
        [contentKind, contentKey, targetLanguage, translationQuality, pipelineVersion].joined(separator: "|")
    }

    /// Server state is the source of truth; progress never regresses.
    public func apply(_ job: CloudContentJobResponse) {
        jobID = job.jobId
        statusRaw = job.status.rawValue
        stageRaw = job.stage?.rawValue
        progress = max(progress, job.progress)
        audioReady = audioReady || job.audioReady
        subtitlesReady = subtitlesReady || job.subtitlesReady
        if let error = job.error {
            errorCode = error.code
            errorRetryable = error.retryable
            errorTraceID = error.traceId
        } else if job.status != .failed {
            errorCode = nil
            errorRetryable = false
            errorTraceID = nil
        }
        manifestSchemaVersion = job.artifacts?.schemaVersion ?? manifestSchemaVersion
        updatedAt = job.updatedAt
    }
}

// MARK: - Content key policy (must match docs/contracts/content-keys-v1.md)

public enum CloudContentKeyPolicy {
    public static func podcastContentKey(feedURL: String, episodeGUID: String) -> String {
        let feed = normalizeFeedURL(feedURL)
        let guid = episodeGUID.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespaces)
        return "podcast:\(sha256Hex16(feed)):\(sha256Hex16(guid))"
    }

    /// Feed identity for content-key lookup. Assistant episodes store the RSS
    /// URL on the episode itself (no subscription), so that must win over the
    /// enclosure — which is often an Apple episode page, not the feed.
    public static func podcastFeedIdentity(
        subscriptionFeedURL: String?,
        assistantFeedURL: String?,
        enclosureURL: String
    ) -> String {
        let subscription = (subscriptionFeedURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !subscription.isEmpty { return subscription }
        let assistant = (assistantFeedURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !assistant.isEmpty { return assistant }
        if let enclosure = URL(string: enclosureURL), let host = enclosure.host {
            return "\(enclosure.scheme ?? "https")://\(host)\(enclosure.path)"
        }
        return enclosureURL
    }

    public static func videoContentKey(platform: String, videoID: String) -> String {
        let id = videoID.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespaces)
        return "video:\(platform.lowercased()):\(id)"
    }

    public static func normalizeFeedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        let scheme = (components.scheme ?? "https").lowercased()
        let host = (components.host ?? "").lowercased()
        var port = components.port
        if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            port = nil
        }
        var path = components.percentEncodedPath.precomposedStringWithCanonicalMapping
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.scheme = scheme
        components.host = host
        components.port = port
        components.fragment = nil
        components.percentEncodedPath = path
        return components.string ?? raw
    }

    private static func sha256Hex16(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Progress / polling policies

public enum CloudProgressMergePolicy {
    /// Local progress must never regress when server updates arrive.
    public static func merged(existing: Double, incoming: Double) -> Double {
        max(existing, min(max(incoming, 0), 1))
    }
}

public enum CloudPollPolicy {
    public static let minimumSeconds = 1
    public static let maximumSeconds = 60

    /// Server retryAfterSeconds is the primary hint; clamp to sane bounds.
    public static func nextIntervalSeconds(serverHint: Int?) -> TimeInterval {
        let hint = serverHint ?? 5
        return TimeInterval(min(max(hint, minimumSeconds), maximumSeconds))
    }
}

// MARK: - Error presentation policy

public enum CloudErrorCategory: String, Sendable {
    case needsUpgrade
    case sourceGone
    case sourceRestricted
    case rateLimited
    case capacity
    case retryableFailure
    case fatalFailure
    case unknown
}

public enum CloudErrorPresentationPolicy {
    public static func category(forCode code: String) -> CloudErrorCategory {
        switch code {
        case "PIPELINE_VERSION_UNSUPPORTED": return .needsUpgrade
        case "SOURCE_UNAVAILABLE": return .sourceGone
        case "SOURCE_RESTRICTED": return .sourceRestricted
        case "SOURCE_RATE_LIMITED": return .rateLimited
        case "QUEUE_BUSY", "STORAGE_FULL": return .capacity
        case "AUDIO_DOWNLOAD_FAILED", "ASR_FAILED", "TRANSLATION_FAILED",
             "ARTIFACT_PUBLISH_FAILED", "INTERNAL_ERROR":
            return .retryableFailure
        case "ASR_SUBMISSION_UNCERTAIN", "MEDIA_TOO_LARGE", "MEDIA_TOO_LONG", "UNSUPPORTED_AUDIO":
            return .fatalFailure
        default:
            return .unknown
        }
    }
}

// MARK: - Projection to existing display models

public struct CloudPodcastPipelineProjection: Equatable, Sendable {
    public var status: String
    public var pipelineStep: String
    public var progress: Double
    public var errorMessage: String?

    public init(status: String, pipelineStep: String, progress: Double, errorMessage: String?) {
        self.status = status
        self.pipelineStep = pipelineStep
        self.progress = progress
        self.errorMessage = errorMessage
    }
}

public enum CloudPodcastProjectionPolicy {
    /// Maps cloud job state onto the existing EpisodeRecord display fields so
    /// current UI keeps working unchanged during the V10 migration.
    public static func project(_ job: CloudContentJobResponse) -> CloudPodcastPipelineProjection {
        switch job.status {
        case .ready:
            return CloudPodcastPipelineProjection(
                status: "completed", pipelineStep: "completed", progress: 1, errorMessage: nil
            )
        case .failed:
            return CloudPodcastPipelineProjection(
                status: "failed",
                pipelineStep: mapStage(job.stage),
                progress: job.progress,
                errorMessage: job.error.map { "\($0.code): \($0.message)" }
            )
        case .cancelled:
            return CloudPodcastPipelineProjection(
                status: "cancelled", pipelineStep: mapStage(job.stage), progress: job.progress, errorMessage: nil
            )
        case .expired:
            return CloudPodcastPipelineProjection(
                status: "failed", pipelineStep: "expired", progress: job.progress,
                errorMessage: "Content job expired on the server"
            )
        case .queued:
            return CloudPodcastPipelineProjection(
                status: "queued", pipelineStep: "queued", progress: job.progress, errorMessage: nil
            )
        case .running, .unknown:
            return CloudPodcastPipelineProjection(
                status: "running", pipelineStep: mapStage(job.stage), progress: job.progress, errorMessage: nil
            )
        }
    }

    /// Cloud stages map onto the existing local step vocabulary so current UI
    /// strings keep working; audio fetch stays "download" etc.
    static func mapStage(_ stage: CloudJobStage?) -> String {
        switch stage {
        case .validatingSource: return "cloud_validate"
        case .fetchingAudio: return "download"
        case .preparingAudio: return "cloud_prepare"
        case .transcribing: return "transcribe"
        case .segmenting: return "segment_source"
        case .translating: return "translate"
        case .refiningSubtitles: return "refine_subtitles"
        case .packaging: return "package"
        case .completed: return "completed"
        case .unknown, .none: return "cloud_processing"
        }
    }
}

public struct CloudYTSourceProjection: Equatable, Sendable {
    public var subtitleStatus: String
    public var sourceGenerationStep: String?
    public var sourceGenerationProgress: Double?

    public init(subtitleStatus: String, sourceGenerationStep: String?, sourceGenerationProgress: Double?) {
        self.subtitleStatus = subtitleStatus
        self.sourceGenerationStep = sourceGenerationStep
        self.sourceGenerationProgress = sourceGenerationProgress
    }
}

public enum CloudYTProjectionPolicy {
    /// Maps cloud job state onto YTVideoRecord's sourceGeneration fields.
    public static func project(_ job: CloudContentJobResponse) -> CloudYTSourceProjection {
        switch job.status {
        case .ready:
            return CloudYTSourceProjection(
                subtitleStatus: "ready", sourceGenerationStep: "completed", sourceGenerationProgress: 1
            )
        case .failed:
            return CloudYTSourceProjection(
                subtitleStatus: "failed",
                sourceGenerationStep: job.error?.failedStage?.rawValue ?? job.stage?.rawValue,
                sourceGenerationProgress: job.progress
            )
        case .cancelled:
            return CloudYTSourceProjection(
                subtitleStatus: "not_requested", sourceGenerationStep: nil, sourceGenerationProgress: nil
            )
        case .expired:
            return CloudYTSourceProjection(
                subtitleStatus: "failed", sourceGenerationStep: "expired", sourceGenerationProgress: job.progress
            )
        case .queued, .running, .unknown:
            return CloudYTSourceProjection(
                subtitleStatus: "generating",
                sourceGenerationStep: job.stage?.rawValue ?? "queued",
                sourceGenerationProgress: job.progress
            )
        }
    }
}
