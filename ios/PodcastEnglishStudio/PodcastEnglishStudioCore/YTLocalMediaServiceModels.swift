import Foundation

public enum YTLocalMediaMode: String, Sendable, Codable, Equatable {
    case mp4
    case hls
}

public enum YTLocalMediaJobStatus: String, Sendable, Codable, Equatable {
    case queued
    case resolving
    case fetching
    case packaging
    case ready
    case failed
}

public enum YTLocalMediaErrorCode: String, Sendable, Codable, Equatable {
    case videoUnavailable = "VIDEO_UNAVAILABLE"
    case sabrRequestFailed = "SABR_REQUEST_FAILED"
    case sabrParseFailed = "SABR_PARSE_FAILED"
    case unsupportedCodec = "UNSUPPORTED_CODEC"
    case ffmpegFailed = "FFMPEG_FAILED"
    case mediaExpired = "MEDIA_EXPIRED"
    case invalidVideoID = "INVALID_VIDEO_ID"
    case internalError = "INTERNAL_ERROR"
    case unauthorized = "UNAUTHORIZED"
    case jobNotFound = "JOB_NOT_FOUND"
    case invalidJSON = "INVALID_JSON"
    case diskFull = "DISK_FULL"
    case busy = "BUSY"
    case unknown
}

public struct YTLocalMediaPrepareResponse: Sendable, Codable, Equatable {
    public let jobId: String
    public let status: YTLocalMediaJobStatus
    public let statusUrl: String

    public init(jobId: String, status: YTLocalMediaJobStatus, statusUrl: String) {
        self.jobId = jobId
        self.status = status
        self.statusUrl = statusUrl
    }
}

public struct YTLocalMediaPlaybackInfo: Sendable, Codable, Equatable {
    public let kind: YTLocalMediaMode
    public let url: URL
    public let audioURL: URL?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let durationSeconds: Double?
    public let itagVideo: Int?
    public let itagAudio: Int?

    public init(
        kind: YTLocalMediaMode,
        url: URL,
        audioURL: URL? = nil,
        height: Int?,
        videoCodec: String?,
        audioCodec: String?,
        durationSeconds: Double?,
        itagVideo: Int?,
        itagAudio: Int?
    ) {
        self.kind = kind
        self.url = url
        self.audioURL = audioURL
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.durationSeconds = durationSeconds
        self.itagVideo = itagVideo
        self.itagAudio = itagAudio
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case audioURL = "audioUrl"
        case height
        case videoCodec
        case audioCodec
        case durationSeconds
        case itagVideo
        case itagAudio
    }
}

public struct YTLocalMediaJobResponse: Sendable, Codable, Equatable {
    public let jobId: String
    public let videoId: String
    public let mode: YTLocalMediaMode
    public let preferredHeight: Int
    public let status: YTLocalMediaJobStatus
    public let progress: Double
    public let errorCode: YTLocalMediaErrorCode?
    public let errorMessage: String?
    public let playback: YTLocalMediaPlaybackInfo?

    public init(
        jobId: String,
        videoId: String,
        mode: YTLocalMediaMode,
        preferredHeight: Int,
        status: YTLocalMediaJobStatus,
        progress: Double,
        errorCode: YTLocalMediaErrorCode?,
        errorMessage: String?,
        playback: YTLocalMediaPlaybackInfo?
    ) {
        self.jobId = jobId
        self.videoId = videoId
        self.mode = mode
        self.preferredHeight = preferredHeight
        self.status = status
        self.progress = progress
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.playback = playback
    }
}

public struct YTLocalMediaServiceConfig: Sendable, Equatable {
    public let baseURL: URL
    public let token: String
    public let mode: YTLocalMediaMode
    public let preferredHeight: Int

    public init(
        baseURL: URL,
        token: String,
        mode: YTLocalMediaMode = .mp4,
        preferredHeight: Int = 720
    ) {
        self.baseURL = baseURL
        self.token = token
        self.mode = mode
        self.preferredHeight = preferredHeight
    }

    private static let defaultsPrefix = "yt.localMedia."

