import XCTest
@testable import PodcastEnglishStudioCore

final class YTCaptionFetchingTests: XCTestCase {
    private var clock: ManualYTCaptionClock!
    private var store: InMemoryYTCaptionRequestStateStore!

    override func setUp() {
        super.setUp()
        CaptionTestURLProtocol.reset()
        clock = ManualYTCaptionClock(Date(timeIntervalSince1970: 1_700_000_000))
        store = InMemoryYTCaptionRequestStateStore()
    }

    override func tearDown() {
        CaptionTestURLProtocol.reset()
        super.tearDown()
    }

    func testWatchPlusJSON3SuccessMakesExactlyTwoRequests() async throws {
        let videoID = "abc12345678"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validJSON3(), headers: ["Content-Type": "application/json"])
        )

        let service = makeService()
        let package = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)

        XCTAssertFalse(package.segments.isEmpty)
        XCTAssertEqual(CaptionTestURLProtocol.requests.count, 2)
        XCTAssertTrue(CaptionTestURLProtocol.requests[0].url!.absoluteString.contains("watch?v=\(videoID)"))
        XCTAssertTrue(CaptionTestURLProtocol.requests[1].url!.absoluteString.contains("fmt=json3"))
        XCTAssertFalse(CaptionTestURLProtocol.requests.contains { $0.url?.absoluteString.contains("youtubei/v1/player") == true })
        XCTAssertFalse(CaptionTestURLProtocol.requests.contains { $0.url?.absoluteString.contains("fmt=vtt") == true })
    }

    func testConcurrentIdenticalRequestsShareOneNetworkFlight() async throws {
        let videoID = "concurrent01"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validJSON3(), headers: ["Content-Type": "application/json"], delayMS: 50)
        )

        let service = makeService()
        async let first = service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
        async let second = service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
        let packages = try await [first, second]

        XCTAssertEqual(packages[0].segments.count, packages[1].segments.count)
        XCTAssertEqual(CaptionTestURLProtocol.requests.count, 2)
    }

    func testTracksWithDifferentSignedURLsButSameVssIDDedupe() throws {
        let left = YTCaptionTrack(
            languageCode: "en",
            name: "English",
            kind: "asr",
            baseURL: "https://www.youtube.com/api/timedtext?v=1&lang=en&expire=1&signature=aaa&ei=1",
            vssID: "a.en"
        )
        let right = YTCaptionTrack(
            languageCode: "en",
            name: "English",
            kind: "asr",
            baseURL: "https://www.youtube.com/api/timedtext?v=1&lang=en&expire=2&signature=bbb&ei=2",
            vssID: "a.en"
        )
        XCTAssertEqual(left.stableIdentity, right.stableIdentity)
    }

    func testExpXPEWithoutPoTokenSkipsTimedtextAndUsesIOS() async throws {
        let videoID = "attest00001"
        let attested = timedtextURL(videoID: videoID) + "&exp=xpe"
        enqueueWatch(videoID: videoID, tracks: [
            englishTrackJSON(baseURL: attested, vssID: "a.en")
        ])
        CaptionTestURLProtocol.enqueue(
            .response(
                status: 200,
                body: playerResponseJSON(tracks: [
                    englishTrackJSON(baseURL: timedtextURL(videoID: videoID, pathSuffix: "ios"), vssID: "a.en")
                ]),
                headers: ["Content-Type": "application/json"]
            )
        )
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validJSON3(), headers: ["Content-Type": "application/json"])
        )

        let service = makeService()
        _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)

        XCTAssertEqual(CaptionTestURLProtocol.requests.count, 3)
        XCTAssertTrue(CaptionTestURLProtocol.requests[1].url!.absoluteString.contains("youtubei/v1/player"))
        XCTAssertEqual(CaptionTestURLProtocol.requests[1].value(forHTTPHeaderField: "User-Agent"), YTCaptionClientsTestSupport.iosUserAgent)
        XCTAssertTrue(CaptionTestURLProtocol.requests[2].url!.absoluteString.contains("fmt=json3"))
        XCTAssertFalse(CaptionTestURLProtocol.requests[2].url!.absoluteString.contains("exp=xpe"))
    }

    func testJSON3ParseFailureFallsBackToVTTOnce() async throws {
        let videoID = "fallback0001"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: "{not-json", headers: ["Content-Type": "application/json"])
        )
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validVTT(), headers: ["Content-Type": "text/vtt"])
        )

        let service = makeService()
        let package = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)

        XCTAssertFalse(package.segments.isEmpty)
        XCTAssertEqual(CaptionTestURLProtocol.requests.count, 3)
        XCTAssertTrue(CaptionTestURLProtocol.requests[1].url!.absoluteString.contains("fmt=json3"))
        XCTAssertTrue(CaptionTestURLProtocol.requests[2].url!.absoluteString.contains("fmt=vtt"))
    }

    func testQualityRejectionDoesNotFallBackToVTT() async throws {
        let videoID = "quality0001"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: lowQualityJSON3(), headers: ["Content-Type": "application/json"])
        )

        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 0)
            XCTFail("Expected quality rejection")
        } catch YTCaptionError.captionQualityRejected {
            XCTAssertEqual(CaptionTestURLProtocol.requests.count, 2)
            XCTAssertFalse(CaptionTestURLProtocol.requests.contains { $0.url?.absoluteString.contains("fmt=vtt") == true })
        }
    }

    func testJSON3429DoesNotRequestVTTOrNextTrack() async throws {
        let videoID = "rate0000001"
        enqueueWatch(videoID: videoID, tracks: [
            englishTrackJSON(baseURL: timedtextURL(videoID: videoID), vssID: "a.en"),
            englishTrackJSON(baseURL: timedtextURL(videoID: videoID, pathSuffix: "b"), language: "en-US", vssID: "b.en")
        ])
        CaptionTestURLProtocol.enqueue(
            .response(status: 429, body: "rate", headers: ["Retry-After": "120"])
        )

        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
            XCTFail("Expected rate limit")
        } catch let YTCaptionError.rateLimited(retryAt) {
            XCTAssertEqual(retryAt.timeIntervalSince1970, clock.now.timeIntervalSince1970 + 120, accuracy: 0.01)
            XCTAssertEqual(CaptionTestURLProtocol.requests.count, 2)
            XCTAssertFalse(CaptionTestURLProtocol.requests.contains { $0.url?.absoluteString.contains("fmt=vtt") == true })
        }
    }

    func testCooldownBlocksOtherVideosWithoutNetwork() async throws {
        let first = "ratevideo01"
        enqueueWatch(videoID: first, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: first))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 429, body: "rate", headers: ["Retry-After": "60"])
        )

        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: first, qualityTolerance: 1)
            XCTFail("Expected rate limit")
        } catch YTCaptionError.rateLimited {
            // expected
        }
        let countAfterFirst = CaptionTestURLProtocol.requests.count

        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: "othervideo1", qualityTolerance: 1)
            XCTFail("Expected cooldown")
        } catch YTCaptionError.rateLimited {
            XCTAssertEqual(CaptionTestURLProtocol.requests.count, countAfterFirst)
        }
    }

    func testRetryAfterHTTPDateAndDefaultExponentialCooldown() async throws {
        let videoID = "httpretry01"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        let retryAt = clock.now.addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        CaptionTestURLProtocol.enqueue(
            .response(
                status: 429,
                body: "rate",
                headers: ["Retry-After": formatter.string(from: retryAt)]
            )
        )

        let service = makeService(jitter: FixedYTCaptionJitterSource(0))
        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
            XCTFail("Expected rate limit")
        } catch let YTCaptionError.rateLimited(date) {
            XCTAssertEqual(date.timeIntervalSince1970, retryAt.timeIntervalSince1970, accuracy: 1)
        }

        // Fresh state for default exponential cooldown without Retry-After.
        store = InMemoryYTCaptionRequestStateStore()
        clock.now = retryAt.addingTimeInterval(1)
        let secondService = makeService(jitter: FixedYTCaptionJitterSource(0))
        let second = "httpretry02"
        enqueueWatch(videoID: second, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: second))])
        CaptionTestURLProtocol.enqueue(.response(status: 429, body: "rate", headers: [:]))
        do {
            _ = try await secondService.fetchEnglishCaptionPackage(videoID: second, qualityTolerance: 1)
            XCTFail("Expected rate limit")
        } catch let YTCaptionError.rateLimited(date) {
            XCTAssertEqual(date.timeIntervalSince1970, clock.now.timeIntervalSince1970 + 15 * 60, accuracy: 0.01)
        }
    }

    func testDefaultCooldownCapsAtSixHoursAndResetsAfterSuccess() async throws {
        let coordinator = YTCaptionRequestCoordinator(
            stateStore: store,
            clock: clock,
            jitter: FixedYTCaptionJitterSource(0)
        )
        // Simulate successive 429 defaults.
        for expectedMinutes in [15, 30, 60, 120, 360, 360] {
            let until = await coordinator.makeDefaultCooldown()
            XCTAssertEqual(until.timeIntervalSince(clock.now), TimeInterval(expectedMinutes * 60), accuracy: 0.01)
            await coordinator.noteRateLimited(retryAt: until)
            clock.now = until.addingTimeInterval(1)
        }

        let service = YTCaptionService(
            session: makeSession(),
            coordinator: coordinator,
            clock: clock,
            jitter: FixedYTCaptionJitterSource(0)
        )
        let videoID = "successreset"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validJSON3(), headers: ["Content-Type": "application/json"])
        )
        _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
        let afterSuccess = await coordinator.rateLimitedRetryAt()
        XCTAssertNil(afterSuccess)
    }

    func testPersistedCooldownSurvivesRestart() async throws {
        let videoID = "persist0001"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 429, body: "rate", headers: ["Retry-After": "300"])
        )
        let first = makeService()
        do {
            _ = try await first.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
            XCTFail("Expected rate limit")
        } catch YTCaptionError.rateLimited {
            // expected
        }
        let count = CaptionTestURLProtocol.requests.count

        let restarted = makeService()
        do {
            _ = try await restarted.fetchEnglishCaptionPackage(videoID: "anothervid1", qualityTolerance: 1)
            XCTFail("Expected persisted cooldown")
        } catch YTCaptionError.rateLimited {
            XCTAssertEqual(CaptionTestURLProtocol.requests.count, count)
        }
    }

    func testSignature404RefreshesTracksOnceThenStops() async throws {
        let videoID = "sigexpire01"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(.response(status: 404, body: "gone", headers: [:]))
        // Refresh watch + json3 still 404
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID, pathSuffix: "new"))])
        CaptionTestURLProtocol.enqueue(.response(status: 404, body: "gone", headers: [:]))

        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
            XCTFail("Expected http failure")
        } catch YTCaptionError.httpFailure(let status) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(CaptionTestURLProtocol.requests.count, 4)
        }
    }

    func testIOSAndWebCarryMatchingUAAndVisitorContext() async throws {
        let videoID = "context0001"
        let attested = timedtextURL(videoID: videoID) + "&exp=xpv"
        enqueueWatch(
            videoID: videoID,
            tracks: [englishTrackJSON(baseURL: attested)],
            visitorData: "visitor-token-1"
        )
        CaptionTestURLProtocol.enqueue(
            .response(
                status: 200,
                body: playerResponseJSON(tracks: [
                    englishTrackJSON(baseURL: timedtextURL(videoID: videoID, pathSuffix: "ios"))
                ]),
                headers: ["Content-Type": "application/json"]
            )
        )
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validJSON3(), headers: ["Content-Type": "application/json"])
        )

        let service = makeService()
        _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)

        let watchUA = CaptionTestURLProtocol.requests[0].value(forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(watchUA, YTCaptionClientsTestSupport.webUserAgent)
        let player = CaptionTestURLProtocol.requests[1]
        XCTAssertEqual(player.value(forHTTPHeaderField: "User-Agent"), YTCaptionClientsTestSupport.iosUserAgent)
        XCTAssertEqual(player.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), "visitor-token-1")
        let timedtext = CaptionTestURLProtocol.requests[2]
        XCTAssertEqual(timedtext.value(forHTTPHeaderField: "User-Agent"), YTCaptionClientsTestSupport.iosUserAgent)
        XCTAssertEqual(timedtext.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), "visitor-token-1")
    }

    func testNegativeCacheHitExpiryAndTrim() async throws {
        let coordinator = YTCaptionRequestCoordinator(
            stateStore: store,
            clock: clock,
            jitter: FixedYTCaptionJitterSource(0),
            negativeCacheLimit: 2,
            negativeTTL: 6 * 3600
        )
        let service = YTCaptionService(
            session: makeSession(),
            coordinator: coordinator,
            clock: clock,
            jitter: FixedYTCaptionJitterSource(0)
        )

        for videoID in ["neg00000001", "neg00000002", "neg00000003"] {
            enqueueWatch(videoID: videoID, tracks: [])
            // iOS empty
            CaptionTestURLProtocol.enqueue(
                .response(status: 200, body: playerResponseJSON(tracks: []), headers: ["Content-Type": "application/json"])
            )
            // Android VR empty
            CaptionTestURLProtocol.enqueue(
                .response(status: 200, body: playerResponseJSON(tracks: []), headers: ["Content-Type": "application/json"])
            )
            do {
                _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
                XCTFail("Expected missing")
            } catch YTCaptionError.missingEnglishTrack {
                // expected
            }
            // Spacing between launches.
            clock.now = clock.now.addingTimeInterval(3)
        }

        let before = CaptionTestURLProtocol.requests.count
        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: "neg00000003", qualityTolerance: 1)
            XCTFail("Expected negative cache")
        } catch YTCaptionError.missingEnglishTrack {
            XCTAssertEqual(CaptionTestURLProtocol.requests.count, before)
        }

        // Oldest entries trimmed to 2; first video should not be negatively cached anymore.
        enqueueWatch(videoID: "neg00000001", tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: "neg00000001"))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validJSON3(), headers: ["Content-Type": "application/json"])
        )
        clock.now = clock.now.addingTimeInterval(3)
        _ = try await service.fetchEnglishCaptionPackage(videoID: "neg00000001", qualityTolerance: 1)

        // Expire negative cache for video 3.
        clock.now = clock.now.addingTimeInterval(6 * 3600 + 1)
        enqueueWatch(videoID: "neg00000003", tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: "neg00000003"))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: validJSON3(), headers: ["Content-Type": "application/json"])
        )
        _ = try await service.fetchEnglishCaptionPackage(videoID: "neg00000003", qualityTolerance: 1)
    }

    func testErrorCodesAndNoChannelIDInference() async throws {
        let videoID = "blocked0001"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 403, body: "<!DOCTYPE html><html>deny</html>", headers: ["Content-Type": "text/html"])
        )
        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(videoID: videoID, qualityTolerance: 1)
            XCTFail("Expected access blocked")
        } catch let error as YTCaptionError {
            XCTAssertEqual(error.stableErrorCode, "youtube_caption_access_blocked")
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("channel ID"))
        }
    }

    // MARK: - Ingestion policy

    func testLenientPolicyAcceptsLowQualityJSON3() async throws {
        let videoID = "lenient0001"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: lowQualityJSON3(), headers: ["Content-Type": "application/json"])
        )

        let service = makeService()
        let package = try await service.fetchEnglishCaptionPackage(
            videoID: videoID,
            qualityTolerance: 0,
            ingestionPolicy: .acceptParseableContent
        )

        XCTAssertFalse(package.segments.isEmpty)
        XCTAssertFalse(package.englishVTT.isEmpty)
    }

    func testLenientPolicyAcceptsLowQualityVTTFallback() async throws {
        let videoID = "lenient0002"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: "{not-json", headers: ["Content-Type": "application/json"])
        )
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: lowQualityVTT(), headers: ["Content-Type": "text/vtt"])
        )

        let service = makeService()
        let package = try await service.fetchEnglishCaptionPackage(
            videoID: videoID,
            qualityTolerance: 0,
            ingestionPolicy: .acceptParseableContent
        )
        XCTAssertFalse(package.segments.isEmpty)
    }

    func testStrictPolicyRejectsLowQualityVTTFallback() async throws {
        let videoID = "strictvtt001"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: "{not-json", headers: ["Content-Type": "application/json"])
        )
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: lowQualityVTT(), headers: ["Content-Type": "text/vtt"])
        )

        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(
                videoID: videoID,
                qualityTolerance: 0,
                ingestionPolicy: .strict
            )
            XCTFail("Expected quality rejection")
        } catch YTCaptionError.captionQualityRejected {
            // expected
        }
    }

    func testLenientPolicyStillRejectsEmptyTrack() async throws {
        let videoID = "lenient0003"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: "", headers: ["Content-Type": "application/json"])
        )
        // An empty json3 body falls back to VTT; an empty VTT result is retried once
        // through the empty-response catch path, so two VTT responses are consumed.
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: "", headers: ["Content-Type": "text/vtt"])
        )
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: "", headers: ["Content-Type": "text/vtt"])
        )

        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(
                videoID: videoID,
                qualityTolerance: 1,
                ingestionPolicy: .acceptParseableContent
            )
            XCTFail("Expected empty caption rejection")
        } catch let error as YTCaptionError {
            switch error {
            case .emptyCaptionFile, .emptyCaptionResponse:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLenientPolicyStillPropagatesRateLimit() async throws {
        let videoID = "lenient0004"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 429, body: "rate", headers: ["Retry-After": "120"])
        )

        let service = makeService()
        do {
            _ = try await service.fetchEnglishCaptionPackage(
                videoID: videoID,
                qualityTolerance: 1,
                ingestionPolicy: .acceptParseableContent
            )
            XCTFail("Expected rate limit")
        } catch YTCaptionError.rateLimited {
            // expected: the lenient policy never bypasses transport-level errors
        }
    }

    func testSuccessCacheIsScopedByIngestionPolicy() async throws {
        let videoID = "cachepol0001"
        enqueueWatch(videoID: videoID, tracks: [englishTrackJSON(baseURL: timedtextURL(videoID: videoID))])
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: lowQualityJSON3(), headers: ["Content-Type": "application/json"])
        )

        let service = makeService()
        let package = try await service.fetchEnglishCaptionPackage(
            videoID: videoID,
            qualityTolerance: 0,
            ingestionPolicy: .acceptParseableContent
        )
        XCTAssertFalse(package.segments.isEmpty)
        let requestsAfterLenient = CaptionTestURLProtocol.requests.count

        // A strict fetch for the same video must NOT reuse the lenient success cache:
        // it hits the network again (track cache is shared) and rejects the track.
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: lowQualityJSON3(), headers: ["Content-Type": "application/json"])
        )
        do {
            _ = try await service.fetchEnglishCaptionPackage(
                videoID: videoID,
                qualityTolerance: 0,
                ingestionPolicy: .strict
            )
            XCTFail("Expected quality rejection under the strict policy")
        } catch YTCaptionError.captionQualityRejected {
            XCTAssertGreaterThan(CaptionTestURLProtocol.requests.count, requestsAfterLenient)
        }
    }

    // MARK: - Helpers

    private func makeService(
        jitter: YTCaptionJitterSource = FixedYTCaptionJitterSource(0)
    ) -> YTCaptionService {
        let coordinator = YTCaptionRequestCoordinator(
            stateStore: store,
            clock: clock,
            jitter: jitter,
            minimumLaunchSpacing: 0
        )
        return YTCaptionService(
            session: makeSession(),
            coordinator: coordinator,
            clock: clock,
            jitter: jitter
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptionTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func enqueueWatch(videoID: String, tracks: [[String: Any]], visitorData: String = "visitor-data") {
        let html = watchHTML(videoID: videoID, tracks: tracks, visitorData: visitorData)
        CaptionTestURLProtocol.enqueue(
            .response(status: 200, body: html, headers: ["Content-Type": "text/html"])
        )
    }

    private func watchHTML(videoID: String, tracks: [[String: Any]], visitorData: String) -> String {
        let tracksJSON = jsonString(tracks)
        return """
        <html><head></head><body>
        <script>ytcfg.set({"INNERTUBE_API_KEY":"test-key","VISITOR_DATA":"\(visitorData)"});</script>
        <script>
        var ytInitialPlayerResponse = {
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": \(tracksJSON)
            }
          }
        };
        </script>
        </body></html>
        """
    }

    private func playerResponseJSON(tracks: [[String: Any]]) -> String {
        """
        {
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": \(jsonString(tracks))
            }
          }
        }
        """
    }

    private func englishTrackJSON(
        baseURL: String,
        language: String = "en",
        vssID: String = "a.en"
    ) -> [String: Any] {
        [
            "baseUrl": baseURL,
            "languageCode": language,
            "name": ["simpleText": "English"],
            "isTranslatable": true,
            "vssId": vssID
        ]
    }

    private func timedtextURL(videoID: String, pathSuffix: String = "") -> String {
        "https://www.youtube.com/api/timedtext?v=\(videoID)\(pathSuffix)&lang=en&signature=sig"
    }

    private func validJSON3() -> String {
        """
        {
          "events": [
            {
              "tStartMs": 0,
              "dDurationMs": 2000,
              "segs": [
                {"utf8": "Hello world, this is a longer caption line.", "tOffsetMs": 0}
              ]
            },
            {
              "tStartMs": 2500,
              "dDurationMs": 2000,
              "segs": [
                {"utf8": "Another complete sentence for quality checks.", "tOffsetMs": 0}
              ]
            }
          ]
        }
        """
    }

    private func lowQualityJSON3() -> String {
        // Absolute CPS hard ceiling (>120) rejects the track after parse succeeds.
        let text = String(repeating: "word ", count: 40)
        return """
        {
          "events": [
            {"tStartMs": 0, "dDurationMs": 50, "segs": [{"utf8": "\(text)", "tOffsetMs": 0}]}
          ]
        }
        """
    }

    private func lowQualityVTT() -> String {
        // Same CPS hard ceiling as lowQualityJSON3, expressed as a VTT cue.
        let text = String(repeating: "word ", count: 40)
        return """
        WEBVTT

        00:00:00.000 --> 00:00:00.050
        \(text)
        """
    }

    private func validVTT() -> String {
        """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        Hello world, this is a longer caption line.

        00:00:02.500 --> 00:00:04.500
        Another complete sentence for quality checks.
        """
    }

    private func jsonString(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
}

private final class ManualYTCaptionClock: YTCaptionClock, @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class InMemoryYTCaptionRequestStateStore: YTCaptionRequestStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = YTCaptionPersistedRequestState()

    func load() -> YTCaptionPersistedRequestState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func save(_ state: YTCaptionPersistedRequestState) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }
}

private enum YTCaptionClientsTestSupport {
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let iosUserAgent = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
}

private final class CaptionTestURLProtocol: URLProtocol {
    enum Action {
        case response(status: Int, body: String, headers: [String: String], delayMS: Int = 0)
    }

    private static let lock = NSLock()
    private static var actions: [Action] = []
    private(set) static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        actions = []
        requests = []
    }

    static func enqueue(_ action: Action) {
        lock.lock()
        defer { lock.unlock() }
        actions.append(action)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let action: Action?
        Self.lock.lock()
        Self.requests.append(request)
        action = Self.actions.isEmpty ? nil : Self.actions.removeFirst()
        Self.lock.unlock()

        guard let action else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch action {
        case .response(let status, let body, let headers, let delayMS):
            if delayMS > 0 {
                Thread.sleep(forTimeInterval: Double(delayMS) / 1000)
            }
            let data = Data(body.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
