import Foundation
import XCTest

// WP11 scenario tests for the podcast cloud orchestration.
//
// The SPM test target (PodcastEnglishStudioTests) intentionally cannot link
// CloudSyncKit/DomainModels: both packages depend back on PodcastEnglishStudioCore,
// so adding them here would create a package cycle. These scenario tests are
// therefore compiled only when the cloud modules are visible (an app-hosted test
// bundle); under `swift test` a single skipped placeholder keeps the suite green.
// Gateway-level basics are covered by CloudSyncKit's CloudContentGatewayTests and
// the fixture contract by CloudPodcastContractTests.

#if canImport(CloudSyncKit) && canImport(DomainModels)

import SwiftData
@testable import CloudSyncKit
@testable import DomainModels

final class CloudPodcastOrchestrationTests: XCTestCase {

    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CloudContent")

    func fixture(_ name: String) -> Data {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("missing fixture \(name)")
            return Data()
        }
        return data
    }

    /// Running fixture body with custom flags and a short poll hint.
    func runningFixture(audioReady: Bool, subtitlesReady: Bool, hint: Int = 1) -> Data {
        var object = try! JSONSerialization.jsonObject(
            with: fixture("job-running-transcribing.json")
        ) as! [String: Any]
        object["audioReady"] = audioReady
        object["subtitlesReady"] = subtitlesReady
        object["retryAfterSeconds"] = hint
        return try! JSONSerialization.data(withJSONObject: object)
    }

    override func setUp() {
        super.setUp()
        CloudPodcastScriptedURLProtocol.reset()
    }

    override func tearDown() {
        CloudPodcastScriptedURLProtocol.reset()
        super.tearDown()
    }

    func makeClient() -> CloudContentJobClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudPodcastScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return try! CloudContentJobClient.makeDefault(
            baseURLString: "https://content.example.com/",
            tokenProvider: StaticContentTokenProvider(token: "test-token"),
            session: session
        )
    }

    @MainActor
    func makeStore() throws -> TestRemoteJobStore {
        try TestRemoteJobStore()
    }

    func sampleRequest() -> CloudContentJobCreateRequest {
        CloudContentJobCreateRequest(
            contentType: .podcastEpisode,
            contentKey: "podcast:aaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbb",
            source: CloudContentSource(
                platform: "rss",
                sourceId: "episode-guid-1",
                url: "https://media.example.com/ep-001.mp3",
                feedUrl: "https://example.com/feed.xml",
                title: "Episode 1"
            ),
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            translationQuality: .quality,
            clientArtifactSchemaVersion: 1
        )
    }

    // MARK: - Submit, simulated quit, restart reconcile resumes the same job

    func testSubmitThenRestartReconcileResumesSameJob() async throws {
        CloudPodcastScriptedURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (202, self.fixture("job-queued.json"), [:])
            }
            if CloudPodcastScriptedURLProtocol.requestCount <= 2 {
                return (200, self.runningFixture(audioReady: false, subtitlesReady: false), [:])
            }
            return (200, self.fixture("job-ready-podcast.json"), [:])
        }
        let store = try await makeStore()
        let submitCoordinator = CloudContentJobCoordinator(client: makeClient(), store: store)

        // Submit, then "quit": the coordinator is dropped, the record persists.
        let submitted = try await submitCoordinator.submit(sampleRequest())
        let persisted = try await store.snapshot(forStableKey: submitted.stableKey)
        XCTAssertEqual(persisted?.jobID, submitted.jobId)
        await submitCoordinator.setForeground(false)

        // "Restart": a fresh coordinator reconciles non-terminal records and
        // resumes polling the SAME job without a second POST.
        let postCountBeforeRestart = CloudPodcastScriptedURLProtocol.postCount
        let restartCoordinator = CloudContentJobCoordinator(client: makeClient(), store: store)
        await restartCoordinator.reconcileAll()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let snapshot = try await store.snapshot(forStableKey: submitted.stableKey),
               snapshot.isTerminal {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let final = try await store.snapshot(forStableKey: submitted.stableKey)
        XCTAssertEqual(final?.statusRaw, "ready")
        XCTAssertEqual(final?.jobID, submitted.jobId)
        XCTAssertEqual(
            CloudPodcastScriptedURLProtocol.postCount,
            postCountBeforeRestart,
            "reconcile must not resubmit the job"
        )
        await restartCoordinator.setForeground(false)
    }

    // MARK: - audioReady fires before subtitlesReady

    func testAudioReadyArrivesBeforeSubtitlesReady() async throws {
        CloudPodcastScriptedURLProtocol.handler = { _ in
            if CloudPodcastScriptedURLProtocol.requestCount == 1 {
                // Audio is ready but subtitles are still translating.
                return (200, self.runningFixture(audioReady: true, subtitlesReady: false), [:])
            }
            return (200, self.fixture("job-ready-podcast.json"), [:])
        }
        let store = try await makeStore()
        let coordinator = CloudContentJobCoordinator(client: makeClient(), store: store)
        let readyJob = try Self.decodeJob(fixture("job-ready-podcast.json"))

        await coordinator.track(stableKey: readyJob.stableKey, jobID: readyJob.jobId)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await store.upsertLog.last?.statusRaw == "ready" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await coordinator.setForeground(false)

        let log = await store.upsertLog
        XCTAssertGreaterThanOrEqual(log.count, 2)
        let intermediate = log[log.count - 2]
        XCTAssertEqual(intermediate.statusRaw, "running")
        XCTAssertTrue(intermediate.audioReady, "audioReady must fire while still running")
        XCTAssertFalse(intermediate.subtitlesReady, "subtitles land later")
        // The projection must keep the episode out of `completed` until ready.
        let intermediateJob = try Self.decodeJob(runningFixture(audioReady: true, subtitlesReady: false))
        XCTAssertEqual(CloudPodcastProjectionPolicy.project(intermediateJob).status, "running")
        XCTAssertEqual(log.last?.statusRaw, "ready")
        XCTAssertEqual(log.last?.subtitlesReady, true)
    }

    // MARK: - Cloud failure mapping and retry reusing the remote job

    func testFailedJobMapsErrorAndRetryReusesRemoteJob() async throws {
        CloudPodcastScriptedURLProtocol.handler = { request in
            if request.httpMethod == "POST" && request.url?.path.hasSuffix("/retry") == true {
                return (202, self.fixture("job-queued.json"), [:])
            }
            return (200, self.fixture("job-failed-retryable.json"), [:])
        }
        let client = makeClient()
        let store = try await makeStore()
        let coordinator = CloudContentJobCoordinator(client: client, store: store)
        let failedJob = try Self.decodeJob(fixture("job-failed-retryable.json"))

        await coordinator.track(stableKey: failedJob.stableKey, jobID: failedJob.jobId)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let snapshot = try await store.snapshot(forStableKey: failedJob.stableKey),
               snapshot.isTerminal {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await coordinator.setForeground(false)

        // Error mapping: projection carries the server code + message.
        let projection = CloudPodcastProjectionPolicy.project(failedJob)
        XCTAssertEqual(projection.status, "failed")
        XCTAssertEqual(projection.pipelineStep, "download") // fetching_audio maps to download
        XCTAssertEqual(
            projection.errorMessage,
            "SOURCE_RATE_LIMITED: Source platform returned HTTP 429 while fetching audio"
        )
        let record = try await store.record(forStableKey: failedJob.stableKey)
        XCTAssertEqual(record?.errorCode, "SOURCE_RATE_LIMITED")
        XCTAssertEqual(record?.errorRetryable, true)

        // Retry reuses the same remote job (server-side checkpoints intact).
        let retried = try await client.retryJob(jobID: failedJob.jobId)
        XCTAssertEqual(retried.jobId, failedJob.jobId)
        XCTAssertEqual(retried.status, .queued)
    }

    // MARK: - Interrupted artifact download leaves no partial state

    func testInterruptedArtifactFetchLeavesJobStateUntouched() async throws {
        CloudPodcastScriptedURLProtocol.handler = { request in
            if request.url?.path.contains("/v1/content-artifacts/") == true {
                throw URLError(.networkConnectionLost) // interrupted mid-download
            }
            return (200, self.fixture("job-ready-podcast.json"), [:])
        }
        let client = makeClient()
        let store = try await makeStore()
        let job = try Self.decodeJob(fixture("job-ready-podcast.json"))
        try await store.upsert(job)
        let before = try await store.snapshot(forStableKey: job.stableKey)

        do {
            _ = try await client.fetchArtifact(jobID: job.jobId, fileName: "segments.json")
            XCTFail("expected the interrupted download to throw")
        } catch let error as CloudContentError {
            guard case .transport = error else {
                return XCTFail("wrong error case \(error)")
            }
        }

        // Nothing was persisted: the cached record is byte-identical, so the next
        // reconcile re-drives the install against the intact previous cache.
        let after = try await store.snapshot(forStableKey: job.stableKey)
        XCTAssertEqual(before, after)
    }

    // MARK: - Helpers

    static func decodeJob(_ data: Data) throws -> CloudContentJobResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudContentJobResponse.self, from: data)
    }
}

