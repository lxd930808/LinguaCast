import Foundation
import PodcastEnglishStudioCore

public struct AppConfiguration: Equatable, Sendable {
    public var youtubeAPIKey: String = ""
    public var dashscopeAPIKey: String = ""
    public var translationProvider: String = "dashscope"
    public var translationAPIKey: String = ""
    public var translationBaseURL: String = TranslationProviderPolicy.defaultDeepSeekBaseURL
    public var translationModelID: String = TranslationChatRequestPolicy.defaultDeepSeekModelID
    public var translationReasoningEffort: String = TranslationChatRequestPolicy.defaultDeepSeekReasoningEffort
    public var ossAccessKeyID: String = ""
    public var ossAccessKeySecret: String = ""
    public var ossEndpoint: String = ""
    public var ossBucket: String = ""
    public var ossRegion: String = ""
    public var minimaxAPIKey: String = ""
    /// Legacy discrete font size retained only for compatibility reads. Not used for V7 rendering.
    public var subtitleFontSize: Double = Self.defaultSubtitleFontSize
    /// English subtitle size level (1–9). Primary V7 size control.
    public var subtitleEnglishSizeLevel: Int = SubtitlePresentationPreferences.defaultEnglishSizeLevel
    /// Target-language size as a percent of English (50–100, step 5).
    public var subtitleTargetScalePercent: Int = SubtitlePresentationPreferences.defaultTargetScalePercent
    /// Raw value of `SubtitleOrder`.
    public var subtitleOrder: String = SubtitleOrder.default.rawValue
    public var translationTargetLanguage: String = TranslationTargetPolicy.defaultTarget(
        preferredLanguageIdentifiers: Locale.preferredLanguages
    ).rawValue
    /// Translation depth (raw value of `TranslationQualityMode`). quality = direct→reflect→
    /// retranslate (default); fast = single direct pass. Synced across devices and shown in
    /// the iOS/tvOS settings page. Changing it only affects newly generated subtitles.
    public var translationQualityMode: String = TranslationQualityMode.default.rawValue
    // Raw value of YTStreamSelectionPolicy.storedRawValue; empty means "use the platform default".
    public var preferredVideoQuality: String = ""
    // Video playback speed; restricted to videoPlaybackRateOptions (invalid values coerce to default).
    public var videoPlaybackRate: Double = Self.defaultVideoPlaybackRate
    // Subtitle display mode for video; one of subtitleDisplayModeOptions.
    public var subtitleDisplayMode: String = Self.defaultSubtitleDisplayMode
    // Master switch for agent-driven content filtering.
    public var contentFilterEnabled: Bool = false
    // Comma/space separated keywords or channel/show names the filter should hide.
    public var contentFilterKeywords: String = ""
    // Free-form instruction passed to the filtering agent (e.g. "hide prank videos").
    public var contentFilterPrompt: String = ""
    // Whether playing audio keeps the screen awake (iOS only; read by the player view).
    public var keepScreenAwake: Bool = true
    /// Internal tolerance for high-CPS caption outliers (0–5 percent). Not shown in Settings UI.
    /// Missing/invalid stored values coerce to the default; out-of-range values clamp to 0…5.
    public var captionQualityOutlierTolerancePercent: Double =
        Self.defaultCaptionQualityOutlierTolerancePercent
    /// Raw value of `IOSYouTubePlaybackMode`. Synced across devices but only honored by iOS;
    /// tvOS ignores it and keeps its existing playback path. Missing/invalid values coerce
    /// to the official iframe.
    public var iosYouTubePlaybackMode: String = IOSYouTubePlaybackMode.default.rawValue

    public init() {}

    /// Typed accessor for `iosYouTubePlaybackMode`; normalizes stored values.
    public var youTubePlaybackMode: IOSYouTubePlaybackMode {
        get { IOSYouTubePlaybackMode.normalized(iosYouTubePlaybackMode) }
        set { iosYouTubePlaybackMode = newValue.rawValue }
    }

    public var translationTarget: TranslationTarget {
        get { TranslationTargetPolicy.normalized(translationTargetLanguage) }
        set { translationTargetLanguage = newValue.rawValue }
    }

    /// Translation depth preference; only affects newly generated subtitles.
    public var translationQuality: TranslationQualityMode {
        get { TranslationQualityMode.normalized(translationQualityMode) }
        set { translationQualityMode = newValue.rawValue }
    }

