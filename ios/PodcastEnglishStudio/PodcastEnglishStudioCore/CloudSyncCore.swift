import CryptoKit
import Foundation

public enum SyncDocumentKind: String, Codable, Hashable, Sendable {
    case configuration
    case podcastSubscription
    case youtubeSubscription
}

public struct SyncFieldVersion: Codable, Hashable, Sendable, Comparable {
    public var modifiedAt: Date
    public var deviceID: String

    public init(modifiedAt: Date, deviceID: String) {
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt < rhs.modifiedAt
        }
        return lhs.deviceID < rhs.deviceID
    }
}

public struct SyncFieldValue: Codable, Hashable, Sendable {
    public var value: String
    public var version: SyncFieldVersion

    public init(value: String, version: SyncFieldVersion) {
        self.value = value
        self.version = version
    }
}

public struct SyncDocument: Codable, Hashable, Sendable {
    public var recordName: String
    public var kind: SyncDocumentKind
    public var fields: [String: SyncFieldValue]
    public var deletionVersion: SyncFieldVersion?

    public init(
        recordName: String,
        kind: SyncDocumentKind,
        fields: [String: SyncFieldValue],
        deletionVersion: SyncFieldVersion? = nil
    ) {
        self.recordName = recordName
        self.kind = kind
        self.fields = fields
        self.deletionVersion = deletionVersion
    }

    public var isDeleted: Bool {
        guard let deletionVersion else { return false }
        return fields.values.allSatisfy { $0.version <= deletionVersion }
    }

    public func merged(with other: Self) -> Self {
        precondition(recordName == other.recordName, "Cannot merge different sync records")
        precondition(kind == other.kind, "Cannot merge different sync document kinds")

        var mergedFields = fields
        for (key, candidate) in other.fields {
            if let current = mergedFields[key], current.version > candidate.version {
                continue
            }
            mergedFields[key] = candidate
        }

        let mergedDeletion: SyncFieldVersion?
        switch (deletionVersion, other.deletionVersion) {
        case (.none, .none): mergedDeletion = nil
        case (.some(let value), .none), (.none, .some(let value)): mergedDeletion = value
        case (.some(let lhs), .some(let rhs)): mergedDeletion = max(lhs, rhs)
        }

        return Self(
            recordName: recordName,
            kind: kind,
            fields: mergedFields,
            deletionVersion: mergedDeletion
        )
    }
}

public struct SyncDocumentPersistencePartition: Equatable, Sendable {
    public var secure: [String: SyncDocument]
    public var ordinary: [String: SyncDocument]

    public init(secure: [String: SyncDocument], ordinary: [String: SyncDocument]) {
        self.secure = secure
        self.ordinary = ordinary
    }

    public static func partition(_ documents: [String: SyncDocument]) -> Self {
        var secure: [String: SyncDocument] = [:]
        var ordinary: [String: SyncDocument] = [:]
        for (recordName, document) in documents {
            switch document.kind {
            case .configuration:
                secure[recordName] = document
            case .podcastSubscription, .youtubeSubscription:
                ordinary[recordName] = document
            }
        }
        return Self(secure: secure, ordinary: ordinary)
    }

    public var recombined: [String: SyncDocument] {
        ordinary.merging(secure) { _, secureDocument in secureDocument }
    }
}

public enum SyncRecordIdentity {
    public static func podcast(sourceURL: String) -> String {
        "podcast-\(sha256Hex(normalizedPodcastURL(sourceURL)))"
    }

    public static func youtube(channelID: String) -> String {
        "youtube-\(channelID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public static func normalizedPodcastURL(_ sourceURL: String) -> String {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? trimmed
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SubtitleArtifactIdentity: Codable, Hashable, Sendable {
    /// v2 invalidates cloud artifacts produced before pause-based segmentation.
    public static let schemaVersion = 2

    public var contentKind: TranslationContentKind
    public var contentKey: String
    public var targetLanguage: String

    public init(
        contentKind: TranslationContentKind,
        contentKey: String,
        targetLanguage: String
    ) {
        self.contentKind = contentKind
        self.contentKey = contentKey
        self.targetLanguage = TranslationTargetPolicy.normalized(targetLanguage).rawValue
    }

    public static func podcast(
        sourceURL: String,
        episodeGUID: String,
        target: TranslationTarget
    ) -> Self {
        let source = SyncRecordIdentity.normalizedPodcastURL(sourceURL)
        let guid = episodeGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            contentKind: .podcastEpisode,
            contentKey: SubtitleArtifactHash.sha256Hex("podcast\n\(source)\n\(guid)"),
            targetLanguage: target.rawValue
        )
    }

    public static func youtube(videoID: String, target: TranslationTarget) -> Self {
        let normalizedID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            contentKind: .youtubeVideo,
            // Targeted v3 invalidation: podcast identities and the envelope
            // schema remain stable while poisoned YouTube v2 artifacts miss.
            contentKey: SubtitleArtifactHash.sha256Hex("youtube-v3\n\(normalizedID)"),
            targetLanguage: target.rawValue
        )
    }

