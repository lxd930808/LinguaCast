import Foundation

/// Session-scoped cloud MP4 candidate. The signed URL must never be persisted
/// or logged; it exists only for the current player item.
public struct CloudVideoPlaybackCandidate: Equatable, Sendable {
    public let mediaId: String
    public let contentKey: String
    public let url: URL
    public let expiresAt: Date
    public let mimeType: String
    public let bytes: Int
    public let sha256: String
    public let durationSeconds: Double
    public let height: Int
    public let videoCodec: String
    public let audioCodec: String
    public let acceptRanges: String
    public let mediaVersion: String
    public let createdAt: Date

    public init(
        mediaId: String,
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
        self.mediaId = mediaId
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
}

public enum CloudVideoLookupOutcome: Equatable, Sendable {
    case ready(CloudVideoPlaybackCandidate)
    case notFound
    case notReady(retryAfterSeconds: Int?)
    case integrityFailed
    case unauthorized
    case transport
    case decoding
}

public enum CloudVideoPlaybackFallbackReason: String, Equatable, Sendable {
    case miss
    case notReady
    case timeout
    case unauthorized
    case incompatible
    case durationMismatch
    case integrityFailed
    case transport
    case decoding
}

public enum CloudVideoPlaybackDecision: Equatable, Sendable {
    case useCloud(CloudVideoPlaybackCandidate)
    case refreshCloudOnce
    case fallback(CloudVideoPlaybackFallbackReason)
    case manualQualityMiss
}

/// Pure playback routing for durable cloud MP4. No networking, no tokens.
public enum CloudVideoPlaybackRouting {
    public static let selectionMode = "cloud-media"
    public static let expirySafetyWindow: TimeInterval = 60

    public static func shouldAttemptCloud(usesOfficialIFrame: Bool) -> Bool {
        !usesOfficialIFrame
    }

    public static func preferredHeight(from quality: YTStreamSelectionPolicy?) -> Int? {
        if case .preferred(let maxHeight) = quality {
            return maxHeight
        }
        return nil
    }

    public static func decideOnLookup(
        outcome: CloudVideoLookupOutcome,
        quality: YTStreamSelectionPolicy?,
        expectedDuration: TimeInterval?,
        supportsAV1: Bool,
        now: Date = Date()
    ) -> CloudVideoPlaybackDecision {
        switch outcome {
        case .notFound:
            return .fallback(.miss)
        case .notReady:
            return .fallback(.notReady)
        case .integrityFailed:
            return .fallback(.integrityFailed)
        case .unauthorized:
            return .fallback(.unauthorized)
        case .transport:
            return .fallback(.transport)
        case .decoding:
            return .fallback(.decoding)
        case .ready(let candidate):
            return decideOnReadyCandidate(
                candidate,
                quality: quality,
                expectedDuration: expectedDuration,
                supportsAV1: supportsAV1,
                now: now
            )
        }
    }

    public static func decideOnPlayerFailure(
        statusCode: Int?,
        currentSelectionMode: String?,
        didRefreshCloudURL: Bool
    ) -> CloudVideoPlaybackDecision {
        guard currentSelectionMode == selectionMode else {
            return .fallback(.miss)
        }
        if statusCode == 401 || statusCode == 403 {
            if didRefreshCloudURL {
                return .fallback(.unauthorized)
            }
            return .refreshCloudOnce
        }
        if statusCode == 404 || statusCode == 410 {
            return .fallback(.miss)
        }
        return .fallback(.transport)
    }

    public static func shouldReapplyOnNetworkChange(selectionMode: String?) -> Bool {
        selectionMode != Self.selectionMode
    }

    public static func isCompatible(
        mimeType: String,
        videoCodec: String,
        audioCodec: String,
        supportsAV1: Bool
    ) -> Bool {
        isPlayableContainer(mimeType)
            && isPlayableVideoCodec(videoCodec, supportsAV1: supportsAV1)
            && isPlayableAudioCodec(audioCodec)
    }

