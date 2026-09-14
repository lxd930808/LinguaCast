#if os(iOS)
import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

/// Bilingual subtitle presentation controls bound to the Settings draft configuration.
struct SubtitlePresentationSettingsSection: View {
    @Bindable var settings: SettingsStore
    var wrapsInSection = true

    private var presentation: SubtitlePresentationPreferences {
        settings.configuration.subtitlePresentation
    }

    private var platform: SubtitleSizePlatform { .current }

    private var englishPointSize: Double {
        presentation.englishPointSize(on: platform)
    }

    private var targetPointSize: Double {
        presentation.targetPointSize(on: platform)
    }

    private var targetLanguageName: String {
        settings.configuration.translationTarget.autonym
    }

    var body: some View {
        Group {
            if wrapsInSection {
                Section(L10n.string("settings.subtitles", fallback: "Subtitles")) {
                    controls
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    LinguaSectionHeader(title: L10n.string("settings.subtitles", fallback: "Subtitles"))
                    controls
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        englishSizeControl
        targetScaleControl
        orderControl

        if presentation.isTargetSizeProtectedByMinimum(on: platform) {
            Text(L10n.string(
                "settings.subtitle_min_size_hint",
                fallback: "Translation size is raised to the platform minimum for readability."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        SubtitlePresentationPreview(
            presentation: presentation,
            targetLanguage: settings.configuration.translationTarget
        )
    }

    @ViewBuilder
    private var englishSizeControl: some View {
        Stepper(
            value: $settings.configuration.subtitleEnglishSizeLevel,
            in: SubtitlePresentationPreferences.minimumEnglishSizeLevel
                ... SubtitlePresentationPreferences.maximumEnglishSizeLevel
        ) {
            LabeledContent(
                L10n.string("settings.subtitle_english_size", fallback: "English Size"),
                value: SubtitleOptionLabels.englishSize(
                    level: presentation.englishSizeLevel,
                    scalePercent: presentation.targetScalePercent,
                    order: presentation.order,
                    platform: platform
                )
            )
        }
        .accessibilityIdentifier("settings.subtitle.english-size")
        .accessibilityLabel(L10n.string("settings.subtitle_english_size", fallback: "English Size"))
        .accessibilityValue(Text(verbatim: englishSizeAccessibilityValue))
        Text(L10n.string(
            "settings.subtitle_english_size_help",
            fallback: "English subtitle size from level 1 (smallest) to 9 (largest)."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var targetScaleControl: some View {
        Picker(
            L10n.string("settings.subtitle_target_scale", fallback: "Translation Size"),
            selection: $settings.configuration.subtitleTargetScalePercent
        ) {
            ForEach(SubtitlePresentationPreferences.targetScalePercentOptions, id: \.self) { percent in
                Text(
                    SubtitleOptionLabels.targetScale(
                        percent: percent,
                        englishSizeLevel: presentation.englishSizeLevel,
                        order: presentation.order,
                        platform: platform
                    )
                ).tag(percent)
            }
        }
        .accessibilityIdentifier("settings.subtitle.target-scale")
        .accessibilityValue(Text(verbatim: targetScaleAccessibilityValue))
        Text(L10n.format(
            "settings.subtitle_target_scale_help",
            fallback: "Translation size as a percentage of English size. Current translation language: %@.",
            targetLanguageName
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var orderControl: some View {
        Picker(
            L10n.string("settings.subtitle_order", fallback: "Line Order"),
            selection: $settings.configuration.subtitleOrder
        ) {
            Text(L10n.string(
                "settings.subtitle_order_english_first",
                fallback: "English first"
            ))
            .tag(SubtitleOrder.englishFirst.rawValue)
            Text(L10n.format(
                "settings.subtitle_order_target_first",
                fallback: "%@ first",
                targetLanguageName
            ))
            .tag(SubtitleOrder.targetFirst.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .accessibilityIdentifier("settings.subtitle.order")
        .accessibilityValue(Text(verbatim: orderAccessibilityValue))
        Text(L10n.string(
            "settings.subtitle_order_help",
            fallback: "Choose which language appears on the top line."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var englishSizeAccessibilityValue: String {
        SubtitleOptionLabels.englishSizeValue(level: presentation.englishSizeLevel, pointSize: englishPointSize)
    }

    private var targetScaleAccessibilityValue: String {
        SubtitleOptionLabels.targetScaleValue(percent: presentation.targetScalePercent, pointSize: targetPointSize)
    }

    private var orderAccessibilityValue: String {
        SubtitleOptionLabels.orderValue(order: presentation.order, targetLanguageName: targetLanguageName)
    }
}
#endif
