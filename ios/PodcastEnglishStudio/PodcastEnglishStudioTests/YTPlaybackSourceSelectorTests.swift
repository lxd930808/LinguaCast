import AVFoundation
import XCTest
@testable import PodcastEnglishStudioCore

final class YTPlaybackSourceSelectorTests: XCTestCase {
    private func stream(
        itag: Int,
        height: Int?,
        kind: YTMediaStream.Kind,
        videoCodec: YTMediaStream.VideoCodecKind? = .avc1,
        audioCodec: YTMediaStream.AudioCodecKind? = nil,
        container: String = "mp4",
        bitrate: Int = 1_000_000,
        nativelyPlayable: Bool = true
    ) -> YTMediaStream {
        YTMediaStream(
            id: "\(itag)-\(kind.rawValue)",
            url: URL(string: "https://example.com/\(itag).\(container)")!,
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

    private var sampleResolved: YTResolvedMediaStreams {
        YTResolvedMediaStreams(
            progressive: [
                stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a, bitrate: 500_000),
                stream(itag: 22, height: 720, kind: .progressive, audioCodec: .mp4a, bitrate: 1_500_000)
            ],
            videoOnly: [
                stream(itag: 137, height: 1080, kind: .videoOnly, bitrate: 4_000_000),
                stream(itag: 264, height: 1440, kind: .videoOnly, bitrate: 8_000_000),
                stream(itag: 266, height: 2160, kind: .videoOnly, bitrate: 15_000_000),
                stream(itag: 248, height: 1080, kind: .videoOnly, videoCodec: .vp9, container: "webm", nativelyPlayable: false)
            ],
            audioOnly: [
                stream(itag: 140, height: nil, kind: .audioOnly, videoCodec: nil, audioCodec: .mp4a, container: "m4a", bitrate: 128_000),
                stream(itag: 251, height: nil, kind: .audioOnly, videoCodec: nil, audioCodec: .opus, container: "webm", bitrate: 160_000, nativelyPlayable: false)
            ],
            hlsURL: nil,
            expiresAt: Date().addingTimeInterval(600)
        )
    }

    func testWiFiAutoSelectsHighestHardwareDecodable() {
        let selection = YTPlaybackSourceSelector.select(
            from: sampleResolved,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .wifi,
                supportsAV1HardwareDecode: false
            )
        )
        XCTAssertEqual(selection?.actualHeight, 2160)
        if case .composed(let video, let audio)? = selection?.source {
            XCTAssertEqual(video.height, 2160)
            XCTAssertEqual(audio.container, "m4a")
        } else {
            XCTFail("Expected composed 2160p source")
        }
    }