    /// Same threshold as the content-pipeline promotion probe: 500ms or 0.5%
    /// of the longer duration, whichever is larger.
    public static func durationMismatchExceedsThreshold(
        videoSeconds: Double,
        expectedSeconds: Double
    ) -> Bool {
        let delta = abs(videoSeconds - expectedSeconds)
        let longer = max(videoSeconds, expectedSeconds)
        let threshold = max(0.5, longer * 0.005)
        return delta > threshold
    }

    public static func playbackSelection(
        from candidate: CloudVideoPlaybackCandidate
    ) -> YTPlaybackSelection {
        let stream = YTMediaStream(
            id: "cloud:\(candidate.mediaId)",
            url: candidate.url,
            itag: 0,
            height: candidate.height,
            bitrate: nil,
            averageBitrate: nil,
            videoCodec: videoCodecKind(from: candidate.videoCodec),
            audioCodec: audioCodecKind(from: candidate.audioCodec),
            videoCodecRaw: candidate.videoCodec,
            audioCodecRaw: candidate.audioCodec,
            container: "mp4",
            kind: .progressive,
            isNativelyPlayable: true
        )
        return YTPlaybackSelection(
            source: .direct(stream: stream),
            actualHeight: candidate.height,
            actualCodec: candidate.videoCodec,
            selectionMode: selectionMode
        )
    }

    public static func availableQualityTiers(height: Int) -> [YTStreamSelectionPolicy] {
        let match = YTStreamSelectionPolicy.qualityTierOptions.filter { policy in
            if case .preferred(let maxHeight) = policy {
                return maxHeight == height
            }
            return false
        }
        return match.isEmpty ? [.preferred(maxHeight: height)] : match
    }

    public static func videoCodecKind(from raw: String) -> YTMediaStream.VideoCodecKind {
        let value = raw.lowercased()
        if value.contains("vp9") || value.contains("vp09") { return .vp9 }
        if value.contains("av01") || value.hasPrefix("av1") { return .av1 }
        if value.contains("avc") || value.contains("h264") { return .avc1 }
        return .other
    }

    public static func audioCodecKind(from raw: String) -> YTMediaStream.AudioCodecKind {
        let value = raw.lowercased()
        if value.contains("opus") { return .opus }
        if value.contains("aac") || value.contains("mp4a") || value.contains("mp3") {
            return .mp4a
        }
        return .other
    }

    // MARK: - Internals

    private static func decideOnReadyCandidate(
        _ candidate: CloudVideoPlaybackCandidate,
        quality: YTStreamSelectionPolicy?,
        expectedDuration: TimeInterval?,
        supportsAV1: Bool,
        now: Date
    ) -> CloudVideoPlaybackDecision {
        guard candidate.expiresAt > now else {
            return .fallback(.miss)
        }
        guard isCompatible(
            mimeType: candidate.mimeType,
            videoCodec: candidate.videoCodec,
            audioCodec: candidate.audioCodec,
            supportsAV1: supportsAV1
        ) else {
            return .fallback(.incompatible)
        }
        if let expectedDuration,
           expectedDuration > 0,
           durationMismatchExceedsThreshold(
            videoSeconds: candidate.durationSeconds,
            expectedSeconds: expectedDuration
           ) {
            return .fallback(.durationMismatch)
        }
        if case .preferred(let requestedHeight) = quality, candidate.height < requestedHeight {
            return .manualQualityMiss
        }
        return .useCloud(candidate)
    }

    private static func isPlayableContainer(_ mimeType: String) -> Bool {
        let value = mimeType.lowercased()
        return value.contains("mp4") || value.contains("m4v")
    }

    private static func isPlayableVideoCodec(_ raw: String, supportsAV1: Bool) -> Bool {
        switch videoCodecKind(from: raw) {
        case .avc1:
            return true
        case .av1:
            return supportsAV1
        case .vp9, .other:
            return false
        }
    }

    private static func isPlayableAudioCodec(_ raw: String) -> Bool {
        audioCodecKind(from: raw) == .mp4a
    }
}
