import CryptoKit
import Foundation
import OSLog
import PodcastEnglishStudioCore
import CloudSyncKit

enum PipelineError: LocalizedError {
    case missingConfiguration(String)
    case badResponse(String)
    case transientNetworkFailure(String, Int)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            L10n.string("error.missing_configuration", fallback: "Required configuration is missing. Check Settings and try again.")
        case .badResponse(let value):
            L10n.format("error.request_failed_detail", fallback: "The request could not be completed.\nDetails: %@", value)
        case .transientNetworkFailure(_, let attempts):
            L10n.format("error.network_failed", fallback: "The network request failed after %@ attempts. Check your connection and try again.", String(attempts))
        }
    }
}

struct OSSUploadResult: Sendable {
    var objectKey: String
    var signedURL: URL
}

final class AliyunOSSClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func uploadAndSign(audioURL: URL, episodeID: String, configuration: AppConfiguration) async throws -> OSSUploadResult {
        let objectKey = "podcast-english-studio/\(episodeID)/\(audioURL.lastPathComponent)"
        let endpoint = bucketEndpoint(configuration)
        guard let putURL = URL(string: "\(endpoint)/\(objectKey)") else {
            throw PipelineError.missingConfiguration("OSS endpoint")
        }
        let contentType = "audio/mpeg"
        let date = Self.httpDate(Date())
        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue(date, forHTTPHeaderField: "Date")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            authorization(
                method: "PUT",
                contentType: contentType,
                dateOrExpires: date,
                bucket: configuration.ossBucket,
                objectKey: objectKey,
                accessKeyID: configuration.ossAccessKeyID,
                accessKeySecret: configuration.ossAccessKeySecret
            ),
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try Data(contentsOf: audioURL)
        let (_, response) = try await withNetworkRetries(operation: "OSS upload") {
            try await self.session.data(for: request)
        }
        try validateHTTP(response, context: "OSS upload failed")