    func testCellularAutoCapsAt1080() {
        let selection = YTPlaybackSourceSelector.select(
            from: sampleResolved,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .cellular,
                supportsAV1HardwareDecode: false
            )
        )
        XCTAssertEqual(selection?.actualHeight, 1080)
    }

    func testManual2160IgnoresCellularAutoCap() {
        let selection = YTPlaybackSourceSelector.select(
            from: sampleResolved,
            context: YTPlaybackSelectionContext(
                policy: .preferred(maxHeight: 2160),
                network: .cellular,
                supportsAV1HardwareDecode: false
            )
        )
        XCTAssertEqual(selection?.actualHeight, 2160)
    }

    func testExcludesVP9AndRespectsAV1HardwareFlag() {
        let withAV1 = YTResolvedMediaStreams(
            progressive: [],
            videoOnly: [
                stream(itag: 399, height: 1080, kind: .videoOnly, videoCodec: .av1),
                stream(itag: 248, height: 1080, kind: .videoOnly, videoCodec: .vp9, container: "webm", nativelyPlayable: false),
                stream(itag: 137, height: 720, kind: .videoOnly, videoCodec: .avc1, bitrate: 2_000_000)
            ],
            audioOnly: [
                stream(itag: 140, height: nil, kind: .audioOnly, videoCodec: nil, audioCodec: .mp4a, container: "m4a", bitrate: 128_000)
            ],
            hlsURL: nil,
            expiresAt: nil
        )

        let unsupported = YTPlaybackSourceSelector.select(
            from: withAV1,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .wifi,
                supportsAV1HardwareDecode: false
            )
        )
        XCTAssertEqual(unsupported?.actualHeight, 720)
        XCTAssertEqual(unsupported?.actualCodec, "avc1")

        let supported = YTPlaybackSourceSelector.select(
            from: withAV1,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .wifi,
                supportsAV1HardwareDecode: true
            )
        )
        XCTAssertEqual(supported?.actualHeight, 1080)
        XCTAssertEqual(supported?.actualCodec, "av1")
    }

    func testPrefersDirectProgressiveAtSameHeight() {
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 22, height: 720, kind: .progressive, audioCodec: .mp4a, bitrate: 1_500_000)
            ],
            videoOnly: [
                stream(itag: 136, height: 720, kind: .videoOnly, bitrate: 2_000_000)
            ],
            audioOnly: [
                stream(itag: 140, height: nil, kind: .audioOnly, videoCodec: nil, audioCodec: .mp4a, container: "m4a", bitrate: 128_000)
            ],
            hlsURL: nil,
            expiresAt: nil
        )
        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(policy: .highestQuality, network: .wifi)
        )
        if case .direct(let stream)? = selection?.source {
            XCTAssertEqual(stream.itag, 22)
            XCTAssertEqual(selection?.selectionMode, "direct")
        } else {
            XCTFail("Expected direct progressive at 720p")
        }
    }

    func testComposesWhenNoMatchingProgressive() {
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a, bitrate: 500_000)
            ],
            videoOnly: [
                stream(itag: 137, height: 1080, kind: .videoOnly, bitrate: 4_000_000)
            ],
            audioOnly: [
                stream(itag: 140, height: nil, kind: .audioOnly, videoCodec: nil, audioCodec: .mp4a, container: "m4a", bitrate: 128_000)
            ],
            hlsURL: nil,
            expiresAt: nil
        )
        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(policy: .highestQuality, network: .wifi)
        )
        if case .composed(let video, _)? = selection?.source {
            XCTAssertEqual(video.height, 1080)
            XCTAssertEqual(selection?.selectionMode, "composed")
        } else {
            XCTFail("Expected composed source")
        }
    }

    func testAutoPrefersAdaptiveHLSWhenSeparatedStreamsAlsoExist() {
        let hlsURL = URL(string: "https://example.com/master.m3u8")!
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 18, height: 360, kind: .progressive, audioCodec: .mp4a, bitrate: 500_000)
            ],
            videoOnly: [
                stream(itag: 137, height: 1080, kind: .videoOnly, bitrate: 4_000_000)
            ],
            audioOnly: [
                stream(itag: 140, height: nil, kind: .audioOnly, videoCodec: nil, audioCodec: .mp4a, container: "m4a", bitrate: 128_000)
            ],
            hlsURL: hlsURL,
            expiresAt: nil
        )

        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .cellular,
                supportsAV1HardwareDecode: false
            )
        )

        XCTAssertEqual(selection?.source, .hls(hlsURL, maximumHeight: 1080))
        XCTAssertEqual(selection?.selectionMode, "hls")
    }

    func testQualityFirstAutoPrefersHighestComposedStreamOverHLS() {
        let hlsURL = URL(string: "https://example.com/master.m3u8")!
        let resolved = YTResolvedMediaStreams(
            progressive: [
                stream(itag: 22, height: 720, kind: .progressive, audioCodec: .mp4a, bitrate: 1_500_000)
            ],
            videoOnly: [
                stream(itag: 137, height: 1080, kind: .videoOnly, bitrate: 4_000_000),
                stream(itag: 266, height: 2160, kind: .videoOnly, bitrate: 15_000_000)
            ],
            audioOnly: [
                stream(itag: 140, height: nil, kind: .audioOnly, videoCodec: nil, audioCodec: .mp4a, container: "m4a", bitrate: 128_000)
            ],
            hlsURL: hlsURL,
            expiresAt: nil
        )

        let selection = YTPlaybackSourceSelector.select(
            from: resolved,
            context: YTPlaybackSelectionContext(
                policy: .highestQuality,
                network: .wifi,
                supportsAV1HardwareDecode: false,
                prefersFixedQualityOverAdaptiveHLS: true
            )
        )

        XCTAssertEqual(selection?.actualHeight, 2160)
        XCTAssertEqual(selection?.selectionMode, "composed")
        if case .composed(let video, _)? = selection?.source {
            XCTAssertEqual(video.itag, 266)
        } else {
            XCTFail("Expected quality-first auto to compose the highest playable stream")
        }
    }

    @MainActor
    func testHLSPlayerItemAppliesMaximumHeight() async throws {
        let hlsURL = URL(string: "https://example.com/master.m3u8")!

        let prepared = try await YTPlaybackItemBuilder.makePreparedPlayback(
            from: .hls(hlsURL, maximumHeight: 1080)
        )

        XCTAssertEqual(prepared.primaryItem.preferredMaximumResolution.height, 1080)
        XCTAssertEqual(prepared.primaryItem.preferredMaximumResolution.width, 1920)
        XCTAssertNil(prepared.auxiliaryAudioItem)
    }

    @MainActor
    func testSeparatedStreamsBuildTwoIndependentPlayerItems() async throws {
        let video = stream(itag: 137, height: 1080, kind: .videoOnly)
        let audio = stream(
            itag: 140,
            height: nil,
            kind: .audioOnly,
            videoCodec: nil,
            audioCodec: .mp4a,
            container: "m4a",
            bitrate: 128_000
        )

        let prepared = try await YTPlaybackItemBuilder.makePreparedPlayback(
            from: .composed(video: video, audio: audio)
        )

        XCTAssertEqual((prepared.primaryItem.asset as? AVURLAsset)?.url, video.url)
        XCTAssertEqual((prepared.auxiliaryAudioItem?.asset as? AVURLAsset)?.url, audio.url)
    }

    func testDualPlayerSyncCorrectsOnlyMaterialDrift() {
        XCTAssertEqual(
            YTDualPlayerSyncPolicy.action(videoTime: 42, audioTime: 42.2),
            .none
        )
        XCTAssertEqual(
            YTDualPlayerSyncPolicy.action(videoTime: 42, audioTime: 42.6),
            .seekAudio(to: 42)
        )
    }

    func testInitialPreparationGetsLongerStallGraceThanActivePlayback() {
        XCTAssertEqual(
            YTPlaybackStallRecoveryPolicy.watchdogDelay(allItemsReady: false),
            25
        )
        XCTAssertEqual(
            YTPlaybackStallRecoveryPolicy.watchdogDelay(allItemsReady: true),
            8
        )
    }

    func testQualityTierInclude1440And2160() {
        XCTAssertTrue(
            YTStreamSelectionPolicy.qualityTierOptions.contains(.preferred(maxHeight: 1440))
        )
        XCTAssertTrue(
            YTStreamSelectionPolicy.qualityTierOptions.contains(.preferred(maxHeight: 2160))
        )
    }

    func testURLExpiryUsesExpireMinusFiveMinutes() {
        let url = URL(string: "https://example.com/v?expire=2000000000&itag=140")!
        let expires = YTMediaStreamURLExpiry.expiresAt(
            from: url,
            now: Date(timeIntervalSince1970: 1_999_999_000)
        )
        XCTAssertEqual(expires.timeIntervalSince1970, 2_000_000_000 - 300, accuracy: 0.1)
    }
}