    /// Persist Debug/tvOS Settings values. Pass nil fields to clear.
    public static func saveUserDefaults(
        enabled: Bool,
        baseURLString: String?,
        token: String?,
        mode: YTLocalMediaMode?,
        preferredHeight: Int?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: defaultsPrefix + "enabled")
        if let baseURLString {
            defaults.set(baseURLString, forKey: defaultsPrefix + "baseURL")
        } else {
            defaults.removeObject(forKey: defaultsPrefix + "baseURL")
        }
        if let token {
            defaults.set(token, forKey: defaultsPrefix + "token")
        } else {
            defaults.removeObject(forKey: defaultsPrefix + "token")
        }
        if let mode {
            defaults.set(mode.rawValue, forKey: defaultsPrefix + "mode")
        } else {
            defaults.removeObject(forKey: defaultsPrefix + "mode")
        }
        if let preferredHeight {
            defaults.set(preferredHeight, forKey: defaultsPrefix + "preferredHeight")
        } else {
            defaults.removeObject(forKey: defaultsPrefix + "preferredHeight")
        }
    }

    public static func loadUserDefaults(
        defaults: UserDefaults = .standard
    ) -> (enabled: Bool, baseURLString: String, token: String, mode: YTLocalMediaMode, preferredHeight: Int) {
        let enabled = defaults.bool(forKey: defaultsPrefix + "enabled")
        let baseURLString = defaults.string(forKey: defaultsPrefix + "baseURL") ?? ""
        let token = defaults.string(forKey: defaultsPrefix + "token") ?? ""
        let modeRaw = defaults.string(forKey: defaultsPrefix + "mode") ?? "mp4"
        let mode = YTLocalMediaMode(rawValue: modeRaw) ?? .mp4
        let height = defaults.object(forKey: defaultsPrefix + "preferredHeight") as? Int ?? 720
        return (enabled, baseURLString, token, mode, max(144, height))
    }

    /// Parses mobile QR-setup form fields. Empty values mean "leave unchanged".
    public static func mobileSetupPatch(
        from form: [String: String]
    ) -> (
        hasChanges: Bool,
        enabled: Bool?,
        baseURLString: String?,
        token: String?,
        mode: YTLocalMediaMode?,
        preferredHeight: Int?
    ) {
        let enabledRaw = form["localMediaEnabled"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let enabled: Bool? = switch enabledRaw.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }

        let baseURL = form["localMediaBaseURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = form["localMediaToken"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modeRaw = form["localMediaMode"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mode = modeRaw.isEmpty ? nil : YTLocalMediaMode(rawValue: modeRaw)
        let heightRaw = form["localMediaPreferredHeight"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let height = Int(heightRaw).map { max(144, $0) }

        let hasChanges =
            enabled != nil
            || !baseURL.isEmpty
            || !token.isEmpty
            || mode != nil
            || height != nil

        return (
            hasChanges,
            enabled,
            baseURL.isEmpty ? nil : baseURL,
            token.isEmpty ? nil : token,
            mode,
            height
        )
    }

    /// Merges a mobile-setup patch into UserDefaults. Empty/nil fields keep existing values.
    @discardableResult
    public static func applyMobileSetupPatch(
        from form: [String: String],
        defaults: UserDefaults = .standard
    ) -> Bool {
        let patch = mobileSetupPatch(from: form)
        guard patch.hasChanges else { return false }
        let current = loadUserDefaults(defaults: defaults)
        saveUserDefaults(
            enabled: patch.enabled ?? current.enabled,
            baseURLString: patch.baseURLString ?? current.baseURLString,
            token: patch.token ?? current.token,
            mode: patch.mode ?? current.mode,
            preferredHeight: patch.preferredHeight ?? current.preferredHeight,
            defaults: defaults
        )
        return true
    }

    /// Resolves config from UserDefaults (Settings) first, then process environment.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> YTLocalMediaServiceConfig? {
        let stored = loadUserDefaults(defaults: defaults)
        if stored.enabled,
           let baseURL = URL(string: stored.baseURLString),
           let scheme = baseURL.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           baseURL.host != nil,
           !stored.token.isEmpty
        {
            return YTLocalMediaServiceConfig(
                baseURL: baseURL,
                token: stored.token,
                mode: stored.mode,
                preferredHeight: stored.preferredHeight
            )
        }
        return fromProcessEnvironment(environment: environment)
    }

    /// Debug-only configuration from process environment.
    /// Returns nil unless `YT_PLAYBACK_BACKEND=local-service` and URL/token are present.
    public static func fromProcessEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> YTLocalMediaServiceConfig? {
#if DEBUG
        let backend = environment["YT_PLAYBACK_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard backend == "local-service" else { return nil }

        guard
            let rawURL = environment["YT_LOCAL_MEDIA_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty,
            let baseURL = URL(string: rawURL),
            let scheme = baseURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            baseURL.host != nil
        else {
            return nil
        }

        let token = environment["YT_LOCAL_MEDIA_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }

        let modeRaw = environment["YT_LOCAL_MEDIA_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mode = YTLocalMediaMode(rawValue: modeRaw ?? "mp4") ?? .mp4
        let height = Int(environment["YT_LOCAL_MEDIA_PREFERRED_HEIGHT"] ?? "") ?? 720

        return YTLocalMediaServiceConfig(
            baseURL: baseURL,
            token: token,
            mode: mode,
            preferredHeight: max(144, height)
        )
#else
        return nil
#endif
    }
}

public enum YTLocalMediaServiceError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case httpStatus(Int)
    case backend(YTLocalMediaErrorCode, String?)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Local media service configuration is invalid."
        case .invalidResponse:
            "Local media service returned an invalid response."
        case .httpStatus(let code):
            "Local media service HTTP \(code)."
        case .backend(let code, let message):
            if let message, !message.isEmpty {
                "Local media service failed (\(code.rawValue)): \(message)"
            } else {
                "Local media service failed (\(code.rawValue))."
            }
        case .timedOut:
            "Local media service job timed out."
        case .cancelled:
            "Local media service request was cancelled."
        }
    }
}
