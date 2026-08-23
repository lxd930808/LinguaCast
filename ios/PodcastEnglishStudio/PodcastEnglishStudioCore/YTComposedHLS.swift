import AVFoundation
import Foundation

// 借鉴 ATV-Bilibili-demo 的「ResourceLoader 伪装 HLS」:把 YouTube 分离的
// video-only / audio-only 两条 googlevideo 整段流合成一份 HLS 清单,交给单个
// AVPlayerItem,由系统播放器完成音视频同步,替代双 AVPlayer + 漂移校准方案。
//
// 优先形态:解析各轨 sidx,输出带 EXT-X-BYTERANGE 的短分段 VOD playlist,让
// AVPlayer 按正常 HLS 缓冲模型快速起播。SIDX 不可用时退回每轨一条 #EXTINF
// 整段 playlist(ATV-Bilibili SIDX 失败时的简化形态)。

/// Virtual URLs served by the composed-HLS resource loader. The master playlist
/// references the two media playlists with absolute `ytc://` URIs so AVPlayer
/// resolves them back through the same loader.
public enum YTComposedHLSEndpoint {
    public static let scheme = "ytc"
    public static let masterURL = URL(string: "ytc://composed/master.m3u8")!
    public static let videoPlaylistURL = URL(string: "ytc://composed/video.m3u8")!
    public static let audioPlaylistURL = URL(string: "ytc://composed/audio.m3u8")!
}

/// Pure-text HLS playlist generation for composed (separate video/audio) streams.
public enum YTComposedHLSPlaylistBuilder {
    static let audioGroupID = "audio"

    /// Placeholder VOD length when neither caller metadata nor the stream URL
    /// carries a duration. `#EXTINF` accepts approximations — AVPlayer replaces it
    /// with the real media duration once the MP4/m4a parses — so a generous value
    /// is safer than a short one (a short value risks ending playback early).
    public static let fallbackDuration: TimeInterval = 3 * 60 * 60

    /// Forward-buffer hint applied to the synthesized player item so AVPlayer
    /// starts after ~1–2 short segments instead of a large progressive download.
    public static let preferredForwardBufferDuration: TimeInterval = 5