final class YTMediaStreamResolverCacheTests: XCTestCase {
    actor StubResolver: YTMediaStreamResolving {
        var resolveCount = 0
        var streams: YTResolvedMediaStreams
        private var cache: [String: YTResolvedMediaStreams] = [:]
        private var inFlight: [String: Task<YTResolvedMediaStreams, Error>] = [:]

        init(streams: YTResolvedMediaStreams) {
            self.streams = streams
        }

        func resolve(videoID: String) async throws -> YTResolvedMediaStreams {
            if let cached = cache[videoID], !cached.isExpired {
                return cached
            }
            if let existing = inFlight[videoID] {
                return try await existing.value
            }
            let task = Task {
                resolveCount += 1
                try await Task.sleep(nanoseconds: 20_000_000)
                return streams
            }
            inFlight[videoID] = task
            defer { inFlight[videoID] = nil }
            let value = try await task.value
            cache[videoID] = value
            return value
        }

        func invalidate(videoID: String) async {
            cache[videoID] = nil
        }
    }

    func testConcurrentResolveSingleFlights() async throws {
        let streams = YTResolvedMediaStreams(
            progressive: [],
            videoOnly: [],
            audioOnly: [],
            hlsURL: URL(string: "https://example.com/live.m3u8"),
            expiresAt: Date().addingTimeInterval(600)
        )
        let resolver = StubResolver(streams: streams)
        async let a = resolver.resolve(videoID: "abc")
        async let b = resolver.resolve(videoID: "abc")
        _ = try await (a, b)
        let count = await resolver.resolveCount
        XCTAssertEqual(count, 1)
    }
}
