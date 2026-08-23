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

            preview
    }

    @ViewBuilder
    private var englishSizeControl: some View {
        #if os(tvOS)
        Picker(
            L10n.string("settings.subtitle_english_size", fallback: "English Size"),
            selection: $settings.configuration.subtitleEnglishSizeLevel
        ) {
            ForEach(
                SubtitlePresentationPreferences.minimumEnglishSizeLevel
                    ... SubtitlePresentationPreferences.maximumEnglishSizeLevel,
                id: \.self
            ) { level in
                Text(englishSizeOptionLabel(level: level)).tag(level)
            }
        }
        .accessibilityIdentifier("settings.subtitle.english-size")
        .accessibilityValue(Text(verbatim: englishSizeAccessibilityValue))
        #else
        Stepper(
            value: $settings.configuration.subtitleEnglishSizeLevel,
            in: SubtitlePresentationPreferences.minimumEnglishSizeLevel
                ... SubtitlePresentationPreferences.maximumEnglishSizeLevel
        ) {
            LabeledContent(
                L10n.string("settings.subtitle_english_size", fallback: "English Size"),
                value: englishSizeOptionLabel(level: presentation.englishSizeLevel)
            )
        }
        .accessibilityIdentifier("settings.subtitle.english-size")
        .accessibilityLabel(L10n.string("settings.subtitle_english_size", fallback: "English Size"))
        .accessibilityValue(Text(verbatim: englishSizeAccessibilityValue))
        #endif
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
                Text(targetScaleOptionLabel(percent: percent)).tag(percent)
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
        #if os(iOS)
        .pickerStyle(.segmented)
        #endif
        .accessibilityIdentifier("settings.subtitle.order")
        .accessibilityValue(Text(verbatim: orderAccessibilityValue))
        Text(L10n.string(
            "settings.subtitle_order_help",
            fallback: "Choose which language appears on the top line."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var preview: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(L10n.string("settings.subtitle_preview", fallback: "Preview"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                ForEach(previewLines, id: \.id) { line in
                    Text(line.text)
                        .font(.system(
                            size: line.pointSize,
                            weight: line.isEnglish ? .semibold : .regular
                        ))
                        .foregroundStyle(line.isEnglish ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.subtitle.preview")
        .accessibilityLabel(L10n.string("settings.subtitle_preview", fallback: "Preview"))
        .accessibilityValue(Text(verbatim: previewAccessibilityValue))
    }

    private var previewLines: [PreviewLine] {
        let english = PreviewLine(
            id: "en",
            text: L10n.string(
                "settings.subtitle_preview_english_sample",
                fallback: "Hello, welcome to today's lesson."
            ),
            pointSize: englishPointSize,
            isEnglish: true
        )
        let target = PreviewLine(
            id: "target",
            text: catalogString(targetSampleKey(for: settings.configuration.translationTarget)),
            pointSize: targetPointSize,
            isEnglish: false
        )
        switch presentation.order {
        case .englishFirst: return [english, target]
        case .targetFirst: return [target, english]
        }
    }

    private var englishSizeAccessibilityValue: String {
        L10n.format(
            "settings.subtitle_english_size_value",
            fallback: "Level %d, %@",
            presentation.englishSizeLevel,
            pointSizeText(englishPointSize)
        )
    }

    private var targetScaleAccessibilityValue: String {
        L10n.format(
            "settings.subtitle_target_scale_value",
            fallback: "%@, %@",
            percentText(presentation.targetScalePercent),
            pointSizeText(targetPointSize)
        )
    }

    private var orderAccessibilityValue: String {
        switch presentation.order {
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

    private var previewAccessibilityValue: String {
        previewLines.map(\.text).joined(separator: "\n")
    }

    private func englishSizeOptionLabel(level: Int) -> String {
        let size = SubtitlePresentationPreferences(
            englishSizeLevel: level,
            targetScalePercent: presentation.targetScalePercent,
            order: presentation.order
        ).englishPointSize(on: platform)
        return L10n.format(
            "settings.subtitle_english_size_option",
            fallback: "%d · %@",
            level,
            pointSizeText(size)
        )
    }

    private func targetScaleOptionLabel(percent: Int) -> String {
        let size = SubtitlePresentationPreferences(
            englishSizeLevel: presentation.englishSizeLevel,
            targetScalePercent: percent,
            order: presentation.order
        ).targetPointSize(on: platform)
        return L10n.format(
            "settings.subtitle_target_scale_option",
            fallback: "%@ · %@",
            percentText(percent),
            pointSizeText(size)
        )
    }

    private func pointSizeText(_ value: Double) -> String {
        L10n.format("settings.subtitle_size_pt_format", fallback: "%g pt", value)
    }

    private func percentText(_ value: Int) -> String {
        L10n.format("settings.subtitle_target_scale_format", fallback: "%d%%", value)
    }

    /// Sample lines are stored only in the string catalog so Settings source stays free of CJK literals.
    private func targetSampleKey(for target: TranslationTarget) -> String {
        switch target {
        case .simplifiedChinese: "settings.subtitle_preview_target_sample_zh_Hans"
        case .traditionalChinese: "settings.subtitle_preview_target_sample_zh_Hant"
        case .spanish: "settings.subtitle_preview_target_sample_es"
        case .brazilianPortuguese: "settings.subtitle_preview_target_sample_pt_BR"
        case .japanese: "settings.subtitle_preview_target_sample_ja"
        case .korean: "settings.subtitle_preview_target_sample_ko"
        case .french: "settings.subtitle_preview_target_sample_fr"
        case .german: "settings.subtitle_preview_target_sample_de"
        case .arabic: "settings.subtitle_preview_target_sample_ar"
        }
    }

    private func catalogString(_ key: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? "" : value
    }
}

private struct PreviewLine: Hashable {
    let id: String
    let text: String
    let pointSize: Double
    let isEnglish: Bool
}
