import AVFoundation
import Foundation

@MainActor
public struct YTPreparedPlayback {
    public let primaryItem: AVPlayerItem
    public let auxiliaryAudioItem: AVPlayerItem?
    /// Retains the composed-HLS resource loader delegate for the item's lifetime
    /// (AVAssetResourceLoader holds its delegate weakly). Nil on every path that
    /// serves playlists over plain https.
    public let composedHLSAsset: YTComposedHLSAsset?

    public init(
        primaryItem: AVPlayerItem,
        auxiliaryAudioItem: AVPlayerItem?,
        composedHLSAsset: YTComposedHLSAsset? = nil
    ) {
        self.primaryItem = primaryItem
        self.auxiliaryAudioItem = auxiliaryAudioItem
        self.composedHLSAsset = composedHLSAsset
    }
}

public enum YTDualPlayerSyncAction: Equatable, Sendable {
    case none
    case seekAudio(to: TimeInterval)
}

public enum YTDualPlayerSyncPolicy {
    public static let correctionThreshold: TimeInterval = 0.35

    public static func action(
        videoTime: TimeInterval,
        audioTime: TimeInterval
    ) -> YTDualPlayerSyncAction {
        guard videoTime.isFinite, audioTime.isFinite,
              abs(videoTime - audioTime) > correctionThreshold
        else {
            return .none
        }
        return .seekAudio(to: videoTime)
    }
}

public enum YTPlaybackItemBuilder {
    @MainActor
    public static func makePreparedPlayback(
        from source: YTPlaybackSource,
        prefersComposedHLSSinglePlayer: Bool = false,
        composedHLSDurationHint: TimeInterval? = nil,
        segmentIndexFetcher: YTMP4SegmentIndexFetcher = .shared
    ) async throws -> YTPreparedPlayback {
        switch source {
        case .direct(let stream):
            return YTPreparedPlayback(
                primaryItem: AVPlayerItem(url: stream.url),
                auxiliaryAudioItem: nil
            )
        case .hls(let url, let maximumHeight):
            let item = AVPlayerItem(url: url)
            if let maximumHeight {
                item.preferredMaximumResolution = CGSize(
                    width: CGFloat(maximumHeight) * 16 / 9,
                    height: CGFloat(maximumHeight)
                )
            }
            return YTPreparedPlayback(primaryItem: item, auxiliaryAudioItem: nil)
        case .composed(let video, let audio):
            if prefersComposedHLSSinglePlayer {
                // tvOS: single synthesized-HLS item; the system player owns A/V sync.
                // Probes sidx in parallel and falls back to single-segment playlists.
                let composed = await YTComposedHLSAsset.make(
                    video: video,
                    audio: audio,
                    durationHint: composedHLSDurationHint,
                    indexFetcher: segmentIndexFetcher
                )
                return YTPreparedPlayback(
                    primaryItem: composed.makePlayerItem(),
                    auxiliaryAudioItem: nil,
                    composedHLSAsset: composed
                )
            }
            return YTPreparedPlayback(
                primaryItem: AVPlayerItem(url: video.url),
                auxiliaryAudioItem: AVPlayerItem(url: audio.url)
            )
        }
    }

}
