import AVFoundation
import XCTest
@testable import PodcastEnglishStudioCore

final class YTComposedHLSTests: XCTestCase {
    private func stream(
        itag: Int,
        height: Int?,
        kind: YTMediaStream.Kind,
        videoCodec: YTMediaStream.VideoCodecKind? = .avc1,
        audioCodec: YTMediaStream.AudioCodecKind? = nil,
        videoCodecRaw: String? = nil,
        audioCodecRaw: String? = nil,
        container: String = "mp4",
        bitrate: Int? = 1_000_000,
        averageBitrate: Int? = nil,
        url: String? = nil
    ) -> YTMediaStream {
        YTMediaStream(
            id: "\(itag)-\(kind.rawValue)",
            url: URL(string: url ?? "https://example.com/\(itag).\(container)")!,
            itag: itag,
            height: height,
            bitrate: bitrate,
            averageBitrate: averageBitrate,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            videoCodecRaw: videoCodecRaw ?? videoCodec?.rawValue,
            audioCodecRaw: audioCodecRaw ?? audioCodec?.rawValue,
            container: container,
            kind: kind,
            isNativelyPlayable: true
        )
    }

    private var video1080: YTMediaStream {
        stream(
            itag: 137,
            height: 1080,
            kind: .videoOnly,
            bitrate: 4_000_000,
            url: "https://rr1---sn-x.googlevideo.com/videoplayback?itag=137&dur=355.500"
        )
    }

    private var audioM4A: YTMediaStream {
        stream(
            itag: 140,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: .mp4a,
            container: "m4a",
            bitrate: 128_000,
            url: "https://rr1---sn-x.googlevideo.com/videoplayback?itag=140&dur=355.491"
        )
    }

    // MARK: Master playlist