        let expires = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let signature = signature(
            method: "GET",
            contentType: "",
            dateOrExpires: String(expires),
            bucket: configuration.ossBucket,
            objectKey: objectKey,
            secret: configuration.ossAccessKeySecret
        )
        var components = URLComponents(url: putURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "OSSAccessKeyId", value: configuration.ossAccessKeyID),
            URLQueryItem(name: "Expires", value: String(expires)),
            URLQueryItem(name: "Signature", value: signature)
        ]
        guard let signedURL = components.url else {
            throw PipelineError.badResponse("Could not sign OSS URL.")
        }
        return OSSUploadResult(objectKey: objectKey, signedURL: signedURL)
    }

    func delete(objectKey: String, configuration: AppConfiguration) async throws {
        let endpoint = bucketEndpoint(configuration)
        guard let url = URL(string: "\(endpoint)/\(objectKey)") else { return }
        let date = Self.httpDate(Date())
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(date, forHTTPHeaderField: "Date")
        request.setValue(
            authorization(
                method: "DELETE",
                contentType: "",
                dateOrExpires: date,
                bucket: configuration.ossBucket,
                objectKey: objectKey,
                accessKeyID: configuration.ossAccessKeyID,
                accessKeySecret: configuration.ossAccessKeySecret
            ),
            forHTTPHeaderField: "Authorization"
        )
        let (_, response) = try await withNetworkRetries(operation: "OSS deletion") {
            try await self.session.data(for: request)
        }
        try validateHTTP(response, context: "OSS delete failed")
    }

    private func bucketEndpoint(_ configuration: AppConfiguration) -> String {
        let endpoint = normalizedEndpoint(configuration.ossEndpoint)
        guard let url = URL(string: endpoint), let host = url.host(), !host.hasPrefix("\(configuration.ossBucket).") else {
            return endpoint
        }
        return "\(url.scheme ?? "https")://\(configuration.ossBucket).\(host)"
    }

    private func normalizedEndpoint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http") ? trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : "https://\(trimmed)"
    }

    private func authorization(
        method: String,
        contentType: String,
        dateOrExpires: String,
        bucket: String,
        objectKey: String,
        accessKeyID: String,
        accessKeySecret: String
    ) -> String {
        let signed = signature(
            method: method,
            contentType: contentType,
            dateOrExpires: dateOrExpires,
            bucket: bucket,
            objectKey: objectKey,
            secret: accessKeySecret
        )
        return "OSS \(accessKeyID):\(signed)"
    }

    private func signature(method: String, contentType: String, dateOrExpires: String, bucket: String, objectKey: String, secret: String) -> String {
        let canonical = "\(method)\n\n\(contentType)\n\(dateOrExpires)\n/\(bucket)/\(objectKey)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(canonical.utf8), using: key)
        return Data(code).base64EncodedString()
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

final class DashScopeTranscriptionClient {
    private let session: URLSession
    private let httpClient: BoundedHTTPClient
    private let transcriptionModel = "paraformer-v2"
    private let logger = Logger(
        subsystem: "com.example.LinguaCast",
        category: "DashScopeASR"
    )

    init(session: URLSession = .shared) {
        self.session = session
        self.httpClient = BoundedHTTPClient(session: session)
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        checkpointStore: DashScopeCheckpointStore,
        downloadedResultURL: URL,
        onStage: @escaping (DashScopeTranscriptionStage) async -> Void
    ) async throws -> [LearningSegment] {
        let audioIdentity = try DashScopeAudioIdentity.read(from: audioURL)
        let savedCheckpoint = try checkpointStore.load()
        var checkpoint: DashScopeTranscriptionCheckpoint
        let isMatchingCheckpoint: Bool
        if let saved = savedCheckpoint,
           saved.audioIdentity == audioIdentity,
           saved.schemaVersion == 1 {
            checkpoint = saved
            isMatchingCheckpoint = true
        } else {
            try? checkpointStore.remove()
            try? FileManager.default.removeItem(at: downloadedResultURL)
            checkpoint = DashScopeTranscriptionCheckpoint(audioIdentity: audioIdentity)
            try checkpointStore.save(checkpoint)
            isMatchingCheckpoint = false
        }

        var action = checkpoint.resumeAction(
            for: audioIdentity,
            hasDownloadedResult: isMatchingCheckpoint && FileManager.default.fileExists(
                atPath: downloadedResultURL.path
            )
        )
        var refreshedExpiredResultURL = false

        while true {
            try Task.checkCancellation()
            switch action {
            case .startUpload:
                try await update(
                    checkpoint: &checkpoint,
                    stage: .preparingUpload,
                    store: checkpointStore,
                    onStage: onStage
                )
                try await update(
                    checkpoint: &checkpoint,
                    stage: .uploadingAudio,
                    store: checkpointStore,
                    onStage: onStage
                )
                let remoteAudioURL = try await uploadTemporaryAudio(audioURL, apiKey: apiKey)
                checkpoint.remoteAudioURL = remoteAudioURL
                checkpoint.taskID = nil
                checkpoint.transcriptURL = nil
                checkpoint.taskStatus = nil
                checkpoint.updatedAt = Date()
                try checkpointStore.save(checkpoint)
                action = .submit(remoteAudioURL: remoteAudioURL)

            case .submit(let remoteAudioURL):
                try await update(
                    checkpoint: &checkpoint,
                    stage: .submitting,
                    store: checkpointStore,
                    onStage: onStage
                )
                let taskID: String
                do {
                    taskID = try await submit(
                        remoteAudioURL: remoteAudioURL,
                        apiKey: apiKey
                    )
                } catch let error as BoundedHTTPError {
                    if case .httpStatus(let status) = error,
                       [400, 401, 403, 404, 405, 409, 413, 415, 422, 429].contains(status) {
                        // A received HTTP response proves that this submission
                        // was rejected, so retrying the remote audio is safe.
                        checkpoint.stage = .uploadingAudio
                        checkpoint.updatedAt = Date()
                        try checkpointStore.save(checkpoint)
                    }
                    throw error
                } catch {
                    // A transport failure is ambiguous: DashScope may have
                    // accepted a task whose ID never reached this device. Keep
                    // `.submitting` so later runs cannot submit it twice.
                    throw error
                }
                checkpoint.taskID = taskID
                checkpoint.taskStatus = "PENDING"
                checkpoint.transcriptURL = nil
                checkpoint.updatedAt = Date()
                try checkpointStore.save(checkpoint)
                logger.info("Submitted and checkpointed DashScope task")
                action = .poll(taskID: taskID)

            case .submissionOutcomeUnknown:
                throw PipelineError.badResponse(
                    "The previous transcription submission may have reached DashScope, but its task ID was not received. To avoid creating a duplicate task, use Clear and regenerate before starting again."
                )

            case .poll(let taskID):
                try await update(
                    checkpoint: &checkpoint,
                    stage: .polling,
                    store: checkpointStore,
                    onStage: onStage
                )
                do {
                    let transcriptURL = try await poll(
                        taskID: taskID,
                        apiKey: apiKey
                    ) { status in
                        checkpoint.taskStatus = status
                        checkpoint.updatedAt = Date()
                        try checkpointStore.save(checkpoint)
                    }
                    checkpoint.taskStatus = "SUCCEEDED"
                    checkpoint.transcriptURL = transcriptURL.absoluteString
                    checkpoint.updatedAt = Date()
                    try checkpointStore.save(checkpoint)
                    action = .downloadResult(url: transcriptURL, taskID: taskID)
                } catch let error as DashScopeTerminalTaskError {
                    try? checkpointStore.remove()
                    try? FileManager.default.removeItem(at: downloadedResultURL)
                    throw error
                }

            case .downloadResult(let transcriptURL, let taskID):
                try await update(
                    checkpoint: &checkpoint,
                    stage: .downloadingResult,
                    store: checkpointStore,
                    onStage: onStage
                )
                var request = URLRequest(url: transcriptURL)
                request.timeoutInterval = 60
                do {
                    let response = try await httpClient.data(
                        for: request,
                        policy: BoundedHTTPRetryPolicy(
                            maxAttempts: 3,
                            attemptTimeout: 60,
                            retryDelays: [3, 6]
                        )
                    )
                    try response.data.write(to: downloadedResultURL, options: .atomic)
                    logger.info(
                        "Downloaded DashScope result (\(response.data.count, privacy: .public) bytes)"
                    )
                    action = .parseDownloadedResult
                } catch {
                    if case BoundedHTTPError.httpStatus(let status) = error,
                       [401, 403].contains(status),
                       let taskID,
                       !refreshedExpiredResultURL {
                        refreshedExpiredResultURL = true
                        checkpoint.transcriptURL = nil
                        checkpoint.updatedAt = Date()
                        try checkpointStore.save(checkpoint)
                        action = .poll(taskID: taskID)
                    } else {
                        throw error
                    }
                }

            case .parseDownloadedResult:
                try await update(
                    checkpoint: &checkpoint,
                    stage: .parsingResult,
                    store: checkpointStore,
                    onStage: onStage
                )
                do {
                    let data = try Data(contentsOf: downloadedResultURL)
                    let payload = try JSONSerialization.jsonObject(with: data)
                    let segments = TranscriptionSegmentExtractor.extractSegments(from: payload)
                    guard !segments.isEmpty else {
                        throw PipelineError.badResponse(
                            "DashScope transcription result did not contain any sentences."
                        )
                    }
                    logger.info(
                        "Parsed DashScope result (\(segments.count, privacy: .public) sentences)"
                    )
                    return segments
                } catch {
                    try? FileManager.default.removeItem(at: downloadedResultURL)
                    throw error
                }
            }
        }
    }

    private func update(
        checkpoint: inout DashScopeTranscriptionCheckpoint,
        stage: DashScopeTranscriptionStage,
        store: DashScopeCheckpointStore,
        onStage: (DashScopeTranscriptionStage) async -> Void
    ) async throws {
        checkpoint.stage = stage
        checkpoint.updatedAt = Date()
        try store.save(checkpoint)
        logger.info("DashScope stage \(stage.rawValue, privacy: .public)")
        await onStage(stage)
    }

    private func uploadTemporaryAudio(_ audioURL: URL, apiKey: String) async throws -> String {
        let policy = try await uploadPolicy(apiKey: apiKey)
        let fileSize = try fileSizeInMB(audioURL)
        if let maxFileSizeMB = policy.maxFileSizeMB, fileSize > maxFileSizeMB {
            throw PipelineError.badResponse("Audio file size \(fileSize) MB exceeds the DashScope temporary upload limit of \(maxFileSizeMB) MB.")
        }

        let fileName = audioURL.lastPathComponent
        let objectKey = "\(policy.uploadDir)/\(fileName)"
        var request = URLRequest(url: policy.uploadHost)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let fields = [
            MultipartFormField(name: "OSSAccessKeyId", value: policy.ossAccessKeyID),
            MultipartFormField(name: "Signature", value: policy.signature),
            MultipartFormField(name: "policy", value: policy.policy),
            MultipartFormField(name: "x-oss-object-acl", value: policy.objectACL),
            MultipartFormField(name: "x-oss-forbid-overwrite", value: policy.forbidOverwrite),
            MultipartFormField(name: "key", value: objectKey),
            MultipartFormField(name: "success_action_status", value: "200")
        ]
        return try await MultipartFormFileWriter.withTemporaryBody(
            fields: fields,
            fileFieldName: "file",
            fileName: fileName,
            contentType: "audio/mpeg",
            sourceFileURL: audioURL,
            boundary: boundary
        ) { body in
            var requestWithLength = request
            requestWithLength.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            let uploadRequest = requestWithLength
            let (data, response) = try await withNetworkRetries(operation: "DashScope temporary audio upload") {
                try await self.upload(
                    for: uploadRequest,
                    fromFile: body.url,
                    wallClockTimeout: 900
                )
            }
            try validateHTTP(response, context: "DashScope temporary audio upload failed", responseBody: data)
            return "oss://\(objectKey)"
        }
    }

    private func uploadPolicy(apiKey: String) async throws -> DashScopeUploadPolicy {
        var components = URLComponents(string: "https://dashscope.aliyuncs.com/api/v1/uploads")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: transcriptionModel)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let policyResponse = try await httpClient.data(
            for: request,
            policy: BoundedHTTPRetryPolicy(
                maxAttempts: 3,
                attemptTimeout: 30,
                retryDelays: [3, 6]
            )
        )
        let data = policyResponse.data
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let data = json?["data"] as? [String: Any],
              let policy = data["policy"] as? String,
              let signature = data["signature"] as? String,
              let uploadDir = data["upload_dir"] as? String,
              let uploadHostString = data["upload_host"] as? String,
              let uploadHost = URL(string: uploadHostString),
              let ossAccessKeyID = data["oss_access_key_id"] as? String,
              let objectACL = data["x_oss_object_acl"] as? String,
              let forbidOverwrite = data["x_oss_forbid_overwrite"] as? String else {
            throw PipelineError.badResponse("DashScope upload policy response is incomplete.")
        }
        return DashScopeUploadPolicy(
            policy: policy,
            signature: signature,
            uploadDir: uploadDir,
            uploadHost: uploadHost,
            ossAccessKeyID: ossAccessKeyID,
            objectACL: objectACL,
            forbidOverwrite: forbidOverwrite,
            maxFileSizeMB: intValue(data["max_file_size_mb"])
        )
    }

    private func submit(remoteAudioURL: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": transcriptionModel,
            "input": ["file_urls": [remoteAudioURL]],
            "parameters": [
                "timestamp_alignment_enabled": true,
                "diarization_enabled": true,
                "speaker_count": 4
            ]
        ])
        let submitResponse = try await httpClient.data(
            for: request,
            policy: BoundedHTTPRetryPolicy(
                // Task creation is not idempotent. Retrying after a lost response
                // could create a second billable task with no task ID to resume.
                maxAttempts: 1,
                attemptTimeout: 30,
                retryDelays: []
            )
        )
        let data = submitResponse.data
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let taskID = (json?["output"] as? [String: Any])?["task_id"] as? String {
            return taskID
        }
        throw PipelineError.badResponse("DashScope ASR did not return task_id.")
    }

    private func poll(
        taskID: String,
        apiKey: String,
        onStatus: (String?) throws -> Void
    ) async throws -> URL {
        let url = URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(taskID)")!
        let deadline = Date().addingTimeInterval(20 * 60)
        while !Task.isCancelled {
            guard Date() < deadline else {
                throw PipelineError.badResponse(
                    "DashScope ASR did not finish within 20 minutes. Retry will resume the same task."
                )
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let pollResponse = try await httpClient.data(
                for: request,
                policy: BoundedHTTPRetryPolicy(
                    maxAttempts: 3,
                    attemptTimeout: 30,
                    retryDelays: [3, 6]
                )
            )
            let data = pollResponse.data
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let output = json?["output"] as? [String: Any]
            let status = output?["task_status"] as? String
            try onStatus(status)
            if status == "SUCCEEDED" {
                if let results = output?["results"] as? [[String: Any]],
                   let value = results.first?["transcription_url"] as? String,
                   let transcriptURL = URL(string: value) {
                    return transcriptURL
                }
                if let value = output?["transcription_url"] as? String, let transcriptURL = URL(string: value) {
                    return transcriptURL
                }
                throw PipelineError.badResponse("DashScope ASR succeeded without transcription_url.")
            }
            if ["FAILED", "CANCELED", "UNKNOWN"].contains(status ?? "") {
                throw DashScopeTerminalTaskError(
                    message: dashScopeFailureMessage(status: status, payload: json)
                )
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw CancellationError()
    }

    private func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        wallClockTimeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(
            of: DashScopeUploadResponse.self
        ) { group in
            group.addTask {
                let (data, response) = try await self.session.upload(
                    for: request,
                    fromFile: fileURL
                )
                return DashScopeUploadResponse(data: data, response: response)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(wallClockTimeout * 1_000_000_000)
                )
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return (result.data, result.response)
        }
    }

    private func dashScopeFailureMessage(status: String?, payload: [String: Any]?) -> String {
        let statusText = status ?? "unknown"
        guard let payload else {
            return "DashScope ASR ended with status \(statusText)."
        }
        let detail = structuredErrorDetail(from: payload)
            ?? compactJSONExcerpt(from: payload)
        guard let detail, !detail.isEmpty else {
            return "DashScope ASR ended with status \(statusText)."
        }
        return "DashScope ASR ended with status \(statusText): \(detail)"
    }
}

private struct DashScopeTerminalTaskError: LocalizedError {
    var message: String

    var errorDescription: String? { message }
}

private struct DashScopeUploadPolicy {
    var policy: String
    var signature: String
    var uploadDir: String
    var uploadHost: URL
    var ossAccessKeyID: String
    var objectACL: String
    var forbidOverwrite: String
    var maxFileSizeMB: Int?
}

private struct DashScopeUploadResponse: @unchecked Sendable {
    let data: Data
    let response: URLResponse
}

private func fileSizeInMB(_ url: URL) throws -> Int {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    let bytes = values.fileSize ?? 0
    return Int(ceil(Double(bytes) / 1_048_576.0))
}

final class TranslationClient {
    private let session: URLSession
    private let translationRetryMaxAttempts = 4
    private let requestThrottler = TranslationRequestThrottler()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func translate(
        _ segments: [LearningSegment],
        target: TranslationTarget,
        configuration: AppConfiguration
    ) async throws -> [LearningSegment] {
        try await translateIncrementally(segments, target: target, configuration: configuration) { _ in }
    }

    /// Split an existing translation into exactly `partCount` consecutive parts matching a
    /// source split. Returns nil on any failure (caller keeps the whole-sentence translation).
    /// Propagates `CancellationError` so cancel never collapses into a per-sentence soft failure.
    func splitTranslation(
        _ translation: String,
        intoPartCount partCount: Int,
        target: TranslationTarget,
        configuration: AppConfiguration
    ) async throws -> [String]? {
        guard configuration.hasTranslationKey, partCount > 1 else { return nil }
        do {
            let content = try await requestChatCompletion(
                systemPrompt: TranslationPromptPolicy.alignedTranslationSplitSystemPrompt(
                    target: target,
                    partCount: partCount
                ),
                userPrompt: translation,
                configuration: configuration
            )
            return Self.parseTranslationSplitParts(content, expectedCount: partCount)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Parse the `{"parts":[...]}` split response, requiring exactly `expectedCount` non-empty
    /// parts. Tolerates code fences and surrounding prose around the JSON object.
    private static func parseTranslationSplitParts(_ content: String, expectedCount: Int) -> [String]? {
        let unfenced = content.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = unfenced.firstIndex(of: "{"), let end = unfenced.lastIndex(of: "}") else { return nil }
        let jsonText = String(unfenced[start...end])
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["parts"] as? [Any],
              parts.count == expectedCount else { return nil }
        let strings = parts.map { ($0 as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard strings.allSatisfy({ !$0.isEmpty }) else { return nil }
        return strings
    }

    func translateIncrementally(
        _ segments: [LearningSegment],
        target: TranslationTarget,
        configuration: AppConfiguration,
        onProgress: @MainActor ([LearningSegment]) async throws -> Void
    ) async throws -> [LearningSegment] {
        var translated = segments
        let pendingSegments = translated.filter {
            $0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !pendingSegments.isEmpty else { return translated }

        // Topic summary + glossary, extracted once. A failure degrades to no context —
        // it never blocks translation.
        let context = await extractContext(for: segments, target: target, configuration: configuration)
        let qualityMode = configuration.translationQuality

        let batches = TranslationBatchPlanner.batches(
            for: pendingSegments,
            provider: configuration.translationProvider
        )
        let maxConcurrentRequests = TranslationConcurrencyPolicy.maxConcurrentRequests(
            forProvider: configuration.translationProvider
        )

        try await withThrowingTaskGroup(of: [Int: String].self) { group in
            var nextBatchIndex = 0

            func enqueueNextBatch() {
                guard nextBatchIndex < batches.count else { return }
                let batch = batches[nextBatchIndex]
                nextBatchIndex += 1
                group.addTask {
                    try await self.translateBatch(
                        batch,
                        allSegments: segments,
                        context: context,
                        qualityMode: qualityMode,
                        target: target,
                        configuration: configuration,
                        maxConcurrentFallbacks: maxConcurrentRequests
                    )
                }
            }

            for _ in 0..<min(maxConcurrentRequests, batches.count) {
                enqueueNextBatch()
            }

            while let translationsBySequence = try await group.next() {
                translated = TranslationResultMerger.apply(
                    translationsBySequence: translationsBySequence,
                    to: translated
                )
                try await onProgress(translated)
                enqueueNextBatch()
            }
        }
        return translated
    }

    // MARK: - Topic / term extraction

    private func extractContext(
        for segments: [LearningSegment],
        target: TranslationTarget,
        configuration: AppConfiguration
    ) async -> TranslationContext {
        guard configuration.hasTranslationKey else { return .empty }
        let sample = TranslationContextSamplingPolicy.sampleText(segments: segments)
        guard !sample.isEmpty else { return .empty }
        do {
            let raw = try await requestChatCompletion(
                systemPrompt: TranslationPromptPolicy.contextExtractionSystemPrompt(target: target),
                userPrompt: sample,
                configuration: configuration
            )
            return parseContext(raw) ?? .empty
        } catch {
            return .empty
        }
    }

    private func parseContext(_ raw: String) -> TranslationContext? {
        let stripped = stripJSONMarkdown(raw)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let summary = (json["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawTerms = json["terms"] as? [[String: Any]] ?? []
        let terms = rawTerms.prefix(15).compactMap { entry -> TranslationTerm? in
            guard let source = (entry["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty,
                  let target = (entry["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty
            else { return nil }
            let note = (entry["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TranslationTerm(source: source, target: target, note: note)
        }
        return TranslationContext(topicSummary: summary, terms: terms)
    }

    // MARK: - Batch translation (numbered JSON, reflective or direct)

    private func translateBatch(
        _ batch: TranslationBatch,
        allSegments: [LearningSegment],
        context: TranslationContext,
        qualityMode: TranslationQualityMode,
        target: TranslationTarget,
        configuration: AppConfiguration,
        maxConcurrentFallbacks: Int
    ) async throws -> [Int: String] {
        let blockContext = TranslationBlockContextPolicy.context(
            allSegments: allSegments,
            blockSequences: Set(batch.segments.map(\.sequence))
        )
        let blockText = batch.segments.map(\.text).joined(separator: "\n")
        let matchedTerms = context.terms(matching: blockText)
        let systemPrompt = TranslationPromptPolicy.batchSystemPrompt(
            target: target,
            topicSummary: context.topicSummary,
            terms: matchedTerms,
            contextBefore: blockContext.before,
            contextAfter: blockContext.after,
            qualityMode: qualityMode
        )
        let userPrompt = numberedUserPrompt(for: batch)

        var translations: [Int: String] = [:]
        // Structure/content validation failures retry the whole batch up to 3 times.
        for _ in 0..<3 {
            do {
                let raw = try await requestChatCompletion(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    configuration: configuration
                )
                translations = try parseNumberedBatchTranslations(
                    raw,
                    expected: batch.segments,
                    qualityMode: qualityMode
                )
                break
            } catch is TranslationContentError {
                continue
            }
        }

        let missing = TranslationBatchPlanner.missingSequences(
            in: batch,
            translatedSequences: Set(translations.keys)
        )
        if !missing.isEmpty {
            // Per-line fallback with the same numbered skeleton, up to 3 attempts each.
            let missingSegments = batch.segments.filter { missing.contains($0.sequence) }
            let fallback = try await translateSegmentsIndividually(
                missingSegments,
                context: context,
                qualityMode: qualityMode,
                target: target,
                configuration: configuration,
                maxConcurrentRequests: maxConcurrentFallbacks
            )
            translations.merge(fallback) { current, _ in current }
        }

        // Any still-missing line is a hard failure: the artifact must stay partial/failed.
        let stillMissing = TranslationBatchPlanner.missingSequences(
            in: batch,
            translatedSequences: Set(translations.keys)
        )
        guard stillMissing.isEmpty else {
            throw TranslationContentError.missingContent
        }
        return translations
    }

    private func translateSegmentsIndividually(
        _ segments: [LearningSegment],
        context: TranslationContext,
        qualityMode: TranslationQualityMode,
        target: TranslationTarget,
        configuration: AppConfiguration,
        maxConcurrentRequests: Int
    ) async throws -> [Int: String] {
        guard !segments.isEmpty else { return [:] }
        var translations: [Int: String] = [:]
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            var nextIndex = 0

            func enqueueNextSegment() {
                guard nextIndex < segments.count else { return }
                let segment = segments[nextIndex]
                nextIndex += 1
                group.addTask {
                    let translation = try await self.translateOneWithRetries(
                        segment: segment,
                        context: context,
                        qualityMode: qualityMode,
                        target: target,
                        configuration: configuration
                    )
                    return (segment.sequence, translation)
                }
            }

            for _ in 0..<min(maxConcurrentRequests, segments.count) {
                enqueueNextSegment()
            }

            while let (sequence, translation) = try await group.next() {
                if let translation {
                    translations[sequence] = translation
                }
                enqueueNextSegment()
            }
        }
        return translations
    }

    /// Per-line numbered translation with up to 3 attempts; returns nil when the line
    /// ultimately cannot be produced (so the caller can mark the artifact incomplete).
    private func translateOneWithRetries(
        segment: LearningSegment,
        context: TranslationContext,
        qualityMode: TranslationQualityMode,
        target: TranslationTarget,
        configuration: AppConfiguration
    ) async throws -> String? {
        let matchedTerms = context.terms(matching: segment.text)
        let systemPrompt = TranslationPromptPolicy.singleSystemPrompt(
            target: target,
            topicSummary: context.topicSummary,
            terms: matchedTerms,
            qualityMode: qualityMode
        )
        for _ in 0..<3 {
            do {
                let raw = try await requestChatCompletion(
                    systemPrompt: systemPrompt,
                    userPrompt: "1. \(segment.text)",
                    configuration: configuration
                )
                return try parseNumberedSingleTranslation(
                    raw,
                    expected: segment,
                    qualityMode: qualityMode
                )
            } catch is TranslationContentError {
                continue
            }
        }
        return nil
    }

    // MARK: - Chat plumbing

    private func requestChatCompletion(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration
    ) async throws -> String {
        let provider = TranslationProviderPolicy.normalizedProvider(configuration.translationProvider)
        let baseURL = TranslationProviderPolicy.requestBaseURL(
            provider: provider,
            configuredBaseURL: configuration.translationBaseURL
        )
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw PipelineError.missingConfiguration("translation base URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.translationAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: TranslationChatRequestPolicy.requestBody(
                provider: provider,
                modelID: configuration.translationModelID,
                reasoningEffort: configuration.translationReasoningEffort,
                messages: [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            )
        )

        // DeepSeek JSON Output can return empty content; retry the identical request once.
        var emptyContentAttempt = 1
        while true {
            let data = try await sendTranslationRequest(request, provider: provider)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let content = TranslationChatResponsePolicy.extractContent(from: json)
            if !TranslationChatResponsePolicy.isEmptyContent(content) {
                return content ?? ""
            }
            if TranslationChatResponsePolicy.shouldRetryEmptyContent(
                provider: provider,
                attempt: emptyContentAttempt
            ) {
                emptyContentAttempt += 1
                continue
            }
            throw TranslationContentError.missingContent
        }
    }

    private func sendTranslationRequest(_ request: URLRequest, provider: String) async throws -> Data {
        var attempt = 1
        while true {
            try await requestThrottler.waitIfNeeded(provider: provider)
            let (data, response) = try await withNetworkRetries(operation: "translation request") {
                try await self.session.data(for: request)
            }

            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode),
               TranslationRetryPolicy.shouldRetryHTTPStatus(http.statusCode, provider: provider),
               attempt < translationRetryMaxAttempts {
                let delay = TranslationRetryPolicy.retryDelaySeconds(
                    statusCode: http.statusCode,
                    provider: provider,
                    attempt: attempt,
                    headers: httpHeaderFields(http)
                ) ?? 2
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                attempt += 1
                continue
            }

            try validateHTTP(response, context: "Translation failed", responseBody: data)
            return data
        }
    }

    // MARK: - Prompts + strict parsing

    private func numberedUserPrompt(for batch: TranslationBatch) -> String {
        batch.segments
            .map { "\($0.sequence). \($0.text)" }
            .joined(separator: "\n")
    }

    /// Strict numbered-JSON validation. Every rule must hold simultaneously:
    /// key set exactly matches the expected sequences, one object per source line,
    /// `origin` equals the source text, and the required translation field is non-empty.
    /// Interior newlines inside translations are cleaned to spaces.
    private func parseNumberedBatchTranslations(
        _ raw: String,
        expected: [LearningSegment],
        qualityMode: TranslationQualityMode
    ) throws -> [Int: String] {
        let stripped = stripJSONMarkdown(raw)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TranslationContentError.invalidJSON
        }

        let expectedSequences = Set(expected.map(\.sequence))
        let expectedBySequence = Dictionary(uniqueKeysWithValues: expected.map { ($0.sequence, $0) })
        let providedKeys = Set(json.keys.compactMap(Int.init))
        guard providedKeys == expectedSequences, json.count == expected.count else {
            throw TranslationContentError.invalidJSON
        }

        var translations: [Int: String] = [:]
        for (key, value) in json {
            guard let sequence = Int(key),
                  let source = expectedBySequence[sequence],
                  let entry = value as? [String: Any]
            else { throw TranslationContentError.invalidJSON }
            guard let origin = (entry["origin"] as? String), origin == source.text else {
                throw TranslationContentError.invalidJSON
            }
            guard let translation = requiredTranslation(from: entry, qualityMode: qualityMode) else {
                throw TranslationContentError.missingContent
            }
            translations[sequence] = translation
        }
        guard translations.count == expected.count else { throw TranslationContentError.missingContent }
        return translations
    }

    private func parseNumberedSingleTranslation(
        _ raw: String,
        expected: LearningSegment,
        qualityMode: TranslationQualityMode
    ) throws -> String {
        let stripped = stripJSONMarkdown(raw)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TranslationContentError.invalidJSON
        }
        // Accept either a bare object or a single-keyed numbered wrapper.
        let entry: [String: Any]
        if let origin = json["origin"] as? String {
            guard origin == expected.text else { throw TranslationContentError.invalidJSON }
            entry = json
        } else if json.count == 1,
                  let nested = json.values.first as? [String: Any],
                  (nested["origin"] as? String) == expected.text {
            entry = nested
        } else {
            throw TranslationContentError.invalidJSON
        }
        guard let translation = requiredTranslation(from: entry, qualityMode: qualityMode) else {
            throw TranslationContentError.missingContent
        }
        return translation
    }

    /// quality mode publishes the reflective `final`; fast mode publishes `direct`.
    /// Interior newlines are normalized to spaces.
    private func requiredTranslation(from entry: [String: Any], qualityMode: TranslationQualityMode) -> String? {
        let field = qualityMode == .quality ? "final" : "direct"
        guard let value = entry[field] as? String else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func stripJSONMarkdown(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func httpHeaderFields(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }
}

private actor TranslationRequestThrottler {
    private var lastRequestStartedAt: Date?

    func waitIfNeeded(provider: String) async throws {
        let interval = TranslationRateLimitPolicy.minimumRequestIntervalSeconds(forProvider: provider)
        guard interval > 0 else { return }

        if let lastRequestStartedAt {
            let elapsed = Date().timeIntervalSince(lastRequestStartedAt)
            let remaining = Double(interval) - elapsed
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        lastRequestStartedAt = Date()
    }
}

private enum TranslationContentError: Error {
    case invalidJSON
    case missingContent
}

enum TranscriptionSegmentExtractor {
    /// Extracts learning segments from a DashScope Paraformer recorded-transcription payload.
    ///
    /// Preferred path: `transcripts[].sentences[]` in order, expanding each sentence's
    /// `words[]` into `TranscriptWord` (word text + begin/end + punctuation) so segments
    /// carry word-level timing (timingSource == .wordTimeline). Only when the server does
    /// not return a word array do we keep the sentence-level timestamps (timingSource ==
    /// .legacy). As a last resort (unexpected shapes) we fall back to the generic array
    /// scan the pre-word implementation used.
    static func extractSegments(from payload: Any) -> [LearningSegment] {
        if let sentences = preferredSentences(from: payload), !sentences.isEmpty {
            return sentences.enumerated().map { index, sentence in
                segmentFromSentence(sentence, sequence: index + 1)
            }
        }
        return legacyExtractSegments(from: payload)
    }

    /// Locates `transcripts[].sentences[]` in the payload, preserving sentence order.
    private static func preferredSentences(from payload: Any) -> [[String: Any]]? {
        guard let root = payload as? [String: Any] else { return nil }
        // Common shapes: root.transcripts[].sentences[] or root.transcripts[].sentences
        if let transcripts = root["transcripts"] as? [[String: Any]] {
            var sentences: [[String: Any]] = []
            for transcript in transcripts {
                if let list = transcript["sentences"] as? [[String: Any]] {
                    sentences.append(contentsOf: list)
                }
            }
            if !sentences.isEmpty { return sentences }
        }
        // Some responses nest one level deeper (results[0].transcripts[].sentences).
        if let results = root["results"] as? [[String: Any]] {
            for result in results {
                if let nested = preferredSentences(from: result), !nested.isEmpty {
                    return nested
                }
            }
        }
        return nil
    }

    private static func segmentFromSentence(_ sentence: [String: Any], sequence: Int) -> LearningSegment {
        let text = stringValue(sentence["text"] ?? sentence["sentence"] ?? sentence["transcription"]) ?? ""
        let startMS = intValue(sentence["begin_time"] ?? sentence["start_time"] ?? sentence["start_ms"]) ?? 0
        let endMS = intValue(sentence["end_time"] ?? sentence["end_ms"]) ?? startMS
        let words = extractWords(from: sentence)
        return LearningSegment(
            sequence: sequence,
            startMS: startMS,
            endMS: max(endMS, startMS + 1),
            text: text,
            learningText: text,
            speaker: stringValue(sentence["speaker"] ?? sentence["speaker_id"]),
            words: words,
            timingSource: words.isEmpty ? .legacy : .wordTimeline
        )
    }

    /// Expands `words[]` into `TranscriptWord`, preserving word text, begin/end and
    /// trailing punctuation. Word arrays may nest one level under each sentence.
    private static func extractWords(from sentence: [String: Any]) -> [TranscriptWord] {
        guard let rawWords = sentence["words"] as? [[String: Any]] else { return [] }
        return rawWords.compactMap { word in
            let text = stringValue(word["text"] ?? word["word"]) ?? ""
            guard !text.isEmpty else { return nil }
            let startMS = intValue(word["begin_time"] ?? word["start_time"] ?? word["start_ms"]) ?? 0
            let endMS = intValue(word["end_time"] ?? word["end_ms"]) ?? startMS
            let punctuation = stringValue(word["punctuation"]).map { value -> String in
                // DashScope emits punctuation as a separate leading/trailing token; keep it
                // attached to the word so sentence reconstruction and local segmentation work.
                value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return TranscriptWord(
                text: text,
                startMS: startMS,
                endMS: max(endMS, startMS + 1),
                punctuation: punctuation?.isEmpty == true ? nil : punctuation
            )
        }
    }

    /// Pre-word fallback: scan for the largest candidate array of sentence-like dicts.
    private static func legacyExtractSegments(from payload: Any) -> [LearningSegment] {
        let candidates = collectArrays(from: payload)
        let rawSegments = candidates.max(by: { $0.count < $1.count }) ?? []
        return rawSegments.enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            let text = dict["text"] as? String
                ?? dict["sentence"] as? String
                ?? dict["transcription"] as? String
                ?? dict["result"] as? String
                ?? ""
            guard !text.isEmpty else { return nil }
            let startMS = intValue(dict["start_time"] ?? dict["begin_time"] ?? dict["start_ms"]) ?? 0
            let endMS = intValue(dict["end_time"] ?? dict["end_ms"]) ?? startMS
            return LearningSegment(
                sequence: index + 1,
                startMS: startMS,
                endMS: endMS,
                text: text,
                learningText: text,
                speaker: dict["speaker"] as? String ?? dict["speaker_id"] as? String,
                timingSource: .legacy
            )
        }
    }

    private static func collectArrays(from value: Any) -> [[Any]] {
        if let dict = value as? [String: Any] {
            var arrays: [[Any]] = []
            for (key, child) in dict {
                if ["results", "segments", "sentence", "sentences"].contains(key),
                   let array = child as? [Any] {
                    arrays.append(array)
                }
                arrays.append(contentsOf: collectArrays(from: child))
            }
            return arrays
        }
        if let array = value as? [Any] {
            return array.flatMap { collectArrays(from: $0) }
        }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(Double(string) ?? 0) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

private func validateHTTP(_ response: URLResponse, context: String, responseBody: Data? = nil) throws {
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let detail = responseBody.flatMap(errorDetail(from:)) ?? ""
        throw PipelineError.badResponse("\(context) (HTTP \(status))\(detail).")
    }
}

private func errorDetail(from data: Data) -> String? {
    if let json = try? JSONSerialization.jsonObject(with: data) {
        if let detail = structuredErrorDetail(from: json) {
            return ": " + detail
        }
        if let excerpt = compactJSONExcerpt(from: json) {
            return ": " + excerpt
        }
    }
    if let text = String(data: data, encoding: .utf8) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return ": " + String(trimmed.prefix(300))
        }
    }
    return nil
}

private func structuredErrorDetail(from value: Any) -> String? {
    var parts: [String] = []
    var seen: Set<String> = []
    collectStructuredErrorDetails(from: value, into: &parts, seen: &seen)
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " / ")
}

private func collectStructuredErrorDetails(from value: Any, into parts: inout [String], seen: inout Set<String>) {
    if let dict = value as? [String: Any] {
        let code = stringValue(
            dict["code"]
                ?? dict["error_code"]
                ?? dict["errorCode"]
                ?? dict["errorCodeValue"]
                ?? dict["Code"]
        )
        let message = stringValue(
            dict["message"]
                ?? dict["error_message"]
                ?? dict["errorMessage"]
                ?? dict["Message"]
                ?? dict["reason"]
        )
        let taskID = stringValue(dict["task_id"] ?? dict["taskId"])
        let requestID = stringValue(dict["request_id"] ?? dict["requestId"] ?? dict["RequestId"])
        let failedStatus = stringValue(dict["task_status"] ?? dict["status"] ?? dict["subtask_status"])
            .map { ["FAILED", "CANCELED", "UNKNOWN"].contains($0.uppercased()) } ?? false

        var current: [String] = []
        if let code, !code.isEmpty { current.append(code) }
        if let message, !message.isEmpty { current.append(message) }
        if failedStatus {
            if let taskID, !taskID.isEmpty { current.append("task_id=\(taskID)") }
            if let requestID, !requestID.isEmpty { current.append("request_id=\(requestID)") }
        }

        let detail = current.joined(separator: " ")
        if !detail.isEmpty, seen.insert(detail).inserted {
            parts.append(detail)
        }

        for child in dict.values {
            collectStructuredErrorDetails(from: child, into: &parts, seen: &seen)
        }
        return
    }
    if let array = value as? [Any] {
        for child in array {
            collectStructuredErrorDetails(from: child, into: &parts, seen: &seen)
        }
    }
}

private func compactJSONExcerpt(from value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(500))
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let double = value as? Double { return Int(double) }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(Double(string) ?? 0) }
    return nil
}

func withNetworkRetries<T>(
    operation: String,
    maxAttempts: Int = 3,
    _ work: @escaping () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as URLError where error.isTransientNetworkError {
            if attempt >= maxAttempts {
                throw PipelineError.transientNetworkFailure(operation, maxAttempts)
            }
            try await Task.sleep(nanoseconds: UInt64(attempt * 3) * 1_000_000_000)
            attempt += 1
        } catch {
            throw error
        }
    }
}

private extension URLError {
    var isTransientNetworkError: Bool {
        switch code {
        case .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            true
        default:
            false
        }
    }
}