    public var target: TranslationTarget {
        TranslationTargetPolicy.normalized(targetLanguage)
    }

    public var recordName: String {
        let raw = "\(contentKind.rawValue)\n\(contentKey)\n\(targetLanguage)"
        // YouTube's content identity is intentionally v3 while the shared
        // envelope schema and podcast identities remain v2 compatible.
        let identityVersion = contentKind == .youtubeVideo ? 3 : Self.schemaVersion
        return "subtitle-v\(identityVersion)-\(SubtitleArtifactHash.sha256Hex(raw))"
    }
}

public enum SubtitleArtifactHash {
    public static func sha256Hex(_ value: String) -> String {
        sha256Hex(Data(value.utf8))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SubtitleArtifactValidationError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case identityMismatch
    case incomplete
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Unsupported subtitle artifact schema: \(version)."
        case .identityMismatch: "The subtitle artifact does not match the requested content."
        case .incomplete: "The subtitle artifact is incomplete."
        case .invalidPayload: "The subtitle artifact payload is invalid."
        }
    }
}

public struct SubtitleArtifactEnvelope: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var identity: SubtitleArtifactIdentity
    public var generatedAt: Date
    public var segments: [LearningSegment]
    /// Fingerprint of the English transcription these translations were generated against.
    public var sourceFingerprint: String?
    /// Pipeline version that produced this artifact. Optional so older envelopes (which
    /// predate the field) still decode; a missing value is treated as a playable legacy build.
    public var pipelineVersion: Int?
    /// Provenance describing which pipeline/mode/timing source generated this artifact.
    public var generationProfile: TranslationGenerationProfile?

    public init(
        schemaVersion: Int = SubtitleArtifactIdentity.schemaVersion,
        identity: SubtitleArtifactIdentity,
        generatedAt: Date,
        segments: [LearningSegment],
        sourceFingerprint: String? = nil,
        pipelineVersion: Int? = nil,
        generationProfile: TranslationGenerationProfile? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.generatedAt = generatedAt
        self.segments = segments
        self.sourceFingerprint = sourceFingerprint ?? TranscriptionFingerprint.make(segments: segments)
        self.pipelineVersion = pipelineVersion
        self.generationProfile = generationProfile
    }

    public var isComplete: Bool {
        !segments.isEmpty && segments.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.endMS >= $0.startMS
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func validated(data: Data, expected: SubtitleArtifactIdentity) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Self.self, from: data) else {
            throw SubtitleArtifactValidationError.invalidPayload
        }
        guard envelope.schemaVersion == SubtitleArtifactIdentity.schemaVersion else {
            throw SubtitleArtifactValidationError.unsupportedSchema(envelope.schemaVersion)
        }
        guard envelope.identity == expected else {
            throw SubtitleArtifactValidationError.identityMismatch
        }
        guard envelope.isComplete else {
            throw SubtitleArtifactValidationError.incomplete
        }
        return envelope
    }
}

public struct SubtitleArtifactMetadata: Codable, Hashable, Sendable {
    public var identity: SubtitleArtifactIdentity
    public var version: SyncFieldVersion
    public var sha256: String?
    public var byteCount: Int64
    public var isDeleted: Bool

    public init(
        identity: SubtitleArtifactIdentity,
        version: SyncFieldVersion,
        sha256: String,
        byteCount: Int64
    ) {
        self.identity = identity
        self.version = version
        self.sha256 = sha256
        self.byteCount = byteCount
        self.isDeleted = false
    }

    private init(
        identity: SubtitleArtifactIdentity,
        version: SyncFieldVersion,
        sha256: String?,
        byteCount: Int64,
        isDeleted: Bool
    ) {
        self.identity = identity
        self.version = version
        self.sha256 = sha256
        self.byteCount = byteCount
        self.isDeleted = isDeleted
    }

    public static func tombstone(identity: SubtitleArtifactIdentity, version: SyncFieldVersion) -> Self {
        Self(identity: identity, version: version, sha256: nil, byteCount: 0, isDeleted: true)
    }
}

public enum SubtitleArtifactPayloadValidator {
    public static func validate(
        data: Data,
        metadata: SubtitleArtifactMetadata
    ) throws -> SubtitleArtifactEnvelope {
        guard !metadata.isDeleted,
              metadata.byteCount == Int64(data.count),
              let expectedHash = metadata.sha256,
              SubtitleArtifactHash.sha256Hex(data) == expectedHash
        else { throw SubtitleArtifactValidationError.invalidPayload }
        return try SubtitleArtifactEnvelope.validated(data: data, expected: metadata.identity)
    }
}

