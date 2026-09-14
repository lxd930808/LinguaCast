import SwiftUI
import SwiftData
import DomainModels
import PodcastEnglishStudioCore

/// Observes the existing translation variant so real sentence counts update in place.
struct PodcastGenerationProgressView: View {
    let episode: EpisodeRecord
    var showsBar = true
    @Query private var variants: [TranslationVariantRecord]

    init(episode: EpisodeRecord, showsBar: Bool = true) {
        self.episode = episode
        self.showsBar = showsBar
        let contentID = episode.id
        let kind = TranslationContentKind.podcastEpisode.rawValue
        _variants = Query(filter: #Predicate<TranslationVariantRecord> {
            $0.contentID == contentID && $0.contentKind == kind
        })
    }

    private var variant: TranslationVariantRecord? {
        guard let target = episode.activeTranslationTargetLanguage else { return nil }
        return variants.first { $0.targetLanguage == target }
    }

    private var counts: (completed: Int?, total: Int?) {
        guard episode.pipelineStep == "translate" || episode.pipelineStep == "translating" else {
            return (nil, nil)
        }
        return (variant?.translatedCount, variant?.totalCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(YTSourceGenerationProgressText.title(
                step: episode.pipelineStep, progress: episode.pipelineProgress,
                completedCount: counts.completed, totalCount: counts.total,
                hidesZeroProgress: true
            ) ?? PipelineStepTitle.display(episode.pipelineStep))
            if showsBar {
                LinguaProgressBar(value: episode.pipelineProgress ?? 0)
            }
        }
    }
}
