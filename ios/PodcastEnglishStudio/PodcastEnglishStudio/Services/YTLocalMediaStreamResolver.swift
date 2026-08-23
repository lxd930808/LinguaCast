import Foundation
import PodcastEnglishStudioCore

/// Resolves YouTube playback through the Mac-local SABR media service.
actor YTLocalMediaStreamResolver: YTMediaStreamResolving {
    private let client: YTLocalMediaServiceClient
    private let config: YTLocalMediaServiceConfig
    private var cache: [String: YTResolvedMediaStreams] = [:]
    private var inFlight: [String: Task<YTResolvedMediaStreams, Error>] = [:]
    private var activeJobByVideo: [String: String] = [:]

    init(config: YTLocalMediaServiceConfig, client: YTLocalMediaServiceClient? = nil) {
        self.config = config
        self.client = client ?? YTLocalMediaServiceClient(config: config)
    }

    func resolve(videoID: String) async throws -> YTResolvedMediaStreams {
        if let cached = cache[videoID], !cached.isExpired {
            return cached
        }
        if let existing = inFlight[videoID] {
            return try await existing.value
        }

        let task = Task<YTResolvedMediaStreams, Error> {
            try await self.fetch(videoID: videoID)
        }
        inFlight[videoID] = task
        defer { inFlight[videoID] = nil }

        do {
            let streams = try await task.value
            cache[videoID] = streams
            return streams
        } catch {
            let mapped = mapError(error)
#if DEBUG
            print("YTLocalMediaStreamResolver: failed videoID=\(videoID) error=\(mapped.localizedDescription)")
#endif
            throw mapped
        }
    }

    func invalidate(videoID: String) async {
        inFlight[videoID]?.cancel()
        inFlight[videoID] = nil
        if let jobID = activeJobByVideo[videoID] {
            await client.deleteJob(jobID: jobID)
            activeJobByVideo[videoID] = nil
        }
        cache[videoID] = nil
    }

    private func fetch(videoID: String) async throws -> YTResolvedMediaStreams {
#if DEBUG
        print("YTLocalMediaStreamResolver: preparing \(videoID) via \(config.baseURL.host ?? "?") mode=\(config.mode.rawValue)")
#endif
        let prepared = try await client.prepare(
            videoID: videoID,
            mode: config.mode,
            preferredHeight: config.preferredHeight
        )
        activeJobByVideo[videoID] = prepared.jobId

        let job = try await client.waitForJob(jobID: prepared.jobId)
        guard let playback = job.playback else {
            throw YTLocalMediaServiceError.invalidResponse
        }

#if DEBUG
        print(
            "YTLocalMediaStreamResolver: ready kind=\(playback.kind.rawValue) height=\(playback.height.map(String.init) ?? "?") codec=\(playback.videoCodec ?? "?")"
        )
#endif

        return mapPlayback(playback)
    }

    private func mapPlayback(_ playback: YTLocalMediaPlaybackInfo) -> YTResolvedMediaStreams {
        switch playback.kind {
        case .hls:
            return YTResolvedMediaStreams(
                progressive: [],
                videoOnly: [],
                audioOnly: [],
                hlsURL: playback.url,
                expiresAt: Date().addingTimeInterval(5 * 60 * 60)
            )
        case .mp4:
            let stream = YTMediaStream(
                id: "local-mp4-\(playback.itagVideo ?? 0)",
                url: playback.url,
                itag: playback.itagVideo ?? 0,
                height: playback.height,
                bitrate: nil,
                averageBitrate: nil,
                videoCodec: .avc1,
                audioCodec: .mp4a,
                videoCodecRaw: playback.videoCodec,
                audioCodecRaw: playback.audioCodec,
                container: "mp4",
                kind: .progressive,
                isNativelyPlayable: true
            )
            return YTResolvedMediaStreams(
                progressive: [stream],
                videoOnly: [],
                audioOnly: [],
                hlsURL: nil,
                expiresAt: Date().addingTimeInterval(5 * 60 * 60)
            )
        }
    }

    private func mapError(_ error: Error) -> YTMediaStreamResolverError {
        if let local = error as? YTLocalMediaServiceError {
            switch local {
            case .cancelled:
                return .extractionFailed("Local media job cancelled.")
            case .timedOut:
                return .extractionFailed("Local media job timed out.")
            case .backend(let code, let message):
                switch code {
                case .mediaExpired:
                    return .expired
                case .unauthorized:
                    return .remoteForbidden
                default:
                    return .extractionFailed(message ?? code.rawValue)
                }
            case .httpStatus, .invalidConfiguration, .invalidResponse:
                return .extractionFailed(local.localizedDescription)
            }
        }
        if error is CancellationError {
            return .extractionFailed("Local media job cancelled.")
        }
        return .extractionFailed(error.localizedDescription)
    }
}
