import Foundation
#if canImport(VideoToolbox)
import VideoToolbox
#endif

// MARK: - Stream models

public struct YTMediaStream: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case progressive
        case videoOnly
        case audioOnly
    }

    public enum VideoCodecKind: String, Sendable, Equatable {
        case avc1
        case av1
        case vp9
        case other
    }

    public enum AudioCodecKind: String, Sendable, Equatable {
        case mp4a
        case opus
        case other
    }

    public let id: String
    public let url: URL
    public let itag: Int
    public let height: Int?
    public let bitrate: Int?
    public let averageBitrate: Int?
    public let videoCodec: VideoCodecKind?
    public let audioCodec: AudioCodecKind?
    public let videoCodecRaw: String?
    public let audioCodecRaw: String?
    public let container: String
    public let kind: Kind
    public let isNativelyPlayable: Bool

    public init(
        id: String,
        url: URL,
        itag: Int,
        height: Int?,
        bitrate: Int?,
        averageBitrate: Int?,
        videoCodec: VideoCodecKind?,
        audioCodec: AudioCodecKind?,
        videoCodecRaw: String?,
        audioCodecRaw: String?,
        container: String,
        kind: Kind,
        isNativelyPlayable: Bool
    ) {
        self.id = id
        self.url = url
        self.itag = itag
        self.height = height
        self.bitrate = bitrate
        self.averageBitrate = averageBitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoCodecRaw = videoCodecRaw
        self.audioCodecRaw = audioCodecRaw
        self.container = container
        self.kind = kind
        self.isNativelyPlayable = isNativelyPlayable
    }

    public var effectiveHeight: Int {
        height ?? 0
    }

    public var qualityScore: (Int, Int, Int) {
        (effectiveHeight, bitrate ?? 0, averageBitrate ?? 0)
    }
}

public struct YTResolvedMediaStreams: Sendable, Equatable {
    public let progressive: [YTMediaStream]
    public let videoOnly: [YTMediaStream]
    public let audioOnly: [YTMediaStream]
    public let hlsURL: URL?
    public let expiresAt: Date?

    public init(
        progressive: [YTMediaStream],
        videoOnly: [YTMediaStream],
        audioOnly: [YTMediaStream],
        hlsURL: URL?,
        expiresAt: Date?
    ) {
        self.progressive = progressive
        self.videoOnly = videoOnly
        self.audioOnly = audioOnly
        self.hlsURL = hlsURL
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

public enum YTPlaybackSource: Sendable, Equatable {
    case direct(stream: YTMediaStream)
    case composed(video: YTMediaStream, audio: YTMediaStream)
    case hls(URL, maximumHeight: Int?)
}

public struct YTPlaybackSelection: Sendable, Equatable {
    public let source: YTPlaybackSource
    public let actualHeight: Int?
    public let actualCodec: String?
    public let selectionMode: String

    public init(source: YTPlaybackSource, actualHeight: Int?, actualCodec: String?, selectionMode: String) {
        self.source = source
        self.actualHeight = actualHeight
        self.actualCodec = actualCodec
        self.selectionMode = selectionMode
    }
}

public enum YTPlaybackNetworkKind: Sendable, Equatable {
    case wifi
    case cellular
    case other
}

public struct YTPlaybackSelectionContext: Sendable, Equatable {
    public let policy: YTStreamSelectionPolicy?
    public let network: YTPlaybackNetworkKind
    public let supportsAV1HardwareDecode: Bool
    /// When true, "auto"/highest respects the cellular 1080p cap.
    public let applyCellularAutoCap: Bool
    /// When true, auto quality selects the highest fixed, natively decodable stream
    /// before HLS. Adaptive HLS remains available to the player's stall recovery.
    public let prefersFixedQualityOverAdaptiveHLS: Bool

    public init(
        policy: YTStreamSelectionPolicy?,
        network: YTPlaybackNetworkKind,
        supportsAV1HardwareDecode: Bool = YTHardwareDecodeSupport.isAV1Supported,
        applyCellularAutoCap: Bool = true,
        prefersFixedQualityOverAdaptiveHLS: Bool = false
    ) {
        self.policy = policy
        self.network = network
        self.supportsAV1HardwareDecode = supportsAV1HardwareDecode
        self.applyCellularAutoCap = applyCellularAutoCap
        self.prefersFixedQualityOverAdaptiveHLS = prefersFixedQualityOverAdaptiveHLS
    }
}

public enum YTHardwareDecodeSupport {
    public static var isAV1Supported: Bool {
#if canImport(VideoToolbox) && !os(watchOS)
        if #available(iOS 13.0, macOS 10.15, tvOS 13.0, *) {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }
#endif
        return false
    }
}

public protocol YTMediaStreamResolving: Actor {
    func resolve(videoID: String) async throws -> YTResolvedMediaStreams
    func invalidate(videoID: String) async
}

public enum YTMediaStreamResolverError: LocalizedError, Equatable, Sendable {
    case noPlayableStream
    case rateLimited
    case expired
    case remoteForbidden
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noPlayableStream:
            "No usable video stream was resolved."
        case .rateLimited:
            "YouTube stream requests are rate limited."
        case .expired:
            "The resolved stream URL has expired."
        case .remoteForbidden:
            "The stream URL was rejected by YouTube."
        case .extractionFailed(let message):
            message
        }
    }
}

