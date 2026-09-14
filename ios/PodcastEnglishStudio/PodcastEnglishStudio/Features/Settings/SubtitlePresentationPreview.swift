import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

struct SubtitlePresentationPreview: View {
    let presentation: SubtitlePresentationPreferences
    let targetLanguage: TranslationTarget

    private var platform: SubtitleSizePlatform { .current }

    var body: some View {
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
        .accessibilityValue(Text(verbatim: previewLines.map(\.text).joined(separator: "\n")))
    }

    private var previewLines: [PreviewLine] {
        let english = PreviewLine(
            id: "en",
            text: L10n.string(
                "settings.subtitle_preview_english_sample",
                fallback: "Hello, welcome to today's lesson."
            ),
            pointSize: presentation.englishPointSize(on: platform),
            isEnglish: true
        )
        let target = PreviewLine(
            id: "target",
            text: catalogString(targetSampleKey(for: targetLanguage)),
            pointSize: presentation.targetPointSize(on: platform),
            isEnglish: false
        )
        switch presentation.order {
        case .englishFirst: return [english, target]
        case .targetFirst: return [target, english]
        }
    }

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
