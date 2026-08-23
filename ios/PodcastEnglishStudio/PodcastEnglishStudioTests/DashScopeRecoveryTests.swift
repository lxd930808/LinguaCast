import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

final class DashScopeRecoveryTests: XCTestCase {
    override func tearDown() {
        ASRTestURLProtocol.reset()
        super.tearDown()
    }

    func testCheckpointResumesMostAdvancedDurableStageForMatchingAudio() throws {
        let audioIdentity = DashScopeAudioIdentity(
            byteCount: 92_000_000,
            modificationDate: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            DashScopeTranscriptionCheckpoint(
                audioIdentity: audioIdentity,
                remoteAudioURL: "oss://uploaded/source.mp3"
            ).resumeAction(for: audioIdentity, hasDownloadedResult: false),
            .submit(remoteAudioURL: "oss://uploaded/source.mp3")
        )
        XCTAssertEqual(
            DashScopeTranscriptionCheckpoint(
                audioIdentity: audioIdentity,
                remoteAudioURL: "oss://uploaded/source.mp3",
                stage: .submitting
            ).resumeAction(for: audioIdentity, hasDownloadedResult: false),
            .submissionOutcomeUnknown
        )
        XCTAssertEqual(
            DashScopeTranscriptionCheckpoint(
                audioIdentity: audioIdentity,
                remoteAudioURL: "oss://uploaded/source.mp3",
                taskID: "task-123"
            ).resumeAction(for: audioIdentity, hasDownloadedResult: false),
            .poll(taskID: "task-123")
        )
        XCTAssertEqual(
            DashScopeTranscriptionCheckpoint(
                audioIdentity: audioIdentity,
                remoteAudioURL: "oss://uploaded/source.mp3",
                taskID: "task-123",
                transcriptURL: "https://example.com/result.json"
            ).resumeAction(for: audioIdentity, hasDownloadedResult: false),
            .downloadResult(
                url: try XCTUnwrap(URL(string: "https://example.com/result.json")),
                taskID: "task-123"
            )
        )
        XCTAssertEqual(
            DashScopeTranscriptionCheckpoint(
                audioIdentity: audioIdentity,
                taskID: "task-123"
            ).resumeAction(for: audioIdentity, hasDownloadedResult: true),
            .parseDownloadedResult
        )
    }

    func testCheckpointNeverReusesRemoteWorkForDifferentAudio() {
        let checkpoint = DashScopeTranscriptionCheckpoint(
            audioIdentity: DashScopeAudioIdentity(
                byteCount: 92_000_000,
                modificationDate: Date(timeIntervalSince1970: 100)
            ),
            remoteAudioURL: "oss://uploaded/source.mp3",
            taskID: "task-123"
        )
        let replacementAudio = DashScopeAudioIdentity(
            byteCount: 92_000_001,
            modificationDate: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(
            checkpoint.resumeAction(for: replacementAudio, hasDownloadedResult: false),
            .startUpload
        )
    }

    func testCheckpointStoreRoundTripsAndRemovesDurableState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashScopeCheckpointTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashScopeCheckpointStore(
            fileURL: directory.appendingPathComponent("asr_checkpoint.json")
        )
        let checkpoint = DashScopeTranscriptionCheckpoint(
            audioIdentity: DashScopeAudioIdentity(
                byteCount: 92_000_000,
                modificationDate: Date(timeIntervalSince1970: 100)
            ),
            remoteAudioURL: "oss://uploaded/source.mp3",
            taskID: "task-123",
            taskStatus: "RUNNING",
            stage: .polling,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        try store.save(checkpoint)

        XCTAssertEqual(try store.load(), checkpoint)
        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testCheckpointRoundTripStillMatchesFileModificationTimeWithSubseconds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashScopeCheckpointPrecision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashScopeCheckpointStore(
            fileURL: directory.appendingPathComponent("asr_checkpoint.json")
        )
        let audioIdentity = DashScopeAudioIdentity(
            byteCount: 92_000_000,
            modificationDate: Date(timeIntervalSince1970: 100.987)
        )
        try store.save(
            DashScopeTranscriptionCheckpoint(
                audioIdentity: audioIdentity,
                taskID: "task-123"
            )
        )

        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(
            restored.resumeAction(for: audioIdentity, hasDownloadedResult: false),
            .poll(taskID: "task-123")
        )
    }

    func testAudioIdentityDistinguishesFilesModifiedWithinTheSameSecond() {
        let first = DashScopeAudioIdentity(
            byteCount: 90 * 1_024 * 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_800_000_000.1)
        )
        let second = DashScopeAudioIdentity(
            byteCount: 90 * 1_024 * 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_800_000_000.9)
        )