public enum SubtitleArtifactConflictPolicy {
    public static func preferred(
        _ lhs: SubtitleArtifactMetadata,
        _ rhs: SubtitleArtifactMetadata
    ) -> SubtitleArtifactMetadata {
        precondition(lhs.identity == rhs.identity, "Cannot merge different subtitle artifacts")
        if lhs.version != rhs.version {
            return lhs.version > rhs.version ? lhs : rhs
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? lhs : rhs
        }
        return lhs
    }
}

public enum SubtitleArtifactLookupResult: Equatable, Sendable {
    case ready(SubtitleArtifactEnvelope)
    case sourceOnly(SubtitleArtifactEnvelope)
    case notFound
    case unavailable(String)
}

public enum LocalArtifactStoragePlatform: Sendable {
    case iOS
    case tvOS
}

public enum LocalArtifactStoragePolicy {
    public static var runtimePlatform: LocalArtifactStoragePlatform {
        #if os(tvOS)
        .tvOS
        #else
        .iOS
        #endif
    }

    public static var runtimeDirectory: FileManager.SearchPathDirectory {
        directory(for: runtimePlatform)
    }

    public static func directory(
        for platform: LocalArtifactStoragePlatform
    ) -> FileManager.SearchPathDirectory {
        switch platform {
        case .iOS:
            .applicationSupportDirectory
        case .tvOS:
            .cachesDirectory
        }
    }
}

public enum SyncAccountDecision: Equatable, Sendable {
    case proceed
    case requireConfirmation
}

public enum SyncAccountPolicy {
    public static func decision(previousAccountID: String?, currentAccountID: String) -> SyncAccountDecision {
        guard let previousAccountID else { return .proceed }
        return previousAccountID == currentAccountID ? .proceed : .requireConfirmation
    }
}

public enum CloudOperationFailureKind: Equatable, Sendable {
    case serverRecordChanged
    case recordMissing
    case zoneMissing
    case transient
    case terminal
}

public enum CloudRecordSaveRecoveryAction: Equatable, Sendable {
    case mergeServerRecord
    case recreateRecord
    case recreateZoneAndRetryRecord
    case awaitAutomaticRetry
    case reportFailure
}

public struct CloudRecordSaveFailureContext: Equatable, Sendable {
    public var failure: CloudOperationFailureKind
    public var hasSystemFields: Bool

    public init(failure: CloudOperationFailureKind, hasSystemFields: Bool) {
        self.failure = failure
        self.hasSystemFields = hasSystemFields
    }
}

public struct CloudRecordSaveRecoveryPlan: Equatable, Sendable {
    public var actions: [CloudRecordSaveRecoveryAction]

    public init(actions: [CloudRecordSaveRecoveryAction]) {
        self.actions = actions
    }

    public var shouldQueueZoneSave: Bool {
        actions.contains(.recreateZoneAndRetryRecord)
    }
}

public enum CloudRecordSaveRecoveryPolicy {
    public static func action(
        for failure: CloudOperationFailureKind,
        hasSystemFields: Bool,
        isZoneRecoveryQueued: Bool
    ) -> CloudRecordSaveRecoveryAction {
        switch failure {
        case .serverRecordChanged:
            .mergeServerRecord
        case .recordMissing:
            hasSystemFields ? .recreateRecord : .reportFailure
        case .zoneMissing:
            isZoneRecoveryQueued ? .reportFailure : .recreateZoneAndRetryRecord
        case .transient:
            .awaitAutomaticRetry
        case .terminal:
            .reportFailure
        }
    }

    public static func plan(
        for failures: [CloudRecordSaveFailureContext],
        isZoneRecoveryQueued: Bool
    ) -> CloudRecordSaveRecoveryPlan {
        CloudRecordSaveRecoveryPlan(actions: failures.map {
            action(
                for: $0.failure,
                hasSystemFields: $0.hasSystemFields,
                isZoneRecoveryQueued: isZoneRecoveryQueued
            )
        })
    }
}

public enum CloudRecordDeleteRecoveryAction: Equatable, Sendable {
    case acceptAsDeleted
    case awaitAutomaticRetry
    case reportFailure
}

public enum CloudRecordDeleteRecoveryPolicy {
    public static func action(
        for failure: CloudOperationFailureKind
    ) -> CloudRecordDeleteRecoveryAction {
        switch failure {
        case .recordMissing, .zoneMissing:
            .acceptAsDeleted
        case .transient:
            .awaitAutomaticRetry
        case .serverRecordChanged, .terminal:
            .reportFailure
        }
    }
}