// MARK: - Expiry helpers

public enum YTMediaStreamURLExpiry {
    /// Prefer URL `expire` / `expires` query values; otherwise fall back to a short TTL.
    public static func expiresAt(from url: URL, now: Date = Date(), fallbackTTL: TimeInterval = 10 * 60) -> Date {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for key in ["expire", "expires"] {
            if let raw = items.first(where: { $0.name.lowercased() == key })?.value,
               let epoch = TimeInterval(raw) {
                // YouTube uses unix seconds.
                let absolute = Date(timeIntervalSince1970: epoch)
                return absolute.addingTimeInterval(-5 * 60)
            }
        }
        return now.addingTimeInterval(fallbackTTL)
    }

    public static func earliestExpiry(in streams: [YTMediaStream], hlsURL: URL?, now: Date = Date()) -> Date? {
        var dates: [Date] = streams.map { expiresAt(from: $0.url, now: now) }
        if let hlsURL {
            dates.append(expiresAt(from: hlsURL, now: now))
        }
        return dates.min()
    }
}

// MARK: - Source selection

public enum YTPlaybackSourceSelector {
    public static let cellularAutoMaxHeight = 1080
    /// Below this height, Auto + quality-first platforms prefer a verified HLS
    /// manifest over sticking to itag-18-class progressive when HLS is available.
    public static let minimumPreferredFixedHeight = 720

    public static func effectiveMaxHeight(context: YTPlaybackSelectionContext) -> Int? {
        switch context.policy {
        case .none, .some(.highestQuality):
            if context.applyCellularAutoCap, context.network == .cellular {
                return cellularAutoMaxHeight
            }
            return nil
        case .some(.preferred(let maxHeight)):
            return maxHeight
        case .some(.legacyCompatible):
            return 360
        }
    }

