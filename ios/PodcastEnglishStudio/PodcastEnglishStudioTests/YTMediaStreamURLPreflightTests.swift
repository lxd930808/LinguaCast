import XCTest
@testable import PodcastEnglishStudioCore

final class YTMediaStreamURLPreflightTests: XCTestCase {
    override func tearDown() {
        PreflightTestURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private var gvsURL: URL {
        URL(string: "https://rr1---sn-test.googlevideo.com/videoplayback?itag=137")!
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreflightTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func respond(statusCode: Int) {
        PreflightTestURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (response, Data([0, 1]))
        }
    }

    func testPartialContentIsPlayableAndUsesRangeRequest() async {
        PreflightTestURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-1")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 206,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (response, Data([0, 1]))
        }

        let outcome = await YTMediaStreamURLPreflight.probe(gvsURL, session: session())
        XCTAssertEqual(outcome, .playable)
    }

    func testForbiddenAndGoneAreDefinitiveRejections() async {
        for status in [401, 403, 410] {
            respond(statusCode: status)
            let outcome = await YTMediaStreamURLPreflight.probe(gvsURL, session: session())
            XCTAssertEqual(outcome, .rejected(statusCode: status))
        }
    }

    func testServerErrorsAndTransportFailuresFailOpen() async {
        respond(statusCode: 500)
        let serverError = await YTMediaStreamURLPreflight.probe(gvsURL, session: session())
        XCTAssertEqual(serverError, .inconclusive)

        PreflightTestURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        let transportError = await YTMediaStreamURLPreflight.probe(gvsURL, session: session())
        XCTAssertEqual(transportError, .inconclusive)

        // Fail-open: an inconclusive probe must not drop the candidate.
        let stream = stream(
            itag: 137,
            height: 1080,
            kind: .videoOnly,
            host: "rr1---sn-test.googlevideo.com"
        )
        let playable = await YTMediaStreamURLPreflight.isSourcePlayable(
            .direct(stream: stream),
            session: session()
        )
        XCTAssertTrue(playable)
    }

    func testComposedSourceIsRejectedWhenEitherTrackIsRefused() async {
        PreflightTestURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let statusCode = url.absoluteString.contains("140") ? 403 : 206
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (response, Data([0, 1]))
        }

        let video = stream(itag: 137, height: 1080, kind: .videoOnly, host: "rr1---sn-test.googlevideo.com")
        let audio = stream(
            itag: 140,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: .mp4a,
            container: "m4a",
            host: "rr1---sn-test.googlevideo.com"
        )

