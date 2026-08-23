import Foundation
import PodcastEnglishStudioCore

actor YTLocalMediaServiceClient {
    private let config: YTLocalMediaServiceConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private var pollTasks: [String: Task<YTLocalMediaJobResponse, Error>] = [:]

    init(config: YTLocalMediaServiceConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.decoder = JSONDecoder()
    }

    func prepare(
        videoID: String,
        mode: YTLocalMediaMode? = nil,
        preferredHeight: Int? = nil
    ) async throws -> YTLocalMediaPrepareResponse {
        var request = try makeRequest(
            path: "/v1/videos/\(videoID)/prepare",
            method: "POST"
        )
        let body: [String: Any] = [
            "mode": (mode ?? config.mode).rawValue,
            "preferredHeight": preferredHeight ?? config.preferredHeight
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: YTLocalMediaPrepareResponse.self)
    }

    func job(jobID: String) async throws -> YTLocalMediaJobResponse {
        let request = try makeRequest(path: "/v1/jobs/\(jobID)", method: "GET")
        return try await send(request, as: YTLocalMediaJobResponse.self)
    }

    func reusableAudioURL(
        videoID: String,
        mode: YTLocalMediaMode? = nil,
        preferredHeight: Int? = nil
    ) async throws -> URL {
        let ready = try await waitUntilReady(
            videoID: videoID,
            mode: mode,
            preferredHeight: preferredHeight
        )
        guard let audioURL = ready.playback?.audioURL else {
            throw YTLocalMediaServiceError.invalidResponse
        }
        return audioURL
    }

    func waitUntilReady(
        videoID: String,
        mode: YTLocalMediaMode? = nil,
        preferredHeight: Int? = nil,
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        timeout: TimeInterval = 60 * 60
    ) async throws -> YTLocalMediaJobResponse {
        let prepared = try await prepare(
            videoID: videoID,
            mode: mode,
            preferredHeight: preferredHeight
        )
        return try await waitForJob(
            jobID: prepared.jobId,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            timeout: timeout
        )
    }

    func waitForJob(
        jobID: String,
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        timeout: TimeInterval = 60 * 60
    ) async throws -> YTLocalMediaJobResponse {
        if let existing = pollTasks[jobID] {
            return try await existing.value
        }

        let task = Task<YTLocalMediaJobResponse, Error> {
            let deadline = Date().addingTimeInterval(timeout)
            while !Task.isCancelled {
                let current = try await self.job(jobID: jobID)
                switch current.status {
                case .ready:
                    guard let playback = current.playback else {
                        throw YTLocalMediaServiceError.invalidResponse
                    }
                    _ = playback
                    return current
                case .failed:
                    throw YTLocalMediaServiceError.backend(
                        current.errorCode ?? .unknown,
                        current.errorMessage
                    )
                case .queued, .resolving, .fetching, .packaging:
                    if Date() >= deadline {
                        throw YTLocalMediaServiceError.timedOut
                    }
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                }
            }
            throw YTLocalMediaServiceError.cancelled
        }

        pollTasks[jobID] = task
        defer { pollTasks[jobID] = nil }
        do {
            return try await task.value
        } catch is CancellationError {
            throw YTLocalMediaServiceError.cancelled
        }
    }

    func cancel(jobID: String) {
        pollTasks[jobID]?.cancel()
        pollTasks[jobID] = nil
    }

    /// Ask the backend to delete job media (R2 + disk). Best-effort.
    func deleteJob(jobID: String) async {
        cancel(jobID: jobID)
        do {
            var request = try makeRequest(path: "/v1/jobs/\(jobID)", method: "DELETE")
            request.timeoutInterval = 15
            let (_, response) = try await session.data(for: request)
            _ = response
        } catch {
#if DEBUG
            print("YTLocalMediaServiceClient: deleteJob failed \(jobID) \(error.localizedDescription)")
#endif
        }
    }

    func cancelAll() {
        for (_, task) in pollTasks {
            task.cancel()
        }
        pollTasks.removeAll()
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: config.baseURL)?.absoluteURL else {
            throw YTLocalMediaServiceError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw YTLocalMediaServiceError.cancelled
        } catch {
#if DEBUG
            print("YTLocalMediaServiceClient: request failed \(request.url?.absoluteString ?? "?") error=\(error.localizedDescription)")
#endif
            throw YTLocalMediaServiceError.backend(
                .internalError,
                error.localizedDescription
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw YTLocalMediaServiceError.invalidResponse
        }

        if http.statusCode == 401 {
            throw YTLocalMediaServiceError.backend(.unauthorized, "Unauthorized")
        }
        if http.statusCode == 410 {
            throw YTLocalMediaServiceError.backend(.mediaExpired, "Media expired")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? decoder.decode(APIErrorBody.self, from: data) {
                let code = YTLocalMediaErrorCode(rawValue: apiError.error ?? "") ?? .unknown
                throw YTLocalMediaServiceError.backend(code, apiError.message)
            }
            throw YTLocalMediaServiceError.httpStatus(http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw YTLocalMediaServiceError.invalidResponse
        }
    }
}

private struct APIErrorBody: Decodable {
    let error: String?
    let message: String?
}