    public static func select(
        from resolved: YTResolvedMediaStreams,
        context: YTPlaybackSelectionContext
    ) -> YTPlaybackSelection? {
        let isAutoQuality = context.policy == nil || context.policy == .highestQuality
        if isAutoQuality,
           !context.prefersFixedQualityOverAdaptiveHLS,
           let hlsURL = resolved.hlsURL {
            return hlsSelection(hlsURL, context: context, mode: "hls")
        }

        if let hlsURL = resolved.hlsURL,
           resolved.progressive.isEmpty,
           resolved.videoOnly.isEmpty {
            return hlsSelection(hlsURL, context: context, mode: "hls")
        }

        let maxHeight = effectiveMaxHeight(context: context)
        let playableVideoOnly = resolved.videoOnly.filter {
            isHardwareDecodableVideo($0, supportsAV1: context.supportsAV1HardwareDecode)
                && isMP4Container($0)
        }
        let playableProgressive = resolved.progressive.filter {
            isHardwareDecodableVideo($0, supportsAV1: context.supportsAV1HardwareDecode)
                && isMP4Container($0)
                && $0.isNativelyPlayable
        }
        let playableAudio = resolved.audioOnly.filter {
            $0.container.lowercased() == "m4a"
                && ($0.audioCodec == .mp4a || $0.isNativelyPlayable)
                && $0.isNativelyPlayable
        }

        if context.policy == .legacyCompatible {
            if let stream = bestProgressive(playableProgressive, maxHeight: 360)
                ?? playableProgressive.min(by: { $0.qualityScore < $1.qualityScore }) {
                return selection(direct: stream, mode: "legacy")
            }
        }

        // Quality-first platforms: if only sub-720 fixed streams remain (e.g. fake HD
        // filtered out) but HLS is present, prefer adaptive HLS over itag 18.
        // Auto always; manual only when the user asked for ≥720.
        if context.prefersFixedQualityOverAdaptiveHLS,
           let hlsURL = resolved.hlsURL,
           Self.shouldPreferHLSOverLowFixed(policy: context.policy) {
            let bestFixedHeight = max(
                playableVideoOnly.map(\.effectiveHeight).max() ?? 0,
                playableProgressive.map(\.effectiveHeight).max() ?? 0
            )
            if bestFixedHeight > 0, bestFixedHeight < minimumPreferredFixedHeight {
                return hlsSelection(
                    hlsURL,
                    context: context,
                    mode: isAutoQuality ? "hls-low-fixed-fallback" : "hls-preflight-fallback"
                )
            }
            if bestFixedHeight == 0, isAutoQuality {
                return hlsSelection(hlsURL, context: context, mode: "hls")
            }
        }

        let targetVideo = bestVideoOnly(playableVideoOnly, maxHeight: maxHeight)
            ?? bestProgressive(playableProgressive, maxHeight: maxHeight)

        guard let targetVideo else {
            if let hlsURL = resolved.hlsURL {
                return hlsSelection(hlsURL, context: context, mode: "hls")
            }
            if let stream = playableProgressive.max(by: { $0.qualityScore < $1.qualityScore }) {
                return selection(direct: stream, mode: "progressive-fallback")
            }
            return nil
        }

        let targetHeight = targetVideo.effectiveHeight
        if let progressive = bestProgressive(playableProgressive, exactHeight: targetHeight)
            ?? playableProgressive.first(where: { $0.effectiveHeight == targetHeight }) {
            return selection(direct: progressive, mode: "direct")
        }

        if targetVideo.kind == .progressive {
            return selection(direct: targetVideo, mode: "direct")
        }

        guard let audio = bestAudio(playableAudio) else {
            if let progressive = bestProgressive(playableProgressive, maxHeight: maxHeight)
                ?? playableProgressive.max(by: { $0.qualityScore < $1.qualityScore }) {
                return selection(direct: progressive, mode: "progressive-fallback")
            }
            if let hlsURL = resolved.hlsURL {
                return hlsSelection(hlsURL, context: context, mode: "hls")
            }
            return nil
        }

        return YTPlaybackSelection(
            source: .composed(video: targetVideo, audio: audio),
            actualHeight: targetVideo.height,
            actualCodec: targetVideo.videoCodecRaw ?? targetVideo.videoCodec?.rawValue,
            selectionMode: "composed"
        )
    }

    private static func hlsSelection(
        _ hlsURL: URL,
        context: YTPlaybackSelectionContext,
        mode: String
    ) -> YTPlaybackSelection {
        YTPlaybackSelection(
            source: .hls(
                hlsURL,
                maximumHeight: effectiveMaxHeight(context: context)
            ),
            actualHeight: nil,
            actualCodec: "hls",
            selectionMode: mode
        )
    }

    private static func shouldPreferHLSOverLowFixed(policy: YTStreamSelectionPolicy?) -> Bool {
        switch policy {
        case .none, .some(.highestQuality):
            return true
        case .some(.preferred(let maxHeight)):
            return maxHeight >= minimumPreferredFixedHeight
        case .some(.legacyCompatible):
            return false
        }
    }