        XCTAssertNotEqual(first, second)
    }

    func testBoundedHTTPClientCancelsARequestThatNeverCompletes() async throws {
        ASRTestURLProtocol.enqueue(.hang)
        let client = makeHTTPClient()
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/hang")))

        do {
            _ = try await client.data(
                for: request,
                policy: BoundedHTTPRetryPolicy(
                    maxAttempts: 1,
                    attemptTimeout: 0.05,
                    retryDelays: []
                )
            )
            XCTFail("Expected a bounded timeout")
        } catch let error as BoundedHTTPError {
            XCTAssertEqual(error, .timedOut)
        }

    }

    func testBoundedHTTPClientRetriesTimeoutThenReturnsSuccessfulResponse() async throws {
        ASRTestURLProtocol.enqueue(.hang)
        ASRTestURLProtocol.enqueue(.response(statusCode: 200, data: Data("ok".utf8)))
        let client = makeHTTPClient()
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/retry")))

        let response = try await client.data(
            for: request,
            policy: BoundedHTTPRetryPolicy(
                maxAttempts: 2,
                attemptTimeout: 0.05,
                retryDelays: [0]
            )
        )

        XCTAssertEqual(response.data, Data("ok".utf8))
        XCTAssertEqual(response.response.statusCode, 200)
        XCTAssertEqual(ASRTestURLProtocol.requestCount, 2)
    }

    func testBoundedHTTPClientPropagatesTaskCancellationWithoutWaitingForTimeout() async throws {
        ASRTestURLProtocol.enqueue(.hang)
        let client = makeHTTPClient()
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/cancel")))
        let task = Task {
            try await client.data(
                for: request,
                policy: BoundedHTTPRetryPolicy(
                    maxAttempts: 3,
                    attemptTimeout: 30,
                    retryDelays: [1, 1]
                )
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(ASRTestURLProtocol.requestCount, 1)
    }

    func testBoundedHTTPClientHandlesCancellationBeforeRequestStartup() async throws {
        ASRTestURLProtocol.enqueue(.hang)
        let client = makeHTTPClient()
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/cancel-immediately")))
        let task = Task {
            try await client.data(
                for: request,
                policy: BoundedHTTPRetryPolicy(
                    maxAttempts: 1,
                    attemptTimeout: 30,
                    retryDelays: []
                )
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testBoundedHTTPClientRejectsHTTPFailureWithoutRetryingClientErrors() async throws {
        ASRTestURLProtocol.enqueue(.response(statusCode: 403, data: Data("expired".utf8)))
        let client = makeHTTPClient()
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/forbidden")))

        do {
            _ = try await client.data(
                for: request,
                policy: BoundedHTTPRetryPolicy(
                    maxAttempts: 3,
                    attemptTimeout: 1,
                    retryDelays: [0, 0]
                )
            )
            XCTFail("Expected HTTP failure")
        } catch let error as BoundedHTTPError {
            XCTAssertEqual(error, .httpStatus(403))
        }

        XCTAssertEqual(ASRTestURLProtocol.requestCount, 1)
    }

    private func makeHTTPClient() -> BoundedHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ASRTestURLProtocol.self]
        return BoundedHTTPClient(session: URLSession(configuration: configuration))
    }
}

private final class ASRTestURLProtocol: URLProtocol {
    enum Action {
        case hang
        case response(statusCode: Int, data: Data)
    }

    private static let lock = NSLock()
    private static var actions: [Action] = []
    private(set) static var requestCount = 0

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        actions = []
        requestCount = 0
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
        Self.requestCount += 1
        action = Self.actions.isEmpty ? nil : Self.actions.removeFirst()
        Self.lock.unlock()

        switch action {
        case .hang:
            break
        case .response(let statusCode, let data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }

    override func stopLoading() {}
}
