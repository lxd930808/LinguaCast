import Foundation
import DomainModels

// CloudContentGateway (WP10): the client-side gateway to the V10 content job
// API. Rules:
//  - all endpoints are /v1/content-* under the configured HTTPS base URL
//  - HTTP errors, transport errors and decode errors are distinct cases
//  - the Authorization header, signed URL query and content payloads are never logged
//  - the polling coordinator is actor-based and single-flight per job

// MARK: - Errors

public enum CloudContentError: Error, Equatable, Sendable {
    /// Transport-level failure (offline, timeout, cancelled).
    case transport(String)
    /// Non-2xx response with optional decoded server error envelope.
    case http(status: Int, server: CloudJobError?)
    /// Response body did not match the wire schema.
    case decoding(String)
    /// Local configuration problem (bad base URL, missing token).
    case configuration(String)

    public var isUnauthorized: Bool {
        if case .http(let status, _) = self { return status == 401 || status == 403 }
        return false
    }

    /// Suggested retry delay honoring the server Retry-After / retryAfterSeconds hint.
    public var retryAfterSeconds: Int? {
        if case .http(_, let server) = self { return server?.retryAfterSeconds }
        return nil
    }
}

// MARK: - Token provider

public protocol CloudContentTokenProviding: Sendable {
    func bearerToken() async throws -> String
}

public struct StaticContentTokenProvider: CloudContentTokenProviding {
    private let token: String
    public init(token: String) { self.token = token }
    public func bearerToken() async throws -> String { token }
}

public struct KeychainContentTokenProvider: CloudContentTokenProviding {
    private let store: ContentServiceTokenStoring
    public init(store: ContentServiceTokenStoring) { self.store = store }
    public func bearerToken() async throws -> String { try store.readContentServiceToken() }
}

// MARK: - Client

public struct CloudContentArtifactDownload: Equatable, Sendable {
    public var data: Data
    public var etag: String?
    public var notModified: Bool

    public init(data: Data, etag: String?, notModified: Bool) {
        self.data = data
        self.etag = etag
        self.notModified = notModified
    }
}

