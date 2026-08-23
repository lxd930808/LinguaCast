import Foundation
import PodcastEnglishStudioCore

enum YTPlaybackBackendKind: String, Sendable {
    case officialIFrame = "iframe"
    case youTubeKit = "youtubekit"
    case localService = "local-service"
}

enum YTPlaybackBackend {
    private static let lock = NSLock()

    static func kind(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> YTPlaybackBackendKind {
        if YTLocalMediaServiceConfig.resolved(environment: environment) != nil {
            return .localService
        }
#if DEBUG
        let raw = environment["YT_PLAYBACK_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "youtubekit", "native":
            return .youTubeKit
        case "local-service":
            // Misconfigured local-service falls back to iframe rather than hanging.
            return .officialIFrame
        default:
            return .officialIFrame
        }
#else
        return .officialIFrame
#endif
    }

    private static var cachedLocalResolver: (any YTMediaStreamResolving)?
    private static var cachedConfigSignature: String?
    private static var didLogBackend = false

    /// Drop cached resolver after Settings change.
    static func resetLocalResolverCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedLocalResolver = nil
        cachedConfigSignature = nil
        didLogBackend = false
    }

    static func makeResolver(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any YTMediaStreamResolving {
        switch kind(environment: environment) {
        case .localService:
            if let config = YTLocalMediaServiceConfig.resolved(environment: environment) {
                let signature = "\(config.baseURL.absoluteString)|\(config.token)|\(config.mode.rawValue)|\(config.preferredHeight)"
                lock.lock()
                defer { lock.unlock() }
                if let cachedLocalResolver, cachedConfigSignature == signature {
                    return cachedLocalResolver
                }
#if DEBUG
                if !didLogBackend {
                    print("YTPlaybackBackend: using local-service \(config.baseURL.absoluteString) mode=\(config.mode.rawValue) height=\(config.preferredHeight)")
                    didLogBackend = true
                }
#endif
                let resolver = YTLocalMediaStreamResolver(config: config)
                cachedLocalResolver = resolver
                cachedConfigSignature = signature
                return resolver
            }
            return YTYouTubeKitMediaStreamResolver.shared
        case .youTubeKit, .officialIFrame:
            return YTYouTubeKitMediaStreamResolver.shared
        }
    }
}
