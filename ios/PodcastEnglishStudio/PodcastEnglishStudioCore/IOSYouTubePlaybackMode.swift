import Foundation

/// iOS YouTube playback experience stored in `AppConfiguration`. The value syncs across
/// devices through the existing settings pipeline, but only iOS honors it; tvOS ignores
/// the stored value and keeps its existing native playback path.
public enum IOSYouTubePlaybackMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// YouTube's official iframe player. Default and the only option shown in Settings.
    case officialIFrame = "official_iframe"
    /// Hidden "server subscription" option mapping to the Mac local media service.
    /// Debug builds can still enable it through the `YT_PLAYBACK_BACKEND=local-service`
    /// environment configuration; Release always uses the official iframe.
    case localService = "local_service"

    public static let `default`: IOSYouTubePlaybackMode = .officialIFrame

    /// Options shown in the Settings picker. The local-service backend stays hidden.
    public static let uiVisibleCases: [IOSYouTubePlaybackMode] = [.officialIFrame]

    /// Missing or invalid stored values fall back to the official iframe.
    public static func normalized(_ rawValue: String?) -> IOSYouTubePlaybackMode {
        guard let rawValue,
              let mode = IOSYouTubePlaybackMode(
                rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              )
        else { return .default }
        return mode
    }

    /// Effective playback experience for this device, resolved from the committed
    /// (saved) configuration so unsaved Settings drafts never affect playback.
    /// - tvOS always returns `.officialIFrame` (the field is ignored there).
    /// - Release always returns `.officialIFrame`.
    /// - Debug keeps the existing environment opt-in for the Mac local media service;
    ///   a stored `.localService` preference without a valid server configuration
    ///   falls back to the official iframe.
    public static func effective(
        configured: IOSYouTubePlaybackMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IOSYouTubePlaybackMode {
        #if os(tvOS)
        return .officialIFrame
        #elseif DEBUG
        if YTLocalMediaServiceConfig.fromProcessEnvironment(environment: environment) != nil {
            return .localService
        }
        return configured == .localService ? .officialIFrame : configured
        #else
        return .officialIFrame
        #endif
    }

    /// First-pass caption acceptance for this playback mode. iOS official-iframe
    /// playback accepts any caption track that parses into non-empty segments (timeline
    /// quality is still enforced by the final publish gate); the local-service backend
    /// — and tvOS, which ignores the setting — keep the existing strict gate.
    public var captionIngestionPolicy: YTCaptionIngestionPolicy {
        #if os(tvOS)
        return .strict
        #else
        switch self {
        case .officialIFrame:
            return .acceptParseableContent
        case .localService:
            return .strict
        }
        #endif
    }
}