public final class CloudContentJobClient: Sendable {
    public let baseURL: URL
    private let tokenProvider: CloudContentTokenProviding
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        baseURL: URL,
        tokenProvider: CloudContentTokenProviding,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
        self.decoder = JSONDecoder()
        // The server emits ISO-8601 with fractional seconds (Date.toISOString());
        // fall back to plain internet date time for hand-written fixtures.
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid ISO-8601 date \(value)"
            )
        }
    }

    public static func makeDefault(
        baseURLString: String,
        tokenProvider: CloudContentTokenProviding,
        session: URLSession = .shared
    ) throws -> CloudContentJobClient {
        var value = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), url.scheme == "https" || url.scheme == "http" else {
            throw CloudContentError.configuration("invalid content service base URL")
        }
        return CloudContentJobClient(baseURL: url, tokenProvider: tokenProvider, session: session)
    }

    // MARK: Jobs

    @discardableResult
    public func createJob(
        _ request: CloudContentJobCreateRequest,
        idempotencyKey: String? = nil
    ) async throws -> CloudContentJobResponse {
        var urlRequest = try await authorizedRequest(path: "/v1/content-jobs", method: "POST")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey {
            urlRequest.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await perform(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CloudContentError.transport("missing HTTP response")
        }
        guard http.statusCode == 200 || http.statusCode == 202 else {
            throw decodeHTTPError(status: http.statusCode, data: data)
        }
        return try decodeJob(data)
    }

    public func getJob(jobID: String) async throws -> CloudContentJobResponse {
        let request = try await authorizedRequest(path: "/v1/content-jobs/\(jobID)", method: "GET")
        let (data, response) = try await perform(request)
        try expectOK(response, data: data)
        return try decodeJob(data)
    }

    public func lookupJob(
        contentType: CloudContentType,
        contentKey: String,
        targetLanguage: String,
        translationQuality: CloudTranslationQuality,
        sourceLanguage: String? = nil
    ) async throws -> CloudContentJobResponse? {
        var components = URLComponents()
        components.path = "/v1/content-jobs:lookup"
        components.queryItems = [
            URLQueryItem(name: "contentType", value: contentType.rawValue),
            URLQueryItem(name: "contentKey", value: contentKey),
            URLQueryItem(name: "targetLanguage", value: targetLanguage),
            URLQueryItem(name: "translationQuality", value: translationQuality.rawValue)
        ]
        if let sourceLanguage { components.queryItems?.append(URLQueryItem(name: "sourceLanguage", value: sourceLanguage)) }
        guard let path = components.string else {
            throw CloudContentError.configuration("failed to build lookup URL")
        }
        let request = try await authorizedRequest(absolutePath: path, method: "GET")
        let (data, response) = try await perform(request)
        try expectOK(response, data: data)
        do {
            return try decoder.decode(CloudContentJobLookupResponse.self, from: data).job
        } catch {
            throw CloudContentError.decoding("lookup: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func retryJob(jobID: String) async throws -> CloudContentJobResponse {
        let request = try await authorizedRequest(path: "/v1/content-jobs/\(jobID)/retry", method: "POST")
        let (data, response) = try await perform(request)
        try expectOK(response, data: data, alsoAllowed: [202])
        return try decodeJob(data)
    }

    /// Re-syncs a job believed to be failed before retrying it. The local record
    /// may be stale — another device or an operator may have already retried or
    /// completed the job — and a blind retry then dead-ends on
    /// 409 INVALID_JOB_STATE even when the content is ready. Returns the job's
    /// current server state (retrying only when it is still failed), or nil when
    /// the job no longer exists remotely and the caller should re-submit.
    @discardableResult
    public func retryJobAfterResync(jobID: String) async throws -> CloudContentJobResponse? {
        let current: CloudContentJobResponse
        do {
            current = try await getJob(jobID: jobID)
        } catch let error as CloudContentError {
            if case .http(let status, _) = error, status == 404 { return nil }
            throw error
        }
        guard current.status == .failed, current.error?.retryable == true else { return current }
        do {
            return try await retryJob(jobID: jobID)
        } catch let error as CloudContentError {
            // Lost the race between GET and retry (the job changed state
            // server-side): re-read once and continue with the server's actual
            // state instead of surfacing a dead-end 409.
            if case .http(let status, _) = error, status == 409 {
                return try await getJob(jobID: jobID)
            }
            throw error
        }
    }

    @discardableResult
    public func cancelJob(jobID: String, purgeArtifacts: Bool = false) async throws -> CloudContentJobResponse {
        let suffix = purgeArtifacts ? "?purgeArtifacts=true" : ""
        let request = try await authorizedRequest(
            absolutePath: "/v1/content-jobs/\(jobID)\(suffix)", method: "DELETE"
        )
        let (data, response) = try await perform(request)
        try expectOK(response, data: data)
        return try decodeJob(data)
    }

    // MARK: Artifacts

    public func fetchAudioPlaybackURL(jobID: String) async throws -> CloudAudioPlaybackURLResponse {
        let request = try await authorizedRequest(
            path: "/v1/content-jobs/\(jobID)/audio-playback-url", method: "POST"
        )
        let (data, response) = try await perform(request)
        try expectOK(response, data: data)
        do {
            return try decoder.decode(CloudAudioPlaybackURLResponse.self, from: data)
        } catch {
            throw CloudContentError.decoding("audio-playback-url: \(error.localizedDescription)")
        }
    }

    /// Issues a short-lived signed MP4 URL for a durable content-media asset.
    /// The URL is session-only: callers must not persist it.
    public func fetchVideoPlaybackURL(
        contentKey: String,
        preferredHeight: Int? = nil
    ) async throws -> CloudVideoPlaybackURLResponse {
        var request = try await authorizedRequest(
            path: "/v1/content-media/video-playback-url", method: "POST"
        )
        let body = CloudVideoPlaybackURLRequest(
            contentType: .video,
            contentKey: contentKey,
            preferredHeight: preferredHeight
        )
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform(request)
        try expectOK(response, data: data)
        do {
            return try decoder.decode(CloudVideoPlaybackURLResponse.self, from: data)
        } catch {
            throw CloudContentError.decoding("video-playback-url: \(error.localizedDescription)")
        }
    }

    public func videoSaveStatus(contentKey: String, retry: Bool = false) async throws -> CloudVideoSaveStatus {
        let path = retry ? "/v1/content-media/video-retry" : "/v1/content-media/video-status"
        var request = try await authorizedRequest(path: path, method: "POST")
        request.httpBody = try JSONEncoder().encode(CloudVideoPlaybackURLRequest(contentKey: contentKey))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform(request)
        try expectOK(response, data: data, alsoAllowed: [202])
        return try decoder.decode(CloudVideoSaveStatus.self, from: data)
    }

    /// Downloads an artifact file; pass a stored ETag to receive notModified on 304.
    public func fetchArtifact(
        jobID: String,
        fileName: String,
        ifNoneMatch etag: String? = nil
    ) async throws -> CloudContentArtifactDownload {
        var request = try await authorizedRequest(
            path: "/v1/content-artifacts/\(jobID)/\(fileName)", method: "GET"
        )
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudContentError.transport("missing HTTP response")
        }
        if http.statusCode == 304 {
            return CloudContentArtifactDownload(
                data: Data(), etag: http.value(forHTTPHeaderField: "ETag"), notModified: true
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw decodeHTTPError(status: http.statusCode, data: data)
        }
        return CloudContentArtifactDownload(
            data: data, etag: http.value(forHTTPHeaderField: "ETag"), notModified: false
        )
    }

    // MARK: Health

    public func readyCheck() async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/content-health/ready"))
        request.httpMethod = "GET"
        let (_, response) = try await perform(request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Internals

    private func authorizedRequest(path: String, method: String) async throws -> URLRequest {
        try await authorizedRequest(absolutePath: path, method: method)
    }

    private func authorizedRequest(absolutePath: String, method: String) async throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + absolutePath) else {
            throw CloudContentError.configuration("invalid path \(absolutePath)")
        }
        let token = try await tokenProvider.bearerToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw CloudContentError.transport(error.localizedDescription)
        } catch {
            throw CloudContentError.transport(error.localizedDescription)
        }
    }

    private func expectOK(
        _ response: URLResponse,
        data: Data,
        alsoAllowed: Set<Int> = []
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudContentError.transport("missing HTTP response")
        }
        guard http.statusCode == 200 || alsoAllowed.contains(http.statusCode) else {
            throw decodeHTTPError(status: http.statusCode, data: data)
        }
    }

    private func decodeHTTPError(status: Int, data: Data) -> CloudContentError {
        let envelope = try? decoder.decode(CloudErrorEnvelope.self, from: data)
        return .http(status: status, server: envelope?.error)
    }

    private func decodeJob(_ data: Data) throws -> CloudContentJobResponse {
        do {
            return try decoder.decode(CloudContentJobResponse.self, from: data)
        } catch {
            throw CloudContentError.decoding("job: \(error.localizedDescription)")
        }
    }
}

