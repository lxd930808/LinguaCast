import Foundation

public enum DownloadProgressMetrics {
    public static func fraction(completedBytes: Int64, expectedBytes: Int64) -> Double? {
        guard completedBytes >= 0, expectedBytes > 0 else { return nil }
        return min(max(Double(completedBytes) / Double(expectedBytes), 0), 1)
    }

    public static func bytesPerSecond(bytesDelta: Int64, elapsedSeconds: TimeInterval) -> Double? {
        guard bytesDelta >= 0, elapsedSeconds > 0 else { return nil }
        return Double(bytesDelta) / elapsedSeconds
    }

    public static func smoothedBytesPerSecond(
        previous: Double?,
        sample: Double,
        sampleWeight: Double = 0.25
    ) -> Double {
        guard let previous else { return max(sample, 0) }
        let weight = min(max(sampleWeight, 0), 1)
        return max(previous * (1 - weight) + sample * weight, 0)
    }
}

public enum SourceGenerationStateRecoveryPolicy {
    public static func shouldClear(step: String?, subtitleStatus: String) -> Bool {
        guard step != nil else { return false }
        return subtitleStatus == "failed" || subtitleStatus == "ready"
    }
}

// MARK: - Cloud video subtitle orchestration (V10 / WP13)
//
// Pure decision/policy seam for the app-target cloud video flow. Kept in Core
// (raw-string based, no CloudSyncKit/DomainModels dependency) so the app glue
// in YTLocalService and the CloudVideo*Tests share exactly one implementation.

/// Decides which backend produces subtitles for newly opened videos.
public enum CloudVideoGenerationRouting {
    /// Raw value of GenerationBackend.cloud; matched case-insensitively with
    /// surrounding whitespace trimmed, mirroring GenerationBackend.normalized.
    public static let cloudBackendRawValue = "cloud"

    /// New video subtitle generation defaults to a contentType=video cloud job
    /// only when the committed backend mode is cloud.
    public static func shouldUseCloudBackend(generationBackend: String) -> Bool {
        generationBackend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == cloudBackendRawValue
    }

    /// In cloud mode platform-caption fetching is diagnostics/fallback only and
    /// never participates in a new generation pass.
    public static func allowsPlatformCaptionFetch(generationBackend: String) -> Bool {
        !shouldUseCloudBackend(generationBackend: generationBackend)
    }

    /// In cloud mode the on-device audio ASR pipeline never participates in a
    /// new generation pass (manual fallback entry points aside).
    public static func allowsLocalAudioASR(generationBackend: String) -> Bool {
        !shouldUseCloudBackend(generationBackend: generationBackend)
    }
}

/// Guards against stale cloud job results: an update or ready payload may only
/// be applied to the video whose generation pass submitted the job. Both the
/// content key and the stable key captured at submit time must match, so a
/// previous video's job can never write into the video now on screen.
public enum CloudVideoJobUpdateGuard {
    public static func shouldApply(
        expectedContentKey: String,
        expectedStableKey: String,
        incomingContentKey: String,
        incomingStableKey: String
    ) -> Bool {
        !expectedContentKey.isEmpty
            && !expectedStableKey.isEmpty
            && expectedContentKey == incomingContentKey
            && expectedStableKey == incomingStableKey
    }
}

public enum CloudSegmentsArtifactError: Error, Equatable, Sendable {
    /// Body did not match the segments envelope wire schema.
    case malformed
    /// Server published a schema newer than this client can consume.
    case unsupportedSchemaVersion(Int)
    /// Envelope decoded but carried no segments.
    case emptySegments
}

/// Wire envelope of the cloud `segments.json` artifact (content-artifact-v1).
/// Unknown JSON fields are ignored; unknown inner segment fields are tolerated
/// by LearningSegment's decoder.
public struct CloudSegmentsArtifactEnvelope: Codable, Equatable, Sendable {
    /// Highest artifact schema this client can consume.
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var sourceLanguage: String
    public var targetLanguage: String
    public var segments: [LearningSegment]

    public init(
        schemaVersion: Int,
        sourceLanguage: String,
        targetLanguage: String,
        segments: [LearningSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.segments = segments
    }

    public static func decode(from data: Data) throws -> CloudSegmentsArtifactEnvelope {
        guard let envelope = try? JSONDecoder().decode(CloudSegmentsArtifactEnvelope.self, from: data) else {
            throw CloudSegmentsArtifactError.malformed
        }
        guard envelope.schemaVersion <= supportedSchemaVersion else {
            throw CloudSegmentsArtifactError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard !envelope.segments.isEmpty else {
            throw CloudSegmentsArtifactError.emptySegments
        }
        return envelope
    }
}