    public static func masterPlaylist(video: YTMediaStream, audio: YTMediaStream) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(audioGroupID)\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(YTComposedHLSEndpoint.audioPlaylistURL.absoluteString)\"",
        ]
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(peakBandwidth(video: video, audio: audio))"
        if let average = averageBandwidth(video: video, audio: audio) {
            streamInf += ",AVERAGE-BANDWIDTH=\(average)"
        }
        streamInf += ",CODECS=\"\(codecsParameter(video: video, audio: audio))\""
        if let resolution = resolutionParameter(height: video.height) {
            streamInf += ",RESOLUTION=\(resolution)"
        }
        streamInf += ",AUDIO=\"\(audioGroupID)\""
        lines.append(streamInf)
        lines.append(YTComposedHLSEndpoint.videoPlaylistURL.absoluteString)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Media playlist: prefer sidx-derived BYTERANGE segments; otherwise one
    /// whole-file `#EXTINF` pointing at the original googlevideo URL.
    public static func mediaPlaylist(
        stream: YTMediaStream,
        durationHint: TimeInterval?,
        segmentIndex: YTMP4SegmentIndex? = nil
    ) -> String {
        if let segmentIndex, !segmentIndex.segments.isEmpty {
            return segmentedMediaPlaylist(stream: stream, index: segmentIndex)
        }
        return singleSegmentMediaPlaylist(stream: stream, durationHint: durationHint)
    }

    static func segmentedMediaPlaylist(stream: YTMediaStream, index: YTMP4SegmentIndex) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(index.targetDuration)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"\(stream.url.absoluteString)\",BYTERANGE=\"\(index.initByteLength)@0\"",
        ]
        for segment in index.segments {
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(segment.byteLength)@\(segment.byteOffset)")
            lines.append(stream.url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func singleSegmentMediaPlaylist(stream: YTMediaStream, durationHint: TimeInterval?) -> String {
        let duration = resolvedDuration(for: stream, hint: durationHint)
        let targetDuration = max(1, Int(duration.rounded(.up)))
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(targetDuration)
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:\(String(format: "%.3f", duration)),
        \(stream.url.absoluteString)
        #EXT-X-ENDLIST

        """
    }

    /// Duration precedence: caller metadata hint → googlevideo `dur` query → fallback.
    static func resolvedDuration(for stream: YTMediaStream, hint: TimeInterval?) -> TimeInterval {
        if let hint, hint.isFinite, hint > 0 { return hint }
        if let dur = googlevideoDuration(from: stream.url), dur.isFinite, dur > 0 { return dur }
        return fallbackDuration
    }

    /// googlevideo adaptive-format URLs carry the exact length in a `dur` query
    /// parameter (seconds, millisecond precision).
    static func googlevideoDuration(from url: URL) -> TimeInterval? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "dur" })?
            .value
            .flatMap(TimeInterval.init)
    }

    static func codecsParameter(video: YTMediaStream, audio: YTMediaStream) -> String {
        "\(videoCodecParameter(video)),\(audioCodecParameter(audio))"
    }

    /// Full RFC 6381 codec strings: pass through values that already carry a
    /// profile ("avc1.640028"), upgrade the resolvers' short names ("avc1") to a
    /// profile that covers the stream's height. Over-declaring the level is safe
    /// (the decoder only checks it can handle it); under-declaring risks -12318.
    static func videoCodecParameter(_ stream: YTMediaStream) -> String {
        if let raw = stream.videoCodecRaw, raw.contains(".") { return raw }
        let kind = stream.videoCodec
            ?? YTMediaStream.VideoCodecKind(rawValue: stream.videoCodecRaw ?? "")
        switch kind {
        case .av1:
            switch stream.effectiveHeight {
            case ..<1440: return "av01.0.08M.08"
            case ..<2160: return "av01.0.12M.08"
            default: return "av01.0.13M.08"
            }
        case .vp9:
            return "vp09.00.40.08"
        case .avc1, .other, .none:
            return stream.effectiveHeight > 1080 ? "avc1.640033" : "avc1.64002A"
        }
    }

    static func audioCodecParameter(_ stream: YTMediaStream) -> String {
        if let raw = stream.audioCodecRaw, raw.contains(".") || raw == "opus" { return raw }
        let kind = stream.audioCodec
            ?? YTMediaStream.AudioCodecKind(rawValue: stream.audioCodecRaw ?? "")
        switch kind {
        case .opus:
            return "opus"
        case .mp4a, .other, .none:
            return "mp4a.40.2"
        }
    }

    static func peakBandwidth(video: YTMediaStream, audio: YTMediaStream) -> Int {
        let bandwidth = (video.bitrate ?? video.averageBitrate ?? 0)
            + (audio.bitrate ?? audio.averageBitrate ?? 0)
        guard bandwidth > 0 else { return estimatedBandwidth(height: video.effectiveHeight) }
        return bandwidth
    }

    static func averageBandwidth(video: YTMediaStream, audio: YTMediaStream) -> Int? {
        let average = (video.averageBitrate ?? video.bitrate ?? 0)
            + (audio.averageBitrate ?? audio.bitrate ?? 0)
        return average > 0 ? average : nil
    }

    /// Rough combined A+V bitrates used only when the streams carry no bitrate at
    /// all (BANDWIDTH is mandatory on EXT-X-STREAM-INF).
    static func estimatedBandwidth(height: Int) -> Int {
        switch height {
        case 2000...: return 16_000_000
        case 1400...: return 9_000_000
        case 1000...: return 5_000_000
        case 700...: return 2_800_000
        case 400...: return 1_400_000
        default: return 900_000
        }
    }

    static func resolutionParameter(height: Int?) -> String? {
        guard let height, height > 0 else { return nil }
        return "\(height * 16 / 9)x\(height)"
    }
}

/// Serves the three synthesized playlists for the custom `ytc://` scheme.
public final class YTComposedHLSResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let masterData: Data
    private let videoData: Data
    private let audioData: Data

    public init(masterPlaylist: String, videoPlaylist: String, audioPlaylist: String) {
        masterData = Data(masterPlaylist.utf8)
        videoData = Data(videoPlaylist.utf8)
        audioData = Data(audioPlaylist.utf8)
    }

    /// Testable lookup: only the three virtual playlist URLs are served here;
    /// real media requests stay on https and never reach this loader.
    func playlistData(for url: URL) -> Data? {
        guard url.scheme == YTComposedHLSEndpoint.scheme else { return nil }
        switch url.lastPathComponent {
        case YTComposedHLSEndpoint.masterURL.lastPathComponent:
            return masterData
        case YTComposedHLSEndpoint.videoPlaylistURL.lastPathComponent:
            return videoData
        case YTComposedHLSEndpoint.audioPlaylistURL.lastPathComponent:
            return audioData
        default:
            return nil
        }
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              let data = playlistData(for: url),
              let dataRequest = loadingRequest.dataRequest
        else {
            return false
        }
        let contentInformation = loadingRequest.contentInformationRequest
        contentInformation?.contentType = "application/vnd.apple.mpegurl"
        contentInformation?.contentLength = Int64(data.count)
        contentInformation?.isByteRangeAccessSupported = false
        dataRequest.respond(with: data)
        loadingRequest.finishLoading()
        return true
    }
}

/// Composed-HLS asset plus the loader delegate that must stay alive alongside it:
/// `AVAssetResourceLoader` holds its delegate weakly, so callers must retain this
/// wrapper for as long as the player item exists (same shape as ATV-Bilibili's
/// `PreparedPlayerMedia`).
public final class YTComposedHLSAsset {
    public let asset: AVURLAsset
    /// True when both tracks produced sidx-backed BYTERANGE playlists.
    public let usedSegmentedPlaylists: Bool
    private let loaderDelegate: YTComposedHLSResourceLoaderDelegate
    private let loaderQueue = DispatchQueue(label: "podcastenglishstudio.yt.composed-hls")

    public init(
        video: YTMediaStream,
        audio: YTMediaStream,
        durationHint: TimeInterval?,
        videoSegmentIndex: YTMP4SegmentIndex? = nil,
        audioSegmentIndex: YTMP4SegmentIndex? = nil
    ) {
        let videoPlaylist = YTComposedHLSPlaylistBuilder.mediaPlaylist(
            stream: video,
            durationHint: durationHint,
            segmentIndex: videoSegmentIndex
        )
        let audioPlaylist = YTComposedHLSPlaylistBuilder.mediaPlaylist(
            stream: audio,
            durationHint: durationHint,
            segmentIndex: audioSegmentIndex
        )
        usedSegmentedPlaylists = videoSegmentIndex != nil && audioSegmentIndex != nil
        loaderDelegate = YTComposedHLSResourceLoaderDelegate(
            masterPlaylist: YTComposedHLSPlaylistBuilder.masterPlaylist(video: video, audio: audio),
            videoPlaylist: videoPlaylist,
            audioPlaylist: audioPlaylist
        )
        asset = AVURLAsset(url: YTComposedHLSEndpoint.masterURL)
        asset.resourceLoader.setDelegate(loaderDelegate, queue: loaderQueue)
    }

    /// Probe both googlevideo URLs for `sidx` in parallel, then build the asset.
    /// Probe failures fall back to single-segment playlists (no throw).
    public static func make(
        video: YTMediaStream,
        audio: YTMediaStream,
        durationHint: TimeInterval?,
        indexFetcher: YTMP4SegmentIndexFetcher = .shared
    ) async -> YTComposedHLSAsset {
        let started = Date()
        let indexes = await indexFetcher.fetchIndexes(videoURL: video.url, audioURL: audio.url)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        print(
            "YTComposedHLS: sidx probe video=\(indexes.video != nil) audio=\(indexes.audio != nil) segmentsV=\(indexes.video?.segments.count ?? 0) segmentsA=\(indexes.audio?.segments.count ?? 0) ms=\(elapsedMs)"
        )
        return YTComposedHLSAsset(
            video: video,
            audio: audio,
            durationHint: durationHint,
            videoSegmentIndex: indexes.video,
            audioSegmentIndex: indexes.audio
        )
    }

    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = YTComposedHLSPlaylistBuilder.preferredForwardBufferDuration
        return item
    }
}