// MARK: - Persistence seam

/// Value snapshot of RemoteContentJobRecord for cross-actor use.
public struct RemoteContentJobSnapshot: Equatable, Sendable {
    public var stableKey: String
    public var jobID: String
    public var statusRaw: String
    public var isTerminal: Bool

    public init(stableKey: String, jobID: String, statusRaw: String, isTerminal: Bool) {
        self.stableKey = stableKey
        self.jobID = jobID
        self.statusRaw = statusRaw
        self.isTerminal = isTerminal
    }
}

/// Persistence seam for RemoteContentJobRecord; the app wires SwiftData in
/// WP11, tests use in-memory fakes. The job ID is persisted BEFORE any UI
/// refresh so a crash after submit cannot orphan the task.
public protocol CloudContentJobPersisting: Sendable {
    /// Persist (or update) the record for this job response; progress merges monotonically.
    func upsert(_ job: CloudContentJobResponse) async throws
    func snapshot(forStableKey key: String) async throws -> RemoteContentJobSnapshot?
    func nonTerminalSnapshots() async throws -> [RemoteContentJobSnapshot]
}

// MARK: - Coordinator

/**
 * Actor-based polling coordinator. Single-flight per stable key: any number of
 * callers may observe the same job and exactly one poll loop runs. Polling
 * honors server retryAfterSeconds. Call `setForeground(false)` on background to
 * stop high-frequency polling; `reconcileAll()` runs one immediate pass over
 * all non-terminal jobs (launch/foreground entry points).
 */
