import XCTest
@testable import PodcastEnglishStudioCore

final class YTLocalMediaServiceClientTests: XCTestCase {
    func testConfigRequiresLocalServiceBackendAndCredentials() {
        let missing = YTLocalMediaServiceConfig.fromProcessEnvironment(environment: [
            "YT_LOCAL_MEDIA_BASE_URL": "http://127.0.0.1:3210",
            "YT_LOCAL_MEDIA_TOKEN": "abc"
        ])
        XCTAssertNil(missing)

        let invalidURL = YTLocalMediaServiceConfig.fromProcessEnvironment(environment: [
            "YT_PLAYBACK_BACKEND": "local-service",
            "YT_LOCAL_MEDIA_BASE_URL": "not a url",
            "YT_LOCAL_MEDIA_TOKEN": "abc"
        ])
        XCTAssertNil(invalidURL)

        let valid = YTLocalMediaServiceConfig.fromProcessEnvironment(environment: [
            "YT_PLAYBACK_BACKEND": "local-service",
            "YT_LOCAL_MEDIA_BASE_URL": "http://192.168.1.20:3210",
            "YT_LOCAL_MEDIA_TOKEN": "secret",
            "YT_LOCAL_MEDIA_MODE": "hls",
            "YT_LOCAL_MEDIA_PREFERRED_HEIGHT": "720"
        ])
        XCTAssertEqual(valid?.baseURL.absoluteString, "http://192.168.1.20:3210")
        XCTAssertEqual(valid?.token, "secret")
        XCTAssertEqual(valid?.mode, .hls)
        XCTAssertEqual(valid?.preferredHeight, 720)
    }

    func testResolvedConfigPrefersUserDefaults() {
        let suite = "yt.localMedia.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        YTLocalMediaServiceConfig.saveUserDefaults(
            enabled: true,
            baseURLString: "https://media.example.com",
            token: "tok",
            mode: .mp4,
            preferredHeight: 720,
            defaults: defaults
        )
        let resolved = YTLocalMediaServiceConfig.resolved(
            environment: [:],
            defaults: defaults
        )
        XCTAssertEqual(resolved?.baseURL.absoluteString, "https://media.example.com")
        XCTAssertEqual(resolved?.token, "tok")
        XCTAssertEqual(resolved?.preferredHeight, 720)
    }

    func testMobileSetupPatchParsesAndMergesFormFields() {
        let empty = YTLocalMediaServiceConfig.mobileSetupPatch(from: [:])
        XCTAssertFalse(empty.hasChanges)

        let suite = "yt.localMedia.mobile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        YTLocalMediaServiceConfig.saveUserDefaults(
            enabled: false,
            baseURLString: "http://old.example",
            token: "old-token",
            mode: .hls,
            preferredHeight: 1080,
            defaults: defaults
        )

        XCTAssertTrue(
            YTLocalMediaServiceConfig.applyMobileSetupPatch(
                from: [
                    "localMediaEnabled": "1",
                    "localMediaBaseURL": "http://192.0.2.10:3210",
                    "localMediaToken": "new-token",
                    "localMediaMode": "mp4",
                    "localMediaPreferredHeight": "720"
                ],
                defaults: defaults
            )
        )

        let stored = YTLocalMediaServiceConfig.loadUserDefaults(defaults: defaults)
        XCTAssertTrue(stored.enabled)
        XCTAssertEqual(stored.baseURLString, "http://192.0.2.10:3210")
        XCTAssertEqual(stored.token, "new-token")
        XCTAssertEqual(stored.mode, .mp4)
        XCTAssertEqual(stored.preferredHeight, 720)

        XCTAssertTrue(
            YTLocalMediaServiceConfig.applyMobileSetupPatch(
                from: ["localMediaPreferredHeight": "1080"],
                defaults: defaults
            )
        )
        let partial = YTLocalMediaServiceConfig.loadUserDefaults(defaults: defaults)
        XCTAssertEqual(partial.baseURLString, "http://192.0.2.10:3210")
        XCTAssertEqual(partial.preferredHeight, 1080)
    }

    func testPrepareAndJobDTODecoding() throws {
        let prepareJSON = """
        {"jobId":"01ABC","status":"queued","statusUrl":"http://127.0.0.1:3210/v1/jobs/01ABC"}
        """.data(using: .utf8)!
        let prepare = try JSONDecoder().decode(YTLocalMediaPrepareResponse.self, from: prepareJSON)
        XCTAssertEqual(prepare.jobId, "01ABC")
        XCTAssertEqual(prepare.status, .queued)

        let jobJSON = """
        {
          "jobId":"01ABC",
          "videoId":"jNQXAC9IVRw",
          "mode":"mp4",
          "preferredHeight":1080,
          "status":"ready",
          "progress":1,
          "errorCode":null,
          "errorMessage":null,
          "playback":{
            "kind":"mp4",
            "url":"http://127.0.0.1:3210/media/01ABC/output.mp4",
            "audioUrl":"http://127.0.0.1:3210/media/01ABC/audio.m4a",
            "height":1080,
            "videoCodec":"h264",
            "audioCodec":"aac",
            "durationSeconds":120.5,
            "itagVideo":137,
            "itagAudio":140
          }
        }
        """.data(using: .utf8)!
        let job = try JSONDecoder().decode(YTLocalMediaJobResponse.self, from: jobJSON)
        XCTAssertEqual(job.status, .ready)
        XCTAssertEqual(job.playback?.height, 1080)
        XCTAssertEqual(job.playback?.kind, .mp4)
        XCTAssertEqual(job.playback?.url.absoluteString, "http://127.0.0.1:3210/media/01ABC/output.mp4")
        XCTAssertEqual(job.playback?.audioURL?.absoluteString, "http://127.0.0.1:3210/media/01ABC/audio.m4a")
    }

    func testResolvedMP4MapsToProgressiveSource() {
        let playback = YTLocalMediaPlaybackInfo(
            kind: .mp4,
            url: URL(string: "http://127.0.0.1:3210/media/1/output.mp4")!,
            height: 1080,
            videoCodec: "h264",
            audioCodec: "aac",
            durationSeconds: 100,
            itagVideo: 137,
            itagAudio: 140
        )
        let streams = YTResolvedMediaStreams(
            progressive: [
                YTMediaStream(
                    id: "local",
                    url: playback.url,
                    itag: 137,
                    height: 1080,
                    bitrate: nil,
                    averageBitrate: nil,
                    videoCodec: .avc1,
                    audioCodec: .mp4a,
                    videoCodecRaw: "h264",
                    audioCodecRaw: "aac",
                    container: "mp4",
                    kind: .progressive,
                    isNativelyPlayable: true
                )
            ],
            videoOnly: [],
            audioOnly: [],
            hlsURL: nil,
            expiresAt: Date().addingTimeInterval(3600)
        )
        let selection = YTPlaybackSourceSelector.select(
            from: streams,
            context: YTPlaybackSelectionContext(
                policy: .preferred(maxHeight: 1080),
                network: .wifi,
                prefersFixedQualityOverAdaptiveHLS: true
            )
        )
        guard case .direct(let stream)? = selection?.source else {
            return XCTFail("Expected progressive direct source")
        }
        XCTAssertEqual(stream.height, 1080)
        XCTAssertEqual(stream.url.absoluteString, playback.url.absoluteString)
    }
}