    /// Available fixed quality menu tiers that exist and are playable for this video.
    public static func availableQualityTiers(
        from resolved: YTResolvedMediaStreams,
        supportsAV1HardwareDecode: Bool = YTHardwareDecodeSupport.isAV1Supported
    ) -> [YTStreamSelectionPolicy] {
        let playableHeights = Set(
            (resolved.videoOnly + resolved.progressive)
                .filter { isHardwareDecodableVideo($0, supportsAV1: supportsAV1HardwareDecode) && isMP4Container($0) }
                .map(\.effectiveHeight)
                .filter { $0 > 0 }
        )
        var options: [YTStreamSelectionPolicy] = [.highestQuality]
        for height in [2160, 1440, 1080, 720, 480, 360] where playableHeights.contains(height) {
            options.append(.preferred(maxHeight: height))
        }
        // Always keep a compatibility escape hatch when any progressive muxed stream exists.
        if resolved.progressive.contains(where: {
            isHardwareDecodableVideo($0, supportsAV1: supportsAV1HardwareDecode) && isMP4Container($0)
        }) {
            options.append(.legacyCompatible)
        }
        return options
    }

    public static func lowerQualityTier(from height: Int?) -> YTStreamSelectionPolicy? {
        let ladder = [2160, 1440, 1080, 720, 480, 360]
        guard let height else { return .preferred(maxHeight: 720) }
        guard let index = ladder.firstIndex(where: { $0 <= height }) else {
            return .legacyCompatible
        }
        let next = index + 1
        if next < ladder.count {
            return .preferred(maxHeight: ladder[next])
        }
        return .legacyCompatible
    }

    private static func selection(direct stream: YTMediaStream, mode: String) -> YTPlaybackSelection {
        YTPlaybackSelection(
            source: .direct(stream: stream),
            actualHeight: stream.height,
            actualCodec: stream.videoCodecRaw ?? stream.videoCodec?.rawValue,
            selectionMode: mode
        )
    }

    private static func isMP4Container(_ stream: YTMediaStream) -> Bool {
        let container = stream.container.lowercased()
        return container == "mp4" || container == "m4v"
    }

    public static func isHardwareDecodableVideo(
        _ stream: YTMediaStream,
        supportsAV1: Bool
    ) -> Bool {
        guard stream.includesVideo else { return false }
        guard stream.isNativelyPlayable || stream.videoCodec == .avc1 || (stream.videoCodec == .av1 && supportsAV1) else {
            return false
        }
        switch stream.videoCodec {
        case .vp9, .other, .none:
            // VP9 and unknown codecs are rejected; nil codec only OK for progressive
            // when YouTubeKit already marked it natively playable (H.264 assumed).
            if stream.videoCodec == .vp9 { return false }
            if stream.videoCodec == .other { return false }
            return stream.isNativelyPlayable
        case .avc1:
            return true
        case .av1:
            return supportsAV1
        }
    }

    private static func bestVideoOnly(_ streams: [YTMediaStream], maxHeight: Int?) -> YTMediaStream? {
        let capped = streams.filter { maxHeight == nil || $0.effectiveHeight <= (maxHeight ?? .max) }
        if let best = capped.max(by: { $0.qualityScore < $1.qualityScore }) {
            return best
        }
        // Nothing at or below the cap: for manual caps, still pick the highest <= cap
        // only; if empty, fall back to the highest overall only when maxHeight is nil.
        guard maxHeight == nil else { return capped.max(by: { $0.qualityScore < $1.qualityScore }) }
        return streams.max(by: { $0.qualityScore < $1.qualityScore })
    }

    private static func bestProgressive(
        _ streams: [YTMediaStream],
        maxHeight: Int?
    ) -> YTMediaStream? {
        let capped = streams.filter { maxHeight == nil || $0.effectiveHeight <= (maxHeight ?? .max) }
        return capped.max(by: { $0.qualityScore < $1.qualityScore })
    }

    private static func bestProgressive(
        _ streams: [YTMediaStream],
        exactHeight: Int
    ) -> YTMediaStream? {
        streams
            .filter { $0.effectiveHeight == exactHeight }
            .max(by: { $0.qualityScore < $1.qualityScore })
    }

    private static func bestAudio(_ streams: [YTMediaStream]) -> YTMediaStream? {
        streams.max { lhs, rhs in
            (lhs.averageBitrate ?? lhs.bitrate ?? 0) < (rhs.averageBitrate ?? rhs.bitrate ?? 0)
        }
    }
}

private extension YTMediaStream {
    var includesVideo: Bool {
        kind == .progressive || kind == .videoOnly
    }
}
