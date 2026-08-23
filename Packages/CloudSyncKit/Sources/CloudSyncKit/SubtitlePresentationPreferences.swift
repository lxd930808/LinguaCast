import Foundation

/// Vertical order of bilingual subtitle lines.
public enum SubtitleOrder: String, CaseIterable, Sendable, Equatable {
    case englishFirst
    case targetFirst

    public static let `default` = SubtitleOrder.englishFirst

    public static func normalized(_ rawValue: String) -> SubtitleOrder {
        SubtitleOrder(rawValue: rawValue) ?? .default
    }
}

/// Platform used when resolving absolute subtitle point sizes.
public enum SubtitleSizePlatform: Sendable, Equatable {
    case iOS
    case tvOS

    public static var current: SubtitleSizePlatform {
        #if os(tvOS)
        .tvOS
        #else
        .iOS
        #endif
    }

    public var englishPointSizes: [Double] {
        switch self {
        case .iOS: [16, 18, 20, 22, 24, 26, 28, 30, 32]
        case .tvOS: [24, 27, 30, 33, 36, 39, 42, 45, 48]
        }
    }

    public var minimumTargetPointSize: Double {
        switch self {
        case .iOS: 12
        case .tvOS: 18
        }
    }
}

/// Shared bilingual subtitle presentation preferences used by Settings and players.
public struct SubtitlePresentationPreferences: Equatable, Sendable {
    public static let defaultEnglishSizeLevel = 3
    public static let defaultTargetScalePercent = 75
    public static let minimumEnglishSizeLevel = 1
    public static let maximumEnglishSizeLevel = 9
    public static let minimumTargetScalePercent = 50
    public static let maximumTargetScalePercent = 100
    public static let targetScalePercentStep = 5

    public var englishSizeLevel: Int
    public var targetScalePercent: Int
    public var order: SubtitleOrder

    public static let `default` = SubtitlePresentationPreferences(
        englishSizeLevel: defaultEnglishSizeLevel,
        targetScalePercent: defaultTargetScalePercent,
        order: .default
    )

    public init(
        englishSizeLevel: Int = defaultEnglishSizeLevel,
        targetScalePercent: Int = defaultTargetScalePercent,
        order: SubtitleOrder = .default
    ) {
        self.englishSizeLevel = Self.normalizedEnglishSizeLevel(englishSizeLevel)
        self.targetScalePercent = Self.normalizedTargetScalePercent(targetScalePercent)
        self.order = order
    }

    public static func normalizedEnglishSizeLevel(_ value: Int) -> Int {
        min(maximumEnglishSizeLevel, max(minimumEnglishSizeLevel, value))
    }

    public static func normalizedEnglishSizeLevel(from rawValue: String) -> Int {
        guard let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultEnglishSizeLevel
        }
        guard (minimumEnglishSizeLevel...maximumEnglishSizeLevel).contains(value) else {
            return defaultEnglishSizeLevel
        }
        return value
    }

    public static func normalizedTargetScalePercent(_ value: Int) -> Int {
        let clamped = min(maximumTargetScalePercent, max(minimumTargetScalePercent, value))
        let steps = Int((Double(clamped - minimumTargetScalePercent) / Double(targetScalePercentStep)).rounded())
        return minimumTargetScalePercent + steps * targetScalePercentStep
    }

    public static func normalizedTargetScalePercent(from rawValue: String) -> Int {
        guard let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultTargetScalePercent
        }
        guard value >= minimumTargetScalePercent,
              value <= maximumTargetScalePercent,
              (value - minimumTargetScalePercent) % targetScalePercentStep == 0
        else {
            return defaultTargetScalePercent
        }
        return value
    }

    public static var targetScalePercentOptions: [Int] {
        stride(
            from: minimumTargetScalePercent,
            through: maximumTargetScalePercent,
            by: targetScalePercentStep
        ).map { $0 }
    }

    /// Migrates a legacy discrete `subtitleFontSize` into a 1–9 level.
    public static func englishSizeLevel(migratingFromLegacyFontSize legacy: Double?) -> Int {
        guard let legacy else { return defaultEnglishSizeLevel }
        switch Int(legacy.rounded()) {
        case 24: return 1
        case 30: return 3
        case 36: return 5
        case 42: return 7
        default: return defaultEnglishSizeLevel
        }
    }

    public func englishPointSize(on platform: SubtitleSizePlatform = .current) -> Double {
        let sizes = platform.englishPointSizes
        let index = Self.normalizedEnglishSizeLevel(englishSizeLevel) - 1
        return sizes[index]
    }

    /// Target-language point size before Dynamic Type scaling.
    /// Rounded to the nearest 0.5 pt and clamped to `[platform.minimum, english]`.
    public func targetPointSize(on platform: SubtitleSizePlatform = .current) -> Double {
        let english = englishPointSize(on: platform)
        let raw = english * (Double(Self.normalizedTargetScalePercent(targetScalePercent)) / 100.0)
        let rounded = (raw * 2).rounded() / 2
        return min(english, max(platform.minimumTargetPointSize, rounded))
    }

    /// True when the minimum target size clamp raised the computed size.
    public func isTargetSizeProtectedByMinimum(on platform: SubtitleSizePlatform = .current) -> Bool {
        let english = englishPointSize(on: platform)
        let raw = english * (Double(Self.normalizedTargetScalePercent(targetScalePercent)) / 100.0)
        let rounded = (raw * 2).rounded() / 2
        return rounded < platform.minimumTargetPointSize
    }
}