public actor CloudContentJobCoordinator {
    private let client: CloudContentJobClient
    private let store: CloudContentJobPersisting
    private var loops: [String: Task<Void, Never>] = [:]
    private var continuations: [String: [UUID: AsyncStream<CloudContentJobResponse>.Continuation]] = [:]
    private var foreground = true

    public init(client: CloudContentJobClient, store: CloudContentJobPersisting) {
        self.client = client
        self.store = store
    }

    /// Submit (or reuse) a job, persist its ID first, then start tracking.
    @discardableResult
    public func submit(
        _ request: CloudContentJobCreateRequest,
        idempotencyKey: String? = nil
    ) async throws -> CloudContentJobResponse {
        let job = try await client.createJob(request, idempotencyKey: idempotencyKey)
        try await store.upsert(job) // persist BEFORE observers see anything
        notify(job)
        track(stableKey: job.stableKey, jobID: job.jobId)
        return job
    }

    /// Resume only an exactly matching variant. Unknown transport state never creates a new job.
    public func resumeOrSubmit(
        _ request: CloudContentJobCreateRequest,
        savedJobID: String? = nil
    ) async throws -> CloudContentJobResponse {
        var current: CloudContentJobResponse?
        if let savedJobID {
            do { current = try await client.getJob(jobID: savedJobID) }
            catch let error as CloudContentError {
                if case .http(let status, _) = error, status == 404 { current = nil }
                else { throw error }
            }
        }
        if current == nil {
            current = try await client.lookupJob(contentType: request.contentType,
                contentKey: request.contentKey, targetLanguage: request.targetLanguage,
                translationQuality: request.translationQuality, sourceLanguage: request.sourceLanguage)
        }
        guard let found = current else { return try await submit(request) }
        guard found.contentType == request.contentType, found.contentKey == request.contentKey,
              found.sourceLanguage == request.sourceLanguage,
              found.targetLanguage == request.targetLanguage,
              found.translationQuality == request.translationQuality else {
            throw CloudContentError.configuration("Remote job does not match the requested variant")
        }
        let job: CloudContentJobResponse
        if found.status == .failed, found.error?.retryable == true {
            guard let resumed = try await client.retryJobAfterResync(jobID: found.jobId) else {
                return try await submit(request)
            }
            job = resumed
        } else { job = found }
        if job.status == .expired || job.status == .cancelled { return try await submit(request) }
        try await store.upsert(job)
        notify(job)
        if !job.status.isTerminal { track(stableKey: job.stableKey, jobID: job.jobId) }
        return job
    }

    /// Begin (idempotently) polling a job until it reaches a terminal state.
    public func track(stableKey: String, jobID: String) {
        guard foreground, loops[stableKey] == nil else { return }
        loops[stableKey] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let fetched = try await self.client.getJob(jobID: jobID)
                    try await self.store.upsert(fetched)
                    await self.notify(fetched)
                    if fetched.status.isTerminal { break }
                    let interval = CloudPollPolicy.nextIntervalSeconds(
                        serverHint: fetched.retryAfterSeconds
                    )
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch is CancellationError {
                    break
                } catch {
                    // Transport/HTTP errors back off; the loop survives.
                    let hint = (error as? CloudContentError)?.retryAfterSeconds
                    let backoff = CloudPollPolicy.nextIntervalSeconds(serverHint: hint ?? 15)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
            await self.clearLoop(stableKey: stableKey)
        }
    }

    /// One immediate reconciliation pass over all non-terminal jobs.
    public func reconcileAll() async {
        guard let records = try? await store.nonTerminalSnapshots() else { return }
        for record in records {
            if foreground {
                track(stableKey: record.stableKey, jobID: record.jobID)
            } else {
                if let job = try? await client.getJob(jobID: record.jobID) {
                    try? await store.upsert(job)
                    notify(job)
                }
            }
        }
    }

    public func setForeground(_ isForeground: Bool) async {
        let becameForeground = isForeground && !foreground
        foreground = isForeground
        if !isForeground {
            for (key, task) in loops {
                task.cancel()
                loops.removeValue(forKey: key)
            }
        } else if becameForeground {
            await reconcileAll()
        }
    }

    /// Observe job updates for a stable key.
    public func updates(for stableKey: String) -> AsyncStream<CloudContentJobResponse> {
        let id = UUID()
        return AsyncStream { continuation in
            var observers = continuations[stableKey] ?? [:]
            observers[id] = continuation
            continuations[stableKey] = observers
            continuation.onTermination = { _ in
                Task { await self.removeObserver(stableKey: stableKey, id: id) }
            }
        }
    }

    public var activeLoopCount: Int { loops.count }

    private func notify(_ job: CloudContentJobResponse) {
        for continuation in continuations[job.stableKey]?.values ?? [:].values {
            continuation.yield(job)
        }
    }

    private func clearLoop(stableKey: String) {
        loops.removeValue(forKey: stableKey)
    }

    private func removeObserver(stableKey: String, id: UUID) {
        continuations[stableKey]?.removeValue(forKey: id)
    }
}


public struct CloudVideoSaveStatus: Codable, Sendable {
    public var contentKey: String
    public var state: String
    public var mediaId: String?
    public var failureCode: String?
    public var attempts: Int
    public var retryAfterSeconds: Int?
}
