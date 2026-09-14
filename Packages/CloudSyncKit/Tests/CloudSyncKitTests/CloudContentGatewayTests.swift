import Foundation
import XCTest
@testable import CloudSyncKit
import DomainModels

// WP10 gateway tests. A scripted URLProtocol replays the WP0 golden fixtures
// so the client and the polling coordinator are verified without a server.

final class CloudContentGatewayTests: XCTestCase {

    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CloudSyncKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // CloudSyncKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/CloudContent")

    func fixture(_ name: String) -> Data {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("missing fixture \(name)")
            return Data()
        }
        return data
    }

    override func setUp() {
        super.setUp()
        ScriptedURLProtocol.reset()
    }

    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    func makeClient(token: String = "test-token") -> CloudContentJobClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return try! CloudContentJobClient.makeDefault(
            baseURLString: "https://content.example.com/",
            tokenProvider: StaticContentTokenProvider(token: token),
            session: session
        )
    }

    // MARK: - Client basics

    func testCreateJobAccepts202Queued() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/content-jobs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-1")
            return (202, self.fixture("job-queued.json"), [:])
        }
        let job = try await makeClient().createJob(sampleCreateRequest(), idempotencyKey: "idem-1")
        XCTAssertEqual(job.status, .queued)
        XCTAssertFalse(job.jobId.isEmpty)
    }

    func testCreateJobAccepts200Reuse() async throws {
        ScriptedURLProtocol.handler = { _ in (200, self.fixture("job-ready-podcast.json"), [:]) }
        let job = try await makeClient().createJob(sampleCreateRequest())
        XCTAssertEqual(job.status, .ready)
        // The golden fixture omits `reused`; the client must tolerate its absence.
        XCTAssertNil(job.reused)
    }

    func testLookupHitAndMiss() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix(":lookup") ?? false)
            if request.url?.query?.contains("missing") == true {
                return (200, self.fixture("lookup-response-miss.json"), [:])
            }
            return (200, self.fixture("lookup-response-hit.json"), [:])
        }
        let client = makeClient()
        let hit = try await client.lookupJob(
            contentType: .podcastEpisode, contentKey: "podcast:abc:def",
            targetLanguage: "zh-Hans", translationQuality: .quality
        )
        XCTAssertNotNil(hit)
        let miss = try await client.lookupJob(
            contentType: .podcastEpisode, contentKey: "podcast:missing:def",
            targetLanguage: "zh-Hans", translationQuality: .quality
        )
        XCTAssertNil(miss)
    }

    func testGetJobDecodesRunningFixture() async throws {
        ScriptedURLProtocol.handler = { _ in (200, self.fixture("job-running-transcribing.json"), [:]) }
        let job = try await makeClient().getJob(jobID: "cj_test")
        XCTAssertEqual(job.status, .running)
        XCTAssertEqual(job.stage, .transcribing)
    }

    // MARK: - Retry after re-sync (stale failed state)

    /// Production incident 2026-08-29: the app cached a job's failed state, the
    /// job was retried server-side and became ready, and the app's blind retry
    /// then dead-ended on 409 INVALID_JOB_STATE. The client must re-sync first.
    func testRetryAfterResyncSkipsRetryWhenJobAlreadyReady() async throws {
        let log = RequestLog()
        ScriptedURLProtocol.handler = { request in
            log.append(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/content-jobs/cj_stale")
            return (200, self.fixture("job-ready-podcast.json"), [:])
        }
        let job = try await makeClient().retryJobAfterResync(jobID: "cj_stale")
        XCTAssertEqual(job?.status, .ready)
        XCTAssertEqual(log.retryCount, 0, "a ready job must not be retried")
    }

    func testRetryAfterResyncRetriesWhenStillFailed() async throws {
        let log = RequestLog()
        ScriptedURLProtocol.handler = { request in
            log.append(request)
            if request.url?.path.hasSuffix("/retry") == true {
                XCTAssertEqual(request.httpMethod, "POST")
                return (202, self.fixture("job-queued.json"), [:])
            }
            return (200, self.fixture("job-failed-retryable.json"), [:])
        }
        let job = try await makeClient().retryJobAfterResync(jobID: "cj_failed")
        XCTAssertEqual(job?.status, .queued)
        XCTAssertEqual(log.retryCount, 1)
    }

    func testRetryAfterResyncReturnsNilForVanishedJob() async throws {
        let log = RequestLog()
        ScriptedURLProtocol.handler = { request in
            log.append(request)
            return (404, Data("{}".utf8), [:])
        }
        let job = try await makeClient().retryJobAfterResync(jobID: "cj_gone")
        XCTAssertNil(job, "a vanished job signals the caller to re-submit")
        XCTAssertEqual(log.retryCount, 0)
    }

    func testRetryAfterResyncRecoversFromRaceConflict() async throws {
        let log = RequestLog()
        let conflict = Data("""
            {"error":{"code":"INVALID_JOB_STATE",\
            "message":"job cj_racy is not in a retryable failed state",\
            "retryable":false,"traceId":"tr_test"}}
            """.utf8)
        ScriptedURLProtocol.handler = { request in
            log.append(request)
            if request.url?.path.hasSuffix("/retry") == true {
                // The job flipped to ready between our GET and our retry.
                return (409, conflict, [:])
            }
            // First GET says failed, the re-read after the 409 says ready.
            return log.count == 1
                ? (200, self.fixture("job-failed-retryable.json"), [:])
                : (200, self.fixture("job-ready-podcast.json"), [:])
        }
        let job = try await makeClient().retryJobAfterResync(jobID: "cj_racy")
        XCTAssertEqual(job?.status, .ready, "a lost race resolves to the live state, not a dead-end 409")
        XCTAssertEqual(log.retryCount, 1)
        XCTAssertEqual(log.count, 3)
    }

    // MARK: - Error separation

    func testUnauthorizedSurfacesHTTPStatus() async throws {
        ScriptedURLProtocol.handler = { _ in (401, Data("{}".utf8), [:]) }
        do {
            _ = try await makeClient().getJob(jobID: "cj_x")
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            XCTAssertTrue(error.isUnauthorized)
            guard case .http(let status, _) = error else { return XCTFail("wrong case \(error)") }
            XCTAssertEqual(status, 401)
        }
    }

    func testServerErrorEnvelopeIsDecoded() async throws {
        ScriptedURLProtocol.handler = { _ in
            (422, self.fixture("error-envelope-invalid-request.json"), [:])
        }
        do {
            _ = try await makeClient().createJob(sampleCreateRequest())
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            guard case .http(let status, let server) = error else {
                return XCTFail("wrong case \(error)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertEqual(server?.code, "INVALID_REQUEST")
            XCTAssertEqual(server?.retryable, false)
        }
    }

    func testTransportFailureIsDistinct() async throws {
        ScriptedURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await makeClient().getJob(jobID: "cj_x")
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            guard case .transport = error else { return XCTFail("wrong case \(error)") }
        }
    }

    func testMalformedBodyIsDecodingError() async throws {
        ScriptedURLProtocol.handler = { _ in (200, Data("not json".utf8), [:]) }
        do {
            _ = try await makeClient().getJob(jobID: "cj_x")
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            guard case .decoding = error else { return XCTFail("wrong case \(error)") }
        }
    }

    // MARK: - Artifacts

    func testArtifactETagRoundTrip() async throws {
        let body = Data("segment data".utf8)
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/content-artifacts/cj_test/audio.mp3")
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"etag-1\"" {
                return (304, Data(), ["ETag": "\"etag-1\""])
            }
            return (200, body, ["ETag": "\"etag-1\""])
        }
        let client = makeClient()
        let first = try await client.fetchArtifact(jobID: "cj_test", fileName: "audio.mp3")
        XCTAssertFalse(first.notModified)
        XCTAssertEqual(first.data, body)
        XCTAssertEqual(first.etag, "\"etag-1\"")
        let second = try await client.fetchArtifact(
            jobID: "cj_test", fileName: "audio.mp3", ifNoneMatch: first.etag
        )
        XCTAssertTrue(second.notModified)
        XCTAssertTrue(second.data.isEmpty)
    }

    func testAudioPlaybackURLDecodes() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/audio-playback-url") ?? false)
            return (200, self.fixture("audio-playback-url-response.json"), [:])
        }
        let response = try await makeClient().fetchAudioPlaybackURL(jobID: "cj_test")
        XCTAssertEqual(response.acceptRanges, "bytes")
        XCTAssertFalse(response.sha256.isEmpty)
    }

    func testVideoPlaybackURLPostsAuthorizedBody() async throws {
        ScriptedURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/content-media/video-playback-url")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(CloudVideoPlaybackURLRequest.self, from: body) {
                XCTAssertEqual(decoded.contentType, .video)
                XCTAssertEqual(decoded.contentKey, "video:youtube:dQw4w9WgXcQ")
                XCTAssertEqual(decoded.preferredHeight, 720)
            }
            return (200, self.fixture("video-playback-url-response.json"), [:])
        }
        let response = try await makeClient().fetchVideoPlaybackURL(
            contentKey: "video:youtube:dQw4w9WgXcQ",
            preferredHeight: 720
        )
        XCTAssertEqual(response.mediaId, "cm_01JFXB2C4E6G8J0M2P4R")
        XCTAssertEqual(response.acceptRanges, "bytes")
        XCTAssertEqual(response.height, 720)
    }

    func testVideoPlaybackURLUnknownFieldsAreIgnored() async throws {
        ScriptedURLProtocol.handler = { _ in
            (200, self.fixture("video-playback-url-unknown-field.json"), [:])
        }
        let response = try await makeClient().fetchVideoPlaybackURL(
            contentKey: "video:youtube:dQw4w9WgXcQ"
        )
        XCTAssertEqual(response.mediaVersion, "mp4-720-avc1-aac")
    }

    func testVideoPlaybackURLMediaNotFoundIsHTTP404() async throws {
        ScriptedURLProtocol.handler = { _ in
            (404, self.fixture("error-envelope-media-not-found.json"), [:])
        }
        do {
            _ = try await makeClient().fetchVideoPlaybackURL(contentKey: "video:youtube:missing")
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            guard case .http(let status, let server) = error else {
                return XCTFail("wrong case \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(server?.code, "MEDIA_NOT_FOUND")
        }
    }

    func testVideoPlaybackURLNotReadyIsHTTP409() async throws {
        ScriptedURLProtocol.handler = { _ in
            (409, self.fixture("error-envelope-media-not-ready.json"), [:])
        }
        do {
            _ = try await makeClient().fetchVideoPlaybackURL(contentKey: "video:youtube:dQw4w9WgXcQ")
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            guard case .http(let status, let server) = error else {
                return XCTFail("wrong case \(error)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(server?.code, "MEDIA_NOT_READY")
            XCTAssertEqual(error.retryAfterSeconds, 8)
        }
    }

    func testVideoPlaybackURLIntegrityFailedIsHTTP409() async throws {
        ScriptedURLProtocol.handler = { _ in
            (409, self.fixture("error-envelope-media-integrity-failed.json"), [:])
        }
        do {
            _ = try await makeClient().fetchVideoPlaybackURL(contentKey: "video:youtube:dQw4w9WgXcQ")
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            guard case .http(let status, let server) = error else {
                return XCTFail("wrong case \(error)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(server?.code, "MEDIA_INTEGRITY_FAILED")
        }
    }

    func testVideoPlaybackURLSchemaTooNewIsDecodingError() async throws {
        var json = try JSONSerialization.jsonObject(
            with: fixture("video-playback-url-response.json")
        ) as? [String: Any]
        json?["schemaVersion"] = 2
        let body = try JSONSerialization.data(withJSONObject: json as Any)
        ScriptedURLProtocol.handler = { _ in (200, body, [:]) }
        do {
            _ = try await makeClient().fetchVideoPlaybackURL(contentKey: "video:youtube:dQw4w9WgXcQ")
            XCTFail("expected throw")
        } catch let error as CloudContentError {
            guard case .decoding = error else { return XCTFail("wrong case \(error)") }
        }
    }

    // MARK: - Token store

    func testTokenStoreRoundTrip() throws {
        let store = InMemoryContentServiceTokenStore()
        XCTAssertEqual(try store.readContentServiceToken(), "")
        try store.writeContentServiceToken("secret-token")
        XCTAssertEqual(try store.readContentServiceToken(), "secret-token")
    }

    // MARK: - Coordinator

    func testCoordinatorSingleFlightPollsUntilTerminal() async throws {
        // First GET returns running with a 1s hint, second returns ready.
        let running = runningFixture(hint: 1)
        let ready = fixture("job-ready-podcast.json")
        let readyJob = try CloudContentGatewayTests.decode(CloudContentJobResponse.self, from: ready)
        ScriptedURLProtocol.handler = { _ in
            if ScriptedURLProtocol.requestCount == 1 {
                return (200, running, [:])
            }
            return (200, ready, [:])
        }
        let store = FakeJobStore()
        let coordinator = CloudContentJobCoordinator(client: makeClient(), store: store)

        await coordinator.track(stableKey: readyJob.stableKey, jobID: readyJob.jobId)
        await coordinator.track(stableKey: readyJob.stableKey, jobID: readyJob.jobId) // single-flight
        let initialLoops = await coordinator.activeLoopCount
        XCTAssertEqual(initialLoops, 1)

        // Wait for the loop to reach the terminal state.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let snapshots = await store.upserted
            if snapshots.last?.status == .ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let upserts = await store.upserted
        XCTAssertEqual(upserts.last?.status, .ready)
        let loopsAfterReady = await coordinator.activeLoopCount
        XCTAssertEqual(loopsAfterReady, 0)
        // Exactly one GET per poll cycle: running + ready.
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 2)
    }

    func testCoordinatorSurvivesTransportErrors() async throws {
        let ready = fixture("job-ready-podcast.json")
        ScriptedURLProtocol.handler = { _ in
            if ScriptedURLProtocol.requestCount == 1 {
                throw URLError(.timedOut)
            }
            return (200, ready, [:])
        }
        // Error backoff uses hint=15s; keep the test fast by only checking that
        // the loop is still alive after the first failure.
        let store = FakeJobStore()
        let coordinator = CloudContentJobCoordinator(client: makeClient(), store: store)
        await coordinator.track(stableKey: "k", jobID: "cj_test")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if ScriptedURLProtocol.requestCount >= 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
        let loopsAfterError = await coordinator.activeLoopCount
        XCTAssertEqual(loopsAfterError, 1)
        await coordinator.setForeground(false) // cancels the backoff sleep
        let loopsAfterBackground = await coordinator.activeLoopCount
        XCTAssertEqual(loopsAfterBackground, 0)
    }

    func testSubmitPersistsBeforeTracking() async throws {
        ScriptedURLProtocol.handler = { _ in (202, self.fixture("job-queued.json"), [:]) }
        let store = FakeJobStore()
        let coordinator = CloudContentJobCoordinator(client: makeClient(), store: store)
        let job = try await coordinator.submit(sampleCreateRequest())
        let upserts = await store.upserted
        XCTAssertEqual(upserts.first?.jobId, job.jobId)
        await coordinator.setForeground(false)
    }

    func testResumeUsesSameJobAndNeverCreatesWhenFailedOrReady() async throws {
        let fixtureData = fixture("job-failed-retryable.json")
        let object = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        var request = sampleCreateRequest()
        request.contentKey = object["contentKey"] as! String
        let jobID = object["jobId"] as! String
        let log = RequestLog()
        ScriptedURLProtocol.handler = { request in
            log.append(request)
            XCTAssertNotEqual(request.url?.path, "/v1/content-jobs")
            if request.url!.path.hasSuffix("/retry") { return (202,self.fixture("job-ready-podcast.json"),[:]) }
            return (200,fixtureData,[:])
        }
        let store = FakeJobStore()
        let coordinator = CloudContentJobCoordinator(client: makeClient(), store: store)
        let result = try await coordinator.resumeOrSubmit(request, savedJobID: jobID)
        XCTAssertEqual(result.jobId,jobID)
        XCTAssertEqual(result.status,.ready)
        XCTAssertEqual(log.retryCount,1)
        let saved = await store.upserted
        XCTAssertEqual(saved.last?.jobId,jobID)
    }

    func testResumeDoesNotCreateOnTransportOrUnauthorizedOrNonretryableFailure() async throws {
        let failed = try JSONSerialization.jsonObject(with: fixture("job-failed-retryable.json")) as! [String:Any]
        var request = sampleCreateRequest()
        request.contentKey = failed["contentKey"] as! String
        let coordinator = CloudContentJobCoordinator(client: makeClient(), store: FakeJobStore())
        for code in [401,503] {
            ScriptedURLProtocol.handler = { r in
                XCTAssertEqual(r.httpMethod,"GET")
                return (code,Data(),[:])
            }
            do { _ = try await coordinator.resumeOrSubmit(request,savedJobID:"old");XCTFail("must fail") }
            catch {}
        }
        var nonretryable = failed
        var error = nonretryable["error"] as! [String:Any];error["retryable"] = false;nonretryable["error"] = error
        let data = try JSONSerialization.data(withJSONObject:nonretryable)
        ScriptedURLProtocol.handler = { r in XCTAssertEqual(r.httpMethod,"GET");return (200,data,[:]) }
        let result = try await coordinator.resumeOrSubmit(request,savedJobID:"old")
        XCTAssertEqual(result.status,.failed)
    }

    // MARK: - Helpers

    private func sampleCreateRequest() -> CloudContentJobCreateRequest {
        CloudContentJobCreateRequest(
            contentType: .podcastEpisode,
            contentKey: "podcast:aaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbb",
            source: CloudContentSource(
                platform: "podcast",
                sourceId: "bbbbbbbbbbbbbbbb",
                url: "https://example.com/feed.xml",
                feedUrl: "https://example.com/feed.xml",
                title: "Sample Episode"
            ),
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            translationQuality: .quality,
            clientArtifactSchemaVersion: 1
        )
    }

    /// Running fixture body with a short poll hint so tests stay fast.
    private func runningFixture(hint: Int) -> Data {
        var object = try! JSONSerialization.jsonObject(
            with: fixture("job-running-transcribing.json")
        ) as! [String: Any]
        object["retryAfterSeconds"] = hint
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

// MARK: - Scripted URLProtocol

/// Lock-protected record of requests seen by a test's handler closure, for
/// ordering/count assertions (ScriptedURLProtocol's own log is private).
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(method: String, path: String)] = []

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var retryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.path.hasSuffix("/retry") }.count
    }

    func append(_ request: URLRequest) {
        lock.lock()
        entries.append((request.httpMethod ?? "", request.url?.path ?? ""))
        lock.unlock()
    }
}

final class ScriptedURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (status: Int, body: Data, headers: [String: String])

    private static let lock = NSLock()
    private static var _handler: Handler?
    private static var _requests: [URLRequest] = []

    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _requests.count
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = ScriptedURLProtocol.handler
        ScriptedURLProtocol.lock.lock()
        ScriptedURLProtocol._requests.append(request)
        ScriptedURLProtocol.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: stub.status,
                httpVersion: "HTTP/1.1", headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !stub.body.isEmpty {
                client?.urlProtocol(self, didLoad: stub.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Fake persistence

actor FakeJobStore: CloudContentJobPersisting {
    private(set) var upserted: [CloudContentJobResponse] = []

    func upsert(_ job: CloudContentJobResponse) async throws {
        if let index = upserted.firstIndex(where: { $0.stableKey == job.stableKey }) {
            upserted[index] = job
        } else {
            upserted.append(job)
        }
    }

    func snapshot(forStableKey key: String) async throws -> RemoteContentJobSnapshot? {
        upserted.first { $0.stableKey == key }.map {
            RemoteContentJobSnapshot(
                stableKey: $0.stableKey, jobID: $0.jobId,
                statusRaw: $0.status.rawValue, isTerminal: $0.status.isTerminal
            )
        }
    }

    func nonTerminalSnapshots() async throws -> [RemoteContentJobSnapshot] {
        upserted.filter { !$0.status.isTerminal }.map {
            RemoteContentJobSnapshot(
                stableKey: $0.stableKey, jobID: $0.jobId,
                statusRaw: $0.status.rawValue, isTerminal: false
            )
        }
    }
}