// MARK: - Scripted URLProtocol (pattern from CloudSyncKit gateway tests)

final class CloudPodcastScriptedURLProtocol: URLProtocol {
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

    static var postCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requests.filter { $0.httpMethod == "POST" }.count
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = CloudPodcastScriptedURLProtocol.handler
        CloudPodcastScriptedURLProtocol.lock.lock()
        CloudPodcastScriptedURLProtocol._requests.append(request)
        CloudPodcastScriptedURLProtocol.lock.unlock()
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

// MARK: - SwiftData-backed store mirroring the app's RemoteContentJobStore

@MainActor
final class TestRemoteJobStore: CloudContentJobPersisting {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    /// Per-upsert state log for ordering assertions (audioReady/subtitlesReady).
    private(set) var upsertLog: [(statusRaw: String, audioReady: Bool, subtitlesReady: Bool)] = []

    init() throws {
        let schema = Schema([RemoteContentJobRecord.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    func upsert(_ job: CloudContentJobResponse) async throws {
        let key = job.stableKey
        let descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate { $0.stableKey == key }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.apply(job)
        } else {
            let record = RemoteContentJobRecord(
                stableKey: key,
                contentKind: job.contentType.rawValue,
                contentKey: job.contentKey,
                jobID: job.jobId,
                statusRaw: job.status.rawValue,
                targetLanguage: job.targetLanguage,
                translationQuality: job.translationQuality.rawValue,
                pipelineVersion: job.pipelineVersion,
                createdAt: job.createdAt
            )
            context.insert(record)
            record.apply(job)
        }
        try context.save()
        upsertLog.append((job.status.rawValue, job.audioReady, job.subtitlesReady))
    }

    func snapshot(forStableKey key: String) async throws -> RemoteContentJobSnapshot? {
        try record(forStableKey: key).map(Self.makeSnapshot)
    }

    func nonTerminalSnapshots() async throws -> [RemoteContentJobSnapshot] {
        try context.fetch(FetchDescriptor<RemoteContentJobRecord>())
            .filter { !["ready", "failed", "cancelled", "expired"].contains($0.statusRaw) }
            .map(Self.makeSnapshot)
    }

    func record(forStableKey key: String) throws -> RemoteContentJobRecord? {
        let descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate { $0.stableKey == key }
        )
        return try context.fetch(descriptor).first
    }

    func allSnapshots() -> [RemoteContentJobSnapshot] {
        ((try? context.fetch(FetchDescriptor<RemoteContentJobRecord>())) ?? [])
            .map(Self.makeSnapshot)
    }

    private static func makeSnapshot(_ record: RemoteContentJobRecord) -> RemoteContentJobSnapshot {
        RemoteContentJobSnapshot(
            stableKey: record.stableKey,
            jobID: record.jobID,
            statusRaw: record.statusRaw,
            isTerminal: ["ready", "failed", "cancelled", "expired"].contains(record.statusRaw)
        )
    }
}

#else

final class CloudPodcastOrchestrationTests: XCTestCase {
    func testScenarioSuiteRequiresCloudModules() throws {
        throw XCTSkip(
            "WP11 orchestration scenarios need CloudSyncKit/DomainModels, which the SPM "
                + "test target cannot link (package cycle); they run in an app-hosted "
                + "test bundle where those modules are visible."
        )
    }
}

#endif
