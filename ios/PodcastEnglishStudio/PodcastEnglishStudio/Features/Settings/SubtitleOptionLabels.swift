import CloudSyncKit

enum SubtitleOptionLabels {
    static func englishSize(level: Int, scalePercent: Int, order: SubtitleOrder, platform: SubtitleSizePlatform) -> String {
        let size = SubtitlePresentationPreferences(
            englishSizeLevel: level,
            targetScalePercent: scalePercent,
            order: order
        ).englishPointSize(on: platform)
        return L10n.format(
            "settings.subtitle_english_size_option",
            fallback: "%d · %@",
            level,
            pointSizeText(size)
        )
    }

    static func targetScale(percent: Int, englishSizeLevel: Int, order: SubtitleOrder, platform: SubtitleSizePlatform) -> String {
        let size = SubtitlePresentationPreferences(
            englishSizeLevel: englishSizeLevel,
            targetScalePercent: percent,
            order: order
        ).targetPointSize(on: platform)
        return L10n.format(
            "settings.subtitle_target_scale_option",
            fallback: "%@ · %@",
            percentText(percent),
            pointSizeText(size)
        )
    }

    static func englishSizeValue(level: Int, pointSize: Double) -> String {
        L10n.format(
            "settings.subtitle_english_size_value",
            fallback: "Level %d, %@",
            level,
            pointSizeText(pointSize)
        )
    }

    static func targetScaleValue(percent: Int, pointSize: Double) -> String {
        L10n.format(
            "settings.subtitle_target_scale_value",
            fallback: "%@, %@",
            percentText(percent),
            pointSizeText(pointSize)
        )
    }

    static func orderValue(order: SubtitleOrder, targetLanguageName: String) -> String {
        switch order {
        case .englishFirst:
            return L10n.string(
                "settings.subtitle_order_english_first",
                fallback: "English first"
            )
        case .targetFirst:
            return L10n.format(
                "settings.subtitle_order_target_first",
                fallback: "%@ first",
                targetLanguageName
            )
        }
    }

    static func pointSizeText(_ value: Double) -> String {
        L10n.format("settings.subtitle_size_pt_format", fallback: "%g pt", value)
    }

    static func percentText(_ value: Int) -> String {
        L10n.format("settings.subtitle_target_scale_format", fallback: "%d%%", value)
    }
}
