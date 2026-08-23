import Foundation
import Network
import PodcastEnglishStudioCore
import YouTubeKit

/// Shared YouTube stream resolver with local YouTubeKit extraction, an iOS InnerTube
/// HLS probe, single-flight request coalescing, and a short-lived cache.
actor YTYouTubeKitMediaStreamResolver: YTMediaStreamResolving {
    static let shared = YTYouTubeKitMediaStreamResolver()
    private static let hlsGraceNanoseconds: UInt64 = 300_000_000

    private enum CacheFlightStage {
        case initial
        case enrichment
    }

    private struct CacheEntry {
        var streams: YTResolvedMediaStreams
        var inFlight: Task<YTResolvedMediaStreams, Error>?
        var generation: UUID
        var flightStage: CacheFlightStage?
    }

    private enum FetchEvent: Sendable {
        case hls(URL?)
        case streams(Result<[YTMediaStream], YTMediaStreamResolverError>)
        case hlsGraceExpired
    }

    private var cache: [String: CacheEntry] = [:]

    func resolve(videoID: String) async throws -> YTResolvedMediaStreams {
        if let entry = cache[videoID] {
            if let inFlight = entry.inFlight {
                return try await consume(
                    inFlight: inFlight,
                    videoID: videoID,
                    generation: entry.generation,
                    stage: entry.flightStage ?? .initial
                )
            }
            if !entry.streams.isExpired {
                return entry.streams
            }
            cache[videoID] = nil
        }

        let generation = UUID()
        let task = Task<YTResolvedMediaStreams, Error> {
            try await Self.fetch(videoID: videoID)
        }
        cache[videoID] = CacheEntry(streams: YTResolvedMediaStreams(
            progressive: [],
            videoOnly: [],
            audioOnly: [],
            hlsURL: nil,
            expiresAt: nil
        ), inFlight: task, generation: generation, flightStage: .initial)
        return try await consume(
            inFlight: task,
            videoID: videoID,
            generation: generation,
            stage: .initial
        )
    }

    func invalidate(videoID: String) async {
        cache[videoID]?.inFlight?.cancel()
        cache[videoID] = nil
    }

    private func consume(
        inFlight: Task<YTResolvedMediaStreams, Error>,
        videoID: String,
        generation: UUID,
        stage: CacheFlightStage
    ) async throws -> YTResolvedMediaStreams {
        do {
            let streams = try await inFlight.value
            guard cache[videoID]?.generation == generation else {
                return streams
            }

            switch stage {
            case .initial:
                if let hlsURL = streams.hlsURL,
                   streams.progressive.isEmpty,
                   streams.videoOnly.isEmpty,
                   streams.audioOnly.isEmpty {
                    let enrichmentGeneration = UUID()
                    let enrichment = Task<YTResolvedMediaStreams, Error> {
                        await Self.fetchYouTubeKitStreams(videoID: videoID, hlsURL: hlsURL)
                    }
                    cache[videoID] = CacheEntry(
                        streams: streams,
                        inFlight: enrichment,
                        generation: enrichmentGeneration,
                        flightStage: .enrichment
                    )
                } else {
                    cache[videoID] = CacheEntry(
                        streams: streams,
                        inFlight: nil,
                        generation: generation,
                        flightStage: nil
                    )
                }
                Self.logResolveSuccess(videoID: videoID, streams: streams)

            case .enrichment:
                cache[videoID] = CacheEntry(
                    streams: streams,
                    inFlight: nil,
                    generation: generation,
                    flightStage: nil
                )
            }
            return streams
        } catch {
            if cache[videoID]?.generation == generation {
                cache[videoID] = nil
            }
            if case .initial = stage {
                Self.logResolveFailure(videoID: videoID, error: error)
            }
            throw error
        }
    }

    private static func fetch(videoID: String) async throws -> YTResolvedMediaStreams {
        let (events, continuation) = AsyncStream<FetchEvent>.makeStream()
        let hlsTask = Task {
            let url = try? await YTInnerTubeHLSResolver().resolve(videoID: videoID)
            continuation.yield(.hls(url))
        }
        let streamsTask = Task {
            do {
                let youtube = YouTube(videoID: videoID, methods: [.local])
                let streams = try await youtube.streams.compactMap(Self.mapStream)
                continuation.yield(.streams(.success(streams)))
            } catch {
                continuation.yield(.streams(.failure(Self.mapError(error))))
            }
        }
        var graceTask: Task<Void, Never>?
        defer {
            hlsTask.cancel()
            streamsTask.cancel()
            graceTask?.cancel()
            continuation.finish()
        }

        var iterator = events.makeAsyncIterator()
        var streamsResult: Result<[YTMediaStream], YTMediaStreamResolverError>?
        var hlsProbeFinished = false
        while let event = await iterator.next() {
            switch event {
            case .hls(let url):
                hlsProbeFinished = true
                if let url {
                    print("YTMediaStreamResolver: iOS InnerTube HLS available videoID=\(videoID)")
                    return makeResolvedStreams(mapped: [], hlsURL: url)
                }
                if let streamsResult {
                    return try finishFetch(streamsResult: streamsResult)
                }

            case .streams(let result):
                streamsResult = result
                if hlsProbeFinished {
                    return try finishFetch(streamsResult: result)
                }
                if case .success(let streams) = result, !streams.isEmpty {
                    graceTask = Task {
                        try? await Task.sleep(nanoseconds: hlsGraceNanoseconds)
                        guard !Task.isCancelled else { return }
                        continuation.yield(.hlsGraceExpired)
                    }
                }

            case .hlsGraceExpired:
                guard let streamsResult else { continue }
                return try finishFetch(streamsResult: streamsResult)
            }
        }

        throw YTMediaStreamResolverError.noPlayableStream
    }

    private static func finishFetch(
        streamsResult: Result<[YTMediaStream], YTMediaStreamResolverError>
    ) throws -> YTResolvedMediaStreams {
        let mapped: [YTMediaStream]
        switch streamsResult {
        case .success(let streams):
            mapped = streams
        case .failure(let error):
            throw error
        }

        guard !mapped.isEmpty else {
            throw YTMediaStreamResolverError.noPlayableStream
        }
        return makeResolvedStreams(mapped: mapped, hlsURL: nil)
    }

    private static func fetchYouTubeKitStreams(
        videoID: String,
        hlsURL: URL
    ) async -> YTResolvedMediaStreams {
        do {
            let youtube = YouTube(videoID: videoID, methods: [.local])
            let mapped = try await youtube.streams.compactMap(Self.mapStream)
            return makeResolvedStreams(mapped: mapped, hlsURL: hlsURL)
        } catch {
            return makeResolvedStreams(mapped: [], hlsURL: hlsURL)
        }
    }

    private static func makeResolvedStreams(
        mapped: [YTMediaStream],
        hlsURL: URL?
    ) -> YTResolvedMediaStreams {
        let progressive = mapped.filter { $0.kind == .progressive }
        let videoOnly = mapped.filter { $0.kind == .videoOnly }
        let audioOnly = mapped.filter { $0.kind == .audioOnly }
        let expiresAt = YTMediaStreamURLExpiry.earliestExpiry(in: mapped, hlsURL: hlsURL)
        return YTResolvedMediaStreams(
            progressive: progressive,
            videoOnly: videoOnly,
            audioOnly: audioOnly,
            hlsURL: hlsURL,
            expiresAt: expiresAt
        )
    }

    private static func mapStream(_ stream: YouTubeKit.Stream) -> YTMediaStream? {
        let itag = itagNumber(from: stream.url) ?? 0
        let container = stream.fileExtension.rawValue
        let videoCodec = mapVideoCodec(stream.videoCodec)
        let audioCodec = mapAudioCodec(stream.audioCodec)
        let kind: YTMediaStream.Kind
        if stream.includesVideoAndAudioTrack {
            kind = .progressive
        } else if stream.includesVideoTrack {
            kind = .videoOnly
        } else if stream.includesAudioTrack {
            kind = .audioOnly
        } else {
            return nil
        }

        return YTMediaStream(
            id: "\(itag)-\(kind.rawValue)-\(stream.url.absoluteString.hashValue)",
            url: stream.url,
            itag: itag,
            height: stream.videoResolution,
            bitrate: stream.bitrate,
            averageBitrate: stream.averageBitrate,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            videoCodecRaw: describeVideoCodec(stream.videoCodec),
            audioCodecRaw: describeAudioCodec(stream.audioCodec),
            container: container,
            kind: kind,
            isNativelyPlayable: stream.isNativelyPlayable
        )
    }

    private static func itagNumber(from url: URL) -> Int? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let raw = items.first(where: { $0.name.lowercased() == "itag" })?.value {
            return Int(raw)
        }
        return nil
    }

    private static func mapVideoCodec(_ codec: VideoCodec?) -> YTMediaStream.VideoCodecKind? {
        guard let codec else { return nil }
        if codec == .avc1 { return .avc1 }
        if codec == .av1 { return .av1 }
        if codec == .vp9 { return .vp9 }
        return .other
    }

    private static func mapAudioCodec(_ codec: AudioCodec?) -> YTMediaStream.AudioCodecKind? {
        guard let codec else { return nil }
        if codec == .mp4a { return .mp4a }
        if codec == .opus { return .opus }
        return .other
    }

    private static func describeVideoCodec(_ codec: VideoCodec?) -> String? {
        guard let codec else { return nil }
        if codec == .avc1 { return "avc1" }
        if codec == .av1 { return "av1" }
        if codec == .vp9 { return "vp9" }
        return "other"
    }

    private static func describeAudioCodec(_ codec: AudioCodec?) -> String? {
        guard let codec else { return nil }
        if codec == .mp4a { return "mp4a" }
        if codec == .opus { return "opus" }
        return "other"
    }

    private static func mapError(_ error: Error) -> YTMediaStreamResolverError {
        let text = error.localizedDescription.lowercased()
        if text.contains("429") || text.contains("rate") {
            return YTMediaStreamResolverError.rateLimited
        }
        if text.contains("403") || text.contains("forbidden") {
            return YTMediaStreamResolverError.remoteForbidden
        }
        if text.contains("410") || text.contains("gone") || text.contains("expir") {
            return YTMediaStreamResolverError.expired
        }
        return YTMediaStreamResolverError.extractionFailed(error.localizedDescription)
    }

    private static func logResolveSuccess(videoID: String, streams: YTResolvedMediaStreams) {
        let heights = (streams.videoOnly + streams.progressive).compactMap(\.height)
        let maxHeight = heights.max() ?? 0
        print(
            "YTMediaStreamResolver: resolved videoID=\(videoID) progressive=\(streams.progressive.count) videoOnly=\(streams.videoOnly.count) audioOnly=\(streams.audioOnly.count) hls=\(streams.hlsURL != nil) maxHeight=\(maxHeight)"
        )
    }

    private static func logResolveFailure(videoID: String, error: Error) {
        let kind: String
        if let typed = error as? YTMediaStreamResolverError {
            switch typed {
            case .noPlayableStream: kind = "noPlayableStream"
            case .rateLimited: kind = "rateLimited"
            case .expired: kind = "expired"
            case .remoteForbidden: kind = "remoteForbidden"
            case .extractionFailed: kind = "extractionFailed"
            }
        } else {
            kind = "unknown"
        }
        print("YTMediaStreamResolver: failed videoID=\(videoID) failureType=\(kind)")
    }
}

/// Observes path changes for Wi‑Fi vs cellular quality caps.
@MainActor
@Observable
final class YTPlaybackNetworkMonitor {
    static let shared = YTPlaybackNetworkMonitor()

    private(set) var kind: YTPlaybackNetworkKind = .other
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "YTPlaybackNetworkMonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let next: YTPlaybackNetworkKind
            if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                next = .wifi
            } else if path.usesInterfaceType(.cellular) {
                next = .cellular
            } else if path.status == .satisfied {
                next = .wifi
            } else {
                next = .other
            }
            Task { @MainActor in
                self?.kind = next
            }
        }
        monitor.start(queue: queue)
    }
}
