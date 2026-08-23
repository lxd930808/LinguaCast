import Foundation

/// Lightweight reachability check for Google Video / HLS URLs before AVPlayer install.
/// Its only job is to drop "metadata-only" formats that the media server refuses
/// without a valid GVS PO Token; anything ambiguous must keep playing.
public enum YTMediaStreamURLPreflight: Sendable {
    public static let defaultTimeout: TimeInterval = 2

    /// A probe never proves playability, so `inconclusive` and `playable` are both
    /// treated as "use it". Only `rejected` removes a candidate from selection.
    public enum Outcome: Sendable, Equatable {
        case playable
        case rejected(statusCode: Int)
        case inconclusive
    }

    /// Statuses that mean the URL is unusable for AVPlayer no matter how long it waits.
    private static let rejectedStatusCodes: Set<Int> = [401, 403, 410]

    /// Google Video can answer differently depending on who is asking, so the probe
    /// impersonates the media stack that will do the real fetching. Probing with the
    /// app's own agent produced rejections for URLs AVPlayer could still play.
    private static let mediaUserAgent =
        "AppleCoreMedia/1.0.0.21K354 (Apple TV; U; CPU OS 17_5 like Mac OS X; en_us)"

    /// Only probe real YouTube media hosts. Local/LAN/test URLs skip preflight so
    /// Debug backends and unit fixtures are never false-negatived.
    public static func shouldPreflight(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard !host.isEmpty else { return false }
        return host.contains("googlevideo.com")
            || host.contains("youtube.com")
            || host.contains("youtu.be")
            || host.hasSuffix(".google.com")
    }

    public static func probe(
        _ url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = defaultTimeout
    ) async -> Outcome {
        guard shouldPreflight(url) else { return .playable }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.setValue(mediaUserAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            if (200..<300).contains(http.statusCode) {
                return .playable
            }
            if rejectedStatusCodes.contains(http.statusCode) {
                return .rejected(statusCode: http.statusCode)
            }
            // Redirects, 5xx, throttling: not a verdict about the URL itself.
            return .inconclusive
        } catch {
            // Timeouts and transport errors must not cost the user a playable stream.
            return .inconclusive
        }
    }

    /// False only when the media server definitively refused one of the URLs.
    public static func isSourcePlayable(
        _ source: YTPlaybackSource,
        session: URLSession = .shared,
        timeout: TimeInterval = defaultTimeout
    ) async -> Bool {
        switch source {
        case .direct(let stream):
            return await isUsable(stream.url, session: session, timeout: timeout)
        case .hls:
            // A playlist is not byte-range media and its manifest host has its own
            // access rules, so a probe here says nothing about playability. AVPlayer
            // fetches and refreshes the manifest itself; let it decide.
            return true
        case .composed(let video, let audio):
            async let videoOutcome = probe(video.url, session: session, timeout: timeout)
            async let audioOutcome = probe(audio.url, session: session, timeout: timeout)
            let video = await videoOutcome
            let audio = await audioOutcome
            return !isRejected(video) && !isRejected(audio)
        }
    }

    /// URLs to exclude from the next selection attempt after a definitive rejection.
    public static func urls(in source: YTPlaybackSource) -> [URL] {
        switch source {
        case .direct(let stream):
            return [stream.url]
        case .hls(let url, _):
            return [url]
        case .composed(let video, let audio):
            return [video.url, audio.url]
        }
    }

    private static func isUsable(
        _ url: URL,
        session: URLSession,
        timeout: TimeInterval
    ) async -> Bool {
        !isRejected(await probe(url, session: session, timeout: timeout))
    }

    private static func isRejected(_ outcome: Outcome) -> Bool {
        if case .rejected = outcome { return true }
        return false
    }
}

public enum YTResolvedMediaStreamsFiltering {
    public static func excluding(
        _ resolved: YTResolvedMediaStreams,
        urls: Set<URL>
    ) -> YTResolvedMediaStreams {
        guard !urls.isEmpty else { return resolved }
        let hlsURL: URL?
        if let existing = resolved.hlsURL, urls.contains(existing) {
            hlsURL = nil
        } else {
            hlsURL = resolved.hlsURL
        }
        return YTResolvedMediaStreams(
            progressive: resolved.progressive.filter { !urls.contains($0.url) },
            videoOnly: resolved.videoOnly.filter { !urls.contains($0.url) },
            audioOnly: resolved.audioOnly.filter { !urls.contains($0.url) },
            hlsURL: hlsURL,
            expiresAt: resolved.expiresAt
        )
    }
}