    func testMasterPlaylistDeclaresAudioGroupAndVariant() {
        let master = YTComposedHLSPlaylistBuilder.masterPlaylist(
            video: video1080,
            audio: audioM4A
        )

        XCTAssertTrue(master.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(master.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        XCTAssertTrue(master.contains("GROUP-ID=\"audio\""))
        XCTAssertTrue(master.contains("URI=\"\(YTComposedHLSEndpoint.audioPlaylistURL.absoluteString)\""))
        XCTAssertTrue(master.contains("BANDWIDTH=4128000"))
        XCTAssertTrue(master.contains("CODECS=\"avc1.64002A,mp4a.40.2\""))
        XCTAssertTrue(master.contains("RESOLUTION=1920x1080"))
        XCTAssertTrue(master.contains("AUDIO=\"audio\""))
        XCTAssertTrue(master.contains("\n\(YTComposedHLSEndpoint.videoPlaylistURL.absoluteString)"))
    }

    func testMasterPlaylistOmitsResolutionWhenHeightUnknown() {
        let video = stream(itag: 137, height: nil, kind: .videoOnly)
        let master = YTComposedHLSPlaylistBuilder.masterPlaylist(video: video, audio: audioM4A)
        XCTAssertFalse(master.contains("RESOLUTION"))
    }

    func testMasterPlaylistEstimatesBandwidthWhenStreamsHaveNone() {
        let video = stream(itag: 137, height: 1080, kind: .videoOnly, bitrate: nil)
        let audio = stream(
            itag: 140,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: .mp4a,
            container: "m4a",
            bitrate: nil
        )
        let master = YTComposedHLSPlaylistBuilder.masterPlaylist(video: video, audio: audio)
        XCTAssertTrue(master.contains("BANDWIDTH=5000000"))
    }

    // MARK: Codec parameters

    func testFullCodecStringsPassThroughVerbatim() {
        let video = stream(
            itag: 137,
            height: 1080,
            kind: .videoOnly,
            videoCodecRaw: "avc1.640028"
        )
        let audio = stream(
            itag: 140,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: .mp4a,
            audioCodecRaw: "mp4a.40.2",
            container: "m4a"
        )
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.codecsParameter(video: video, audio: audio),
            "avc1.640028,mp4a.40.2"
        )
    }

    func testShortCodecNamesUpgradeByHeight() {
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.videoCodecParameter(
                stream(itag: 137, height: 720, kind: .videoOnly, videoCodecRaw: "avc1")
            ),
            "avc1.64002A"
        )
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.videoCodecParameter(
                stream(itag: 264, height: 1440, kind: .videoOnly, videoCodecRaw: "avc1")
            ),
            "avc1.640033"
        )
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.videoCodecParameter(
                stream(itag: 399, height: 1080, kind: .videoOnly, videoCodec: .av1, videoCodecRaw: "av1")
            ),
            "av01.0.08M.08"
        )
    }

    func testMissingCodecFallsBackToDefaults() {
        let video = stream(
            itag: 137,
            height: 1080,
            kind: .videoOnly,
            videoCodec: nil,
            videoCodecRaw: nil
        )
        let audio = stream(
            itag: 140,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: nil,
            audioCodecRaw: nil,
            container: "m4a"
        )
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.codecsParameter(video: video, audio: audio),
            "avc1.64002A,mp4a.40.2"
        )
        let opus = stream(
            itag: 251,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: .opus,
            container: "webm"
        )
        XCTAssertEqual(YTComposedHLSPlaylistBuilder.audioCodecParameter(opus), "opus")
    }

    // MARK: Media playlist

    func testMediaPlaylistIsSingleSegmentVODWithOriginalURL() {
        let playlist = YTComposedHLSPlaylistBuilder.mediaPlaylist(
            stream: video1080,
            durationHint: 355.5
        )

        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:356"))
        XCTAssertTrue(playlist.contains("#EXTINF:355.500,"))
        XCTAssertTrue(playlist.contains(video1080.url.absoluteString))
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testMediaPlaylistUsesByteRangeSegmentsWhenIndexProvided() {
        let index = YTMP4SegmentIndex(
            initByteLength: 1200,
            segments: [
                YTMP4MediaSegment(byteOffset: 1200, byteLength: 80_000, duration: 5.005),
                YTMP4MediaSegment(byteOffset: 81_200, byteLength: 79_000, duration: 4.990),
            ]
        )
        let playlist = YTComposedHLSPlaylistBuilder.mediaPlaylist(
            stream: video1080,
            durationHint: 355.5,
            segmentIndex: index
        )

        XCTAssertTrue(playlist.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:6"))
        XCTAssertTrue(
            playlist.contains(
                "#EXT-X-MAP:URI=\"\(video1080.url.absoluteString)\",BYTERANGE=\"1200@0\""
            )
        )
        XCTAssertTrue(playlist.contains("#EXTINF:5.005,"))
        XCTAssertTrue(playlist.contains("#EXT-X-BYTERANGE:80000@1200"))
        XCTAssertTrue(playlist.contains("#EXT-X-BYTERANGE:79000@81200"))
        XCTAssertFalse(playlist.contains("#EXT-X-TARGETDURATION:356"))
    }

    func testMediaPlaylistFallsBackToSingleSegmentWhenIndexEmpty() {
        let empty = YTMP4SegmentIndex(initByteLength: 0, segments: [])
        let playlist = YTComposedHLSPlaylistBuilder.mediaPlaylist(
            stream: video1080,
            durationHint: 10,
            segmentIndex: empty
        )
        XCTAssertTrue(playlist.contains("#EXT-X-VERSION:3"))
        XCTAssertTrue(playlist.contains("#EXTINF:10.000,"))
        XCTAssertFalse(playlist.contains("#EXT-X-MAP"))
    }

    func testDurationHintWinsOverURLDurParameter() {
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.resolvedDuration(for: video1080, hint: 100),
            100
        )
    }

    func testDurationFallsBackToGooglevideoDurParameter() {
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.resolvedDuration(for: video1080, hint: nil),
            355.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.resolvedDuration(for: video1080, hint: 0),
            355.5,
            accuracy: 0.001
        )
    }

    func testDurationFallsBackToPlaceholderWhenNothingKnown() {
        let bare = stream(itag: 137, height: 1080, kind: .videoOnly)
        XCTAssertEqual(
            YTComposedHLSPlaylistBuilder.resolvedDuration(for: bare, hint: nil),
            YTComposedHLSPlaylistBuilder.fallbackDuration
        )
        let playlist = YTComposedHLSPlaylistBuilder.mediaPlaylist(stream: bare, durationHint: nil)
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:10800"))
    }

    // MARK: Resource loader delegate

    func testResourceLoaderServesOnlyTheThreeVirtualPlaylists() {
        let delegate = YTComposedHLSResourceLoaderDelegate(
            masterPlaylist: "master",
            videoPlaylist: "video",
            audioPlaylist: "audio"
        )

        XCTAssertEqual(
            delegate.playlistData(for: YTComposedHLSEndpoint.masterURL).map { String(decoding: $0, as: UTF8.self) },
            "master"
        )
        XCTAssertEqual(
            delegate.playlistData(for: YTComposedHLSEndpoint.videoPlaylistURL).map { String(decoding: $0, as: UTF8.self) },
            "video"
        )
        XCTAssertEqual(
            delegate.playlistData(for: YTComposedHLSEndpoint.audioPlaylistURL).map { String(decoding: $0, as: UTF8.self) },
            "audio"
        )
        XCTAssertNil(delegate.playlistData(for: URL(string: "https://example.com/master.m3u8")!))
        XCTAssertNil(delegate.playlistData(for: URL(string: "ytc://composed/other.m3u8")!))
    }

    // MARK: Item builder switch

    /// Immediate-fail fetcher so builder tests never wait on a real Range probe.
    private var failingIndexFetcher: YTMP4SegmentIndexFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.05
        config.timeoutIntervalForResource = 0.05
        config.protocolClasses = [YTFailingURLProtocol.self]
        return YTMP4SegmentIndexFetcher(
            session: URLSession(configuration: config),
            timeout: 0.05
        )
    }

    @MainActor
    func testComposedSourceBuildsSingleSynthesizedHLSItemWhenPreferred() async throws {
        let prepared = try await YTPlaybackItemBuilder.makePreparedPlayback(
            from: .composed(video: video1080, audio: audioM4A),
            prefersComposedHLSSinglePlayer: true,
            composedHLSDurationHint: 355.5,
            segmentIndexFetcher: failingIndexFetcher
        )

        XCTAssertNil(prepared.auxiliaryAudioItem)
        XCTAssertNotNil(prepared.composedHLSAsset)
        XCTAssertEqual(prepared.composedHLSAsset?.usedSegmentedPlaylists, false)
        XCTAssertEqual(
            (prepared.primaryItem.asset as? AVURLAsset)?.url,
            YTComposedHLSEndpoint.masterURL
        )
        XCTAssertEqual(
            prepared.primaryItem.preferredForwardBufferDuration,
            YTComposedHLSPlaylistBuilder.preferredForwardBufferDuration,
            accuracy: 0.001
        )
    }

    @MainActor
    func testComposedSourceKeepsDualItemsWhenSinglePlayerNotPreferred() async throws {
        let prepared = try await YTPlaybackItemBuilder.makePreparedPlayback(
            from: .composed(video: video1080, audio: audioM4A),
            prefersComposedHLSSinglePlayer: false
        )

        XCTAssertEqual((prepared.primaryItem.asset as? AVURLAsset)?.url, video1080.url)
        XCTAssertEqual((prepared.auxiliaryAudioItem?.asset as? AVURLAsset)?.url, audioM4A.url)
        XCTAssertNil(prepared.composedHLSAsset)
    }

    func testComposedAssetUsesSegmentedFlagWhenBothIndexesPresent() {
        let index = YTMP4SegmentIndex(
            initByteLength: 100,
            segments: [YTMP4MediaSegment(byteOffset: 100, byteLength: 1000, duration: 2)]
        )
        let asset = YTComposedHLSAsset(
            video: video1080,
            audio: audioM4A,
            durationHint: 10,
            videoSegmentIndex: index,
            audioSegmentIndex: index
        )
        XCTAssertTrue(asset.usedSegmentedPlaylists)
    }
}

private final class YTFailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let error = URLError(.timedOut)
        client?.urlProtocol(self, didFailWithError: error)
    }
    override func stopLoading() {}
}
