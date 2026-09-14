import Foundation
import CloudSyncKit
import DomainModels
import PodcastEnglishStudioCore

protocol CloudVideoMediaResolving: Actor {
    func lookup(
        videoID: String,
        preferredHeight: Int?,
        configuration: AppConfiguration,
        forceRefresh: Bool
    ) async -> CloudVideoLookupOutcome
}

/// Resolves a YouTube video ID to a session-scoped signed cloud MP4.
/// URLs stay in-memory only and are never written to disk or logs.
actor CloudVideoMediaResolver: CloudVideoMediaResolving {
    struct CacheEntry {
        var candidate: CloudVideoPlaybackCandidate
    }

    private let clientProvider: @Sendable (AppConfiguration) -> CloudContentJobClient?
    private var cache: [String: CacheEntry] = [:]

    init(clientProvider: @escaping @Sendable (AppConfiguration) -> CloudContentJobClient?) {
        self.clientProvider = clientProvider
    }

    init() {
        self.init { configuration in
            CloudContentGatewayFactory.makeClient(configuration: configuration)
        }
    }

    func lookup(
        videoID: String,
        preferredHeight: Int?,
        configuration: AppConfiguration,
        forceRefresh: Bool = false
    ) async -> CloudVideoLookupOutcome {
        let trimmedID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return .notFound }
        // Every playback lookup reaches the server to renew the retention window.
        guard let client = clientProvider(configuration) else {
            logResult(videoID: trimmedID, mediaId: nil, result: "config-miss")
            return .notFound
        }
        let contentKey = CloudContentKeyPolicy.videoContentKey(platform: "youtube", videoID: trimmedID)
        do {
            let response = try await client.fetchVideoPlaybackURL(
                contentKey: contentKey,
                preferredHeight: preferredHeight
            )
            let candidate = CloudVideoPlaybackCandidate(
                mediaId: response.mediaId,
                contentKey: response.contentKey,
                url: response.url,
                expiresAt: response.expiresAt,
                mimeType: response.mimeType,
                bytes: response.bytes,
                sha256: response.sha256,
                durationSeconds: response.durationSeconds,
                height: response.height,
                videoCodec: response.videoCodec,
                audioCodec: response.audioCodec,
                acceptRanges: response.acceptRanges,
                mediaVersion: response.mediaVersion,
                createdAt: response.createdAt
            )
            cache[trimmedID] = CacheEntry(candidate: candidate)
            logResult(videoID: trimmedID, mediaId: candidate.mediaId, result: "hit")
            return .ready(candidate)
        } catch let error as CloudContentError {
            return mapError(error, videoID: trimmedID)
        } catch {
            logResult(videoID: trimmedID, mediaId: nil, result: "transport")
            return .transport
        }
    }

    private func mapError(_ error: CloudContentError, videoID: String) -> CloudVideoLookupOutcome {
        switch error {
        case .http(let status, let server):
            let code = server?.code
            if status == 404 || code == "MEDIA_NOT_FOUND" {
                cache[videoID] = nil
                logResult(videoID: videoID, mediaId: nil, result: "miss")
                return .notFound
            }
            if status == 409 && code == "MEDIA_NOT_READY" {
                logResult(videoID: videoID, mediaId: nil, result: "not-ready")
                return .notReady(retryAfterSeconds: server?.retryAfterSeconds)
            }
            if status == 409 && code == "MEDIA_INTEGRITY_FAILED" {
                cache[videoID] = nil
                logResult(videoID: videoID, mediaId: nil, result: "integrity")
                return .integrityFailed
            }
            if status == 401 || status == 403 {
                cache[videoID] = nil
                logResult(videoID: videoID, mediaId: nil, result: "unauthorized")
                return .unauthorized
            }
            logResult(videoID: videoID, mediaId: nil, result: "http-\(status)")
            return .transport
        case .transport:
            logResult(videoID: videoID, mediaId: nil, result: "transport")
            return .transport
        case .decoding:
            logResult(videoID: videoID, mediaId: nil, result: "decoding")
            return .decoding
        case .configuration:
            logResult(videoID: videoID, mediaId: nil, result: "config-miss")
            return .notFound
        }
    }

    private func logResult(videoID: String, mediaId: String?, result: String) {
        let digest = videoID.count <= 6 ? videoID : "\(videoID.prefix(6))…"
        print("CloudVideoMedia: video=\(digest) media=\(mediaId ?? "-") result=\(result)")
    }
}