        let playable = await YTMediaStreamURLPreflight.isSourcePlayable(
            .composed(video: video, audio: audio),
            session: session()
        )
        XCTAssertFalse(playable)
    }

    func testHLSSourceIsNeverRejectedByPreflight() async {
        respond(statusCode: 403)

        let manifest = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/master.m3u8")!
        let playable = await YTMediaStreamURLPreflight.isSourcePlayable(
            .hls(manifest, maximumHeight: nil),
            session: session()
        )

        XCTAssertTrue(playable)
    }

    func testProbeSendsMediaUserAgent() async {
        PreflightTestURLProtocol.requestHandler = { request in
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            XCTAssertTrue(agent.hasPrefix("AppleCoreMedia/"), "unexpected agent: \(agent)")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 206,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (response, Data([0, 1]))
        }

        let outcome = await YTMediaStreamURLPreflight.probe(gvsURL, session: session())
        XCTAssertEqual(outcome, .playable)
    }

    func testSkipsPreflightForNonYouTubeHosts() async {
        let url = URL(string: "https://example.com/video.mp4")!
        let outcome = await YTMediaStreamURLPreflight.probe(url)
        XCTAssertEqual(outcome, .playable)
        XCTAssertFalse(YTMediaStreamURLPreflight.shouldPreflight(url))
    }

    func testExcludingRemovesFailedStreamsAndHLS() {
        let video = stream(itag: 137, height: 1080, kind: .videoOnly)
        let audio = stream(
            itag: 140,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: .mp4a,
            container: "m4a"
        )
        let progressive = stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a)
        let hls = URL(string: "https://example.com/master.m3u8")!
        let resolved = YTResolvedMediaStreams(
            progressive: [progressive],
            videoOnly: [video],
            audioOnly: [audio],
            hlsURL: hls,
            expiresAt: nil
        )

        let filtered = YTResolvedMediaStreamsFiltering.excluding(
            resolved,
            urls: [video.url, hls]
        )

        XCTAssertTrue(filtered.videoOnly.isEmpty)
        XCTAssertEqual(filtered.progressive.map(\.itag), [18])
        XCTAssertNil(filtered.hlsURL)
        XCTAssertEqual(filtered.audioOnly.map(\.itag), [140])
    }

    func testQualityFirstPrefersHLSWhenOnlyLowFixedRemains() {
        let hlsURL = URL(string: "https://example.com/master.m3u8")!
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a)
            ],
            videoOnly: [],
            audioOnly: [
                stream(
                    itag: 140,
                    height: nil,
                    kind: .audioOnly,
                    videoCodec: nil,
                    audioCodec: .mp4a,
                    container: "m4a"
                )
            ],
            hlsURL: hlsURL,
            expiresAt: nil
        )

        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .wifi,
                prefersFixedQualityOverAdaptiveHLS: true
            )
        )

        XCTAssertEqual(selection?.source, .hls(hlsURL, maximumHeight: nil))
        XCTAssertEqual(selection?.selectionMode, "hls-low-fixed-fallback")
        XCTAssertEqual(selection?.actualCodec, "hls")
    }

    func testQualityFirstKeepsComposedWhenFixedHDExists() {
        let hlsURL = URL(string: "https://example.com/master.m3u8")!
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a)
            ],
            videoOnly: [
                stream(itag: 137, height: 1080, kind: .videoOnly)
            ],
            audioOnly: [
                stream(
                    itag: 140,
                    height: nil,
                    kind: .audioOnly,
                    videoCodec: nil,
                    audioCodec: .mp4a,
                    container: "m4a"
                )
            ],
            hlsURL: hlsURL,
            expiresAt: nil
        )

        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .wifi,
                prefersFixedQualityOverAdaptiveHLS: true
            )
        )

        XCTAssertEqual(selection?.actualHeight, 1080)
        XCTAssertEqual(selection?.selectionMode, "composed")
    }

    func testManual1080FallsToHLSWhenOnly360Remains() {
        let hlsURL = URL(string: "https://example.com/master.m3u8")!
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a)
            ],
            videoOnly: [],
            audioOnly: [],
            hlsURL: hlsURL,
            expiresAt: nil
        )

        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(
                policy: .preferred(maxHeight: 1080),
                network: .wifi,
                prefersFixedQualityOverAdaptiveHLS: true
            )
        )

        XCTAssertEqual(selection?.selectionMode, "hls-preflight-fallback")
        XCTAssertEqual(selection?.actualCodec, "hls")
    }

    func testOnly360WithoutHLSStaysProgressive() {
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a)
            ],
            videoOnly: [],
            audioOnly: [],
            hlsURL: nil,
            expiresAt: nil
        )

        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .wifi,
                prefersFixedQualityOverAdaptiveHLS: true
            )
        )

        XCTAssertEqual(selection?.actualHeight, 360)
        if case .direct = selection?.source {
            // ok
        } else {
            XCTFail("Expected direct 360 progressive")
        }
    }

    private func stream(
        itag: Int,
        height: Int?,
        kind: YTMediaStream.Kind,
        videoCodec: YTMediaStream.VideoCodecKind? = .avc1,
        audioCodec: YTMediaStream.AudioCodecKind? = nil,
        container: String = "mp4",
        bitrate: Int = 1_000_000,
        nativelyPlayable: Bool = true,
        host: String = "example.com"
    ) -> YTMediaStream {
        YTMediaStream(
            id: "\(itag)-\(kind.rawValue)",
            url: URL(string: "https://\(host)/\(itag).\(container)")!,
            itag: itag,
            height: height,
            bitrate: bitrate,
            averageBitrate: bitrate,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            videoCodecRaw: videoCodec?.rawValue,
            audioCodecRaw: audioCodec?.rawValue,
            container: container,
            kind: kind,
            isNativelyPlayable: nativelyPlayable
        )
    }
}

private final class PreflightTestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