    public var subtitlePresentation: SubtitlePresentationPreferences {
        get {
            SubtitlePresentationPreferences(
                englishSizeLevel: subtitleEnglishSizeLevel,
                targetScalePercent: subtitleTargetScalePercent,
                order: SubtitleOrder.normalized(subtitleOrder)
            )
        }
        set {
            subtitleEnglishSizeLevel = SubtitlePresentationPreferences.normalizedEnglishSizeLevel(
                newValue.englishSizeLevel
            )
            subtitleTargetScalePercent = SubtitlePresentationPreferences.normalizedTargetScalePercent(
                newValue.targetScalePercent
            )
            subtitleOrder = newValue.order.rawValue
        }
    }

    public var hasRequiredGenerationKeys: Bool {
        hasDashScopeASRKey && hasTranslationKey
    }

    public var hasDashScopeASRKey: Bool {
        !dashscopeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasTranslationKey: Bool {
        !translationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static var defaultSubtitleFontSize: Double {
        #if os(tvOS)
        30
        #else
        19
        #endif
    }

    /// Legacy options retained for compatibility reads only.
    public static let subtitleFontSizeOptions: [Double] = [24, 30, 36, 42]

    public static let defaultVideoPlaybackRate: Double = 1.0
    public static let videoPlaybackRateOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    public static let defaultSubtitleDisplayMode = "bilingual"
    /// YouTube subtitle visibility modes shared by inline and fullscreen layouts.
    public static let subtitleDisplayModeOptions: [String] = ["bilingual", "englishOnly", "off"]

    public static let defaultCaptionQualityOutlierTolerancePercent: Double = 1.0
    public static let minimumCaptionQualityOutlierTolerancePercent: Double = 0.0
    public static let maximumCaptionQualityOutlierTolerancePercent: Double = 5.0

    static func videoPlaybackRate(from value: String) -> Double {
        guard let rate = Double(value), videoPlaybackRateOptions.contains(rate) else {
            return defaultVideoPlaybackRate
        }
        return rate
    }

    static func subtitleDisplayMode(from value: String) -> String {
        subtitleDisplayModeOptions.contains(value) ? value : defaultSubtitleDisplayMode
    }

    /// Coerces a stored or synced percent string into the internal 0…5 range.
    /// Empty / non-numeric values use the default (1%); out-of-range values clamp.
    static func captionQualityOutlierTolerancePercent(from value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = Double(trimmed), parsed.isFinite else {
            return defaultCaptionQualityOutlierTolerancePercent
        }
        return min(
            max(parsed, minimumCaptionQualityOutlierTolerancePercent),
            maximumCaptionQualityOutlierTolerancePercent
        )
    }

    public subscript(key: AppConfigurationKey) -> String {
        get {
            switch key {
            case .youtubeAPIKey: youtubeAPIKey
            case .dashscopeAPIKey: dashscopeAPIKey
            case .translationProvider: translationProvider
            case .translationAPIKey: translationAPIKey
            case .translationBaseURL: translationBaseURL
            case .translationModelID: translationModelID
            case .translationReasoningEffort: translationReasoningEffort
            case .ossAccessKeyID: ossAccessKeyID
            case .ossAccessKeySecret: ossAccessKeySecret
            case .ossEndpoint: ossEndpoint
            case .ossBucket: ossBucket
            case .ossRegion: ossRegion
            case .minimaxAPIKey: minimaxAPIKey
            case .subtitleFontSize: String(format: "%.0f", subtitleFontSize)
            case .subtitleEnglishSizeLevel: String(subtitleEnglishSizeLevel)
            case .subtitleTargetScalePercent: String(subtitleTargetScalePercent)
            case .subtitleOrder: subtitleOrder
            case .translationTargetLanguage: translationTargetLanguage
            case .translationQualityMode: translationQualityMode
            case .preferredVideoQuality: preferredVideoQuality
            case .videoPlaybackRate: String(format: "%g", videoPlaybackRate)
            case .subtitleDisplayMode: subtitleDisplayMode
            case .contentFilterEnabled: contentFilterEnabled ? "true" : "false"
            case .contentFilterKeywords: contentFilterKeywords
            case .contentFilterPrompt: contentFilterPrompt
            case .keepScreenAwake: keepScreenAwake ? "true" : "false"
            case .captionQualityOutlierTolerancePercent:
                String(format: "%g", captionQualityOutlierTolerancePercent)
            case .iosYouTubePlaybackMode: iosYouTubePlaybackMode
            }
        }
        set {
            switch key {
            case .youtubeAPIKey: youtubeAPIKey = newValue
            case .dashscopeAPIKey: dashscopeAPIKey = newValue
            case .translationProvider: translationProvider = newValue
            case .translationAPIKey: translationAPIKey = newValue
            case .translationBaseURL: translationBaseURL = newValue
            case .translationModelID: translationModelID = newValue
            case .translationReasoningEffort: translationReasoningEffort = newValue
            case .ossAccessKeyID: ossAccessKeyID = newValue
            case .ossAccessKeySecret: ossAccessKeySecret = newValue
            case .ossEndpoint: ossEndpoint = newValue
            case .ossBucket: ossBucket = newValue
            case .ossRegion: ossRegion = newValue
            case .minimaxAPIKey: minimaxAPIKey = newValue
            case .subtitleFontSize:
                if let size = Double(newValue), Self.subtitleFontSizeOptions.contains(size) {
                    subtitleFontSize = size
                }
            case .subtitleEnglishSizeLevel:
                subtitleEnglishSizeLevel = SubtitlePresentationPreferences.normalizedEnglishSizeLevel(
                    from: newValue
                )
            case .subtitleTargetScalePercent:
                subtitleTargetScalePercent = SubtitlePresentationPreferences.normalizedTargetScalePercent(
                    from: newValue
                )
            case .subtitleOrder:
                subtitleOrder = SubtitleOrder.normalized(newValue).rawValue
            case .translationTargetLanguage:
                translationTargetLanguage = TranslationTargetPolicy.normalized(newValue).rawValue
            case .translationQualityMode:
                translationQualityMode = TranslationQualityMode.normalized(newValue).rawValue
            case .preferredVideoQuality:
                preferredVideoQuality = newValue
            case .videoPlaybackRate:
                videoPlaybackRate = Self.videoPlaybackRate(from: newValue)
            case .subtitleDisplayMode:
                subtitleDisplayMode = Self.subtitleDisplayMode(from: newValue)
            case .contentFilterEnabled:
                contentFilterEnabled = Self.bool(from: newValue)
            case .contentFilterKeywords:
                contentFilterKeywords = newValue
            case .contentFilterPrompt:
                contentFilterPrompt = newValue
            case .keepScreenAwake:
                keepScreenAwake = Self.bool(from: newValue)
            case .captionQualityOutlierTolerancePercent:
                captionQualityOutlierTolerancePercent =
                    Self.captionQualityOutlierTolerancePercent(from: newValue)
            case .iosYouTubePlaybackMode:
                iosYouTubePlaybackMode = IOSYouTubePlaybackMode.normalized(newValue).rawValue
            }
        }
    }

    private static func bool(from value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "on": true
        default: false
        }
    }
}

public enum AppConfigurationKey: String, CaseIterable, Sendable {
    case youtubeAPIKey
    case dashscopeAPIKey
    case translationProvider
    case translationAPIKey
    case translationBaseURL
    case translationModelID
    case translationReasoningEffort
    case ossAccessKeyID
    case ossAccessKeySecret
    case ossEndpoint
    case ossBucket
    case ossRegion
    case minimaxAPIKey
    case subtitleFontSize
    case subtitleEnglishSizeLevel
    case subtitleTargetScalePercent
    case subtitleOrder
    case translationTargetLanguage
    case translationQualityMode
    case preferredVideoQuality
    case videoPlaybackRate
    case subtitleDisplayMode
    case contentFilterEnabled
    case contentFilterKeywords
    case contentFilterPrompt
    case keepScreenAwake
    case captionQualityOutlierTolerancePercent
    case iosYouTubePlaybackMode

    public static let translationGroup: Set<Self> = [
        .translationProvider,
        .translationBaseURL,
        .translationModelID,
        .translationReasoningEffort
    ]

    /// Non-secret settings accepted by the short-lived local setup page.
    public static let mobileSetupAllowedKeys: Set<Self> = [
        .translationProvider,
        .translationBaseURL,
        .translationModelID,
        .translationReasoningEffort,
        .ossEndpoint,
        .ossBucket,
        .ossRegion
    ]

    /// Keys that participate in the Settings draft/commit workflow for subtitle presentation.
    public static let subtitlePresentationGroup: Set<Self> = [
        .subtitleEnglishSizeLevel,
        .subtitleTargetScalePercent,
        .subtitleOrder,
        .subtitleDisplayMode
    ]

    public var isSecret: Bool {
        switch self {
        case .youtubeAPIKey, .dashscopeAPIKey, .translationAPIKey,
             .ossAccessKeyID, .ossAccessKeySecret, .minimaxAPIKey:
            true
        default:
            false
        }
    }
}
