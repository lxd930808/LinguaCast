import Foundation

public struct DashScopeAudioIdentity: Codable, Equatable, Sendable {
    public var byteCount: Int64
    public var modificationDate: Date
    public var modificationTimeNanoseconds: Int64

    public init(byteCount: Int64, modificationDate: Date) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        let nanoseconds = modificationDate.timeIntervalSince1970 * 1_000_000_000
        if nanoseconds >= Double(Int64.max) {
            self.modificationTimeNanoseconds = .max
        } else if nanoseconds <= Double(Int64.min) {
            self.modificationTimeNanoseconds = .min
        } else {
            self.modificationTimeNanoseconds = Int64(nanoseconds)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.byteCount == rhs.byteCount
            && lhs.modificationTimeNanoseconds == rhs.modificationTimeNanoseconds
    }

    public static func read(from fileURL: URL) throws -> Self {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Self(
            byteCount: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate ?? .distantPast
        )
    }
}

public enum DashScopeTranscriptionStage: String, Codable, Equatable, Sendable {
    case preparingUpload
    case uploadingAudio
    case submitting
    case polling
    case downloadingResult
    case parsingResult
}

public enum DashScopeTranscriptionResumeAction: Equatable, Sendable {
    case startUpload
    case submit(remoteAudioURL: String)
    case submissionOutcomeUnknown
    case poll(taskID: String)
    case downloadResult(url: URL, taskID: String?)
    case parseDownloadedResult
}

public struct DashScopeTranscriptionCheckpoint: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var audioIdentity: DashScopeAudioIdentity
    public var remoteAudioURL: String?
    public var taskID: String?
    public var transcriptURL: String?
    public var taskStatus: String?
    public var stage: DashScopeTranscriptionStage
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        audioIdentity: DashScopeAudioIdentity,
        remoteAudioURL: String? = nil,
        taskID: String? = nil,
        transcriptURL: String? = nil,
        taskStatus: String? = nil,
        stage: DashScopeTranscriptionStage = .preparingUpload,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.audioIdentity = audioIdentity
        self.remoteAudioURL = remoteAudioURL
        self.taskID = taskID
        self.transcriptURL = transcriptURL
        self.taskStatus = taskStatus
        self.stage = stage
        self.updatedAt = updatedAt
    }

    public func resumeAction(
        for currentAudioIdentity: DashScopeAudioIdentity,
        hasDownloadedResult: Bool
    ) -> DashScopeTranscriptionResumeAction {
        guard schemaVersion == 1, audioIdentity == currentAudioIdentity else {
            return .startUpload
        }
        if hasDownloadedResult {
            return .parseDownloadedResult
        }
        if let transcriptURL,
           let url = URL(string: transcriptURL) {
            return .downloadResult(url: url, taskID: taskID)
        }
        if let taskID, !taskID.isEmpty {
            return .poll(taskID: taskID)
        }
        if let remoteAudioURL, !remoteAudioURL.isEmpty {
            if stage == .submitting {
                return .submissionOutcomeUnknown
            }
            return .submit(remoteAudioURL: remoteAudioURL)
        }
        return .startUpload
    }
}

public final class DashScopeCheckpointStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> DashScopeTranscriptionCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DashScopeTranscriptionCheckpoint.self, from: data)
    }

    public func save(_ checkpoint: DashScopeTranscriptionCheckpoint) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(checkpoint)

        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

public struct BoundedHTTPRetryPolicy: Equatable, Sendable {
    public var maxAttempts: Int
    public var attemptTimeout: TimeInterval
    public var retryDelays: [TimeInterval]

    public init(
        maxAttempts: Int,
        attemptTimeout: TimeInterval,
        retryDelays: [TimeInterval]
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.attemptTimeout = max(0.001, attemptTimeout)
        self.retryDelays = retryDelays
    }
}

public struct BoundedHTTPResponse {
    public var data: Data
    public var response: HTTPURLResponse

    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }
}

public enum BoundedHTTPError: LocalizedError, Equatable {
    case timedOut
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The network request timed out."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpStatus(let status):
            return "The server returned HTTP \(status)."
        }
    }
}

public final class BoundedHTTPClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(
        for request: URLRequest,
        policy: BoundedHTTPRetryPolicy
    ) async throws -> BoundedHTTPResponse {
        var attempt = 1
        while true {
            do {
                let response = try await performAttempt(
                    request,
                    timeout: policy.attemptTimeout
                )
                guard (200..<300).contains(response.response.statusCode) else {
                    throw BoundedHTTPError.httpStatus(response.response.statusCode)
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < policy.maxAttempts, Self.isRetryable(error) else {
                    throw error
                }
                let delayIndex = attempt - 1
                let delay = delayIndex < policy.retryDelays.count
                    ? policy.retryDelays[delayIndex]
                    : policy.retryDelays.last ?? 0
                if delay > 0 {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                }
                attempt += 1
            }
        }
    }

    private func performAttempt(
        _ request: URLRequest,
        timeout: TimeInterval
    ) async throws -> BoundedHTTPResponse {
        let state = BoundedHTTPRequestState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let dataTask = session.dataTask(with: request) { data, response, error in
                    if let error {
                        state.finish(.failure(error))
                        return
                    }
                    guard let response = response as? HTTPURLResponse else {
                        state.finish(.failure(BoundedHTTPError.invalidResponse))
                        return
                    }
                    state.finish(.success(BoundedHTTPResponse(data: data ?? Data(), response: response)))
                }
                state.install(continuation: continuation, dataTask: dataTask)
                dataTask.resume()
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
                    guard !Task.isCancelled else { return }
                    state.timeout()
                }
                state.install(timeoutTask: timeoutTask)
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? BoundedHTTPError {
            switch error {
            case .timedOut:
                return true
            case .httpStatus(let status):
                return status == 408 || status == 429 || (500..<600).contains(status)
            case .invalidResponse:
                return false
            }
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

private final class BoundedHTTPRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoundedHTTPResponse, Error>?
    private var dataTask: URLSessionDataTask?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    func install(
        continuation: CheckedContinuation<BoundedHTTPResponse, Error>,
        dataTask: URLSessionDataTask
    ) {
        lock.lock()
        if completed {
            lock.unlock()
            dataTask.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.dataTask = dataTask
        lock.unlock()
    }

    func install(timeoutTask: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            timeoutTask.cancel()
            return
        }
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func finish(_ result: Result<BoundedHTTPResponse, Error>) {
        let continuation: CheckedContinuation<BoundedHTTPResponse, Error>?
        let timeoutTask: Task<Void, Never>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.timeoutTask = nil
        self.dataTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }

    func timeout() {
        let continuation: CheckedContinuation<BoundedHTTPResponse, Error>?
        let dataTask: URLSessionDataTask?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        dataTask = self.dataTask
        self.continuation = nil
        self.dataTask = nil
        self.timeoutTask = nil
        lock.unlock()

        dataTask?.cancel()
        continuation?.resume(throwing: BoundedHTTPError.timedOut)
    }

    func cancel() {
        let continuation: CheckedContinuation<BoundedHTTPResponse, Error>?
        let dataTask: URLSessionDataTask?
        let timeoutTask: Task<Void, Never>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        dataTask = self.dataTask
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.dataTask = nil
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        dataTask?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}
