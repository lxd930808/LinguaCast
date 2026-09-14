import SwiftUI
import DomainModels

#if os(iOS)
struct AssistantSearchResultCard: View {
    let result: AssistantSearchResult
    var binding: AssistantContentBinding? = nil
    var mutationsEnabled: Bool = true
    var onSelect: (AssistantSearchResult) -> Void
    var onPlay: ((AssistantSearchResult) -> Void)? = nil
    var onViewEpisodes: ((AssistantSearchResult) -> Void)?

    private var phase: AssistantSourceCardPhase {
        AssistantSourceCardPolicy.phase(
            searchResultId: result.searchResultId,
            binding: binding
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kindLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LinguaTheme.secondaryText)
            Text(result.title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(LinguaTheme.secondaryText)
            if let reason = matchReasonLabel {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.secondaryText)
            }
            if let warning = userWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.secondaryText)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LinguaTheme.border, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if result.sourceType == .podcastShow {
                Button(L10n.string("assistant.view_episodes", fallback: "View episodes")) {
                    onViewEpisodes?(result)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LinguaTheme.accent)
                .accessibilityIdentifier("assistant.episodes.\(result.searchResultId)")
            }
            if result.deepResearchAvailability == "available" && result.sourceType != .podcastShow {
                if mutationsEnabled || phase == .ready {
                    sourceAction
                }
            }
        }
        if phase == .preparing, let binding, binding.searchResultId == result.searchResultId {
            preparingProgress(binding)
        }
        if phase == .failed {
            Text(binding?.error?.message ?? L10n.string("assistant.preparation", fallback: "Preparation"))
                .font(.caption)
                .foregroundStyle(LinguaTheme.danger)
        }
    }

    @ViewBuilder
    private var sourceAction: some View {
        switch phase {
        case .idle:
            Button(L10n.string("assistant.generate_subtitles", fallback: "Generate bilingual subtitles")) {
                onSelect(result)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LinguaTheme.accent)
            .accessibilityIdentifier("assistant.select.\(result.searchResultId)")
        case .preparing:
            EmptyView()
        case .ready:
            Button(L10n.string("assistant.open_player", fallback: "Play")) {
                onPlay?(result)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LinguaTheme.accent)
            .accessibilityIdentifier("assistant.play.\(result.searchResultId)")
        case .failed:
            Button(L10n.string("assistant.retry_prepare", fallback: "Retry")) {
                onSelect(result)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LinguaTheme.accent)
            .accessibilityIdentifier("assistant.retry.\(result.searchResultId)")
        }
    }

    private func preparingProgress(_ binding: AssistantContentBinding) -> some View {
        let step = AssistantSourceCardPolicy.pipelineStep(for: binding)
        let progress = min(max(binding.progress ?? 0, 0), 1)
        return VStack(alignment: .leading, spacing: 8) {
            PodcastPipelineStageRail(step: step)
            HStack {
                Text(PipelineStepTitle.display(step))
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.secondaryText)
                Spacer()
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(LinguaTheme.secondaryText)
            }
            LinguaProgressBar(value: progress)
                .tint(LinguaTheme.accent)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.prepare.progress.\(result.searchResultId)")
        .accessibilityLabel(PipelineStepTitle.display(step))
        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
    }

    private var kindLabel: String {
        switch result.sourceType {
        case .video:
            return L10n.string("assistant.source.video", fallback: "Video")
        case .podcastShow:
            return L10n.string("assistant.source.show", fallback: "Podcast show")
        case .podcastEpisode:
            return L10n.string("assistant.source.episode", fallback: "Podcast episode")
        case .unknown:
            return L10n.string("assistant.source.unknown", fallback: "Source")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let publisher = result.publisher, !publisher.isEmpty { parts.append(publisher) }
        parts.append(platformLabel)
        if let published = result.publishedAt {
            parts.append(published.formatted(date: .abbreviated, time: .omitted))
        }
        if let seconds = result.durationSeconds, seconds > 0 {
            parts.append("\(seconds / 60) min")
        }
        return parts.joined(separator: " · ")
    }

    private var platformLabel: String {
        switch result.platform {
        case .youtube: return "YouTube"
        case .podcast, .applePodcasts: return "Podcast"
        case .unknown(let raw): return raw
        }
    }

    private var matchReasonLabel: String? {
        switch result.matchReason {
        case "title_exact":
            return L10n.string("assistant.match.title_exact", fallback: "Exact title match")
        case "entity_exact", "person_tag", "person_tag_and_episode_title":
            return L10n.string("assistant.match.person", fallback: "Person or show match")
        case "recent_window":
            return L10n.string("assistant.match.recent", fallback: "Within the requested time range")
        case "channel_or_show_match":
            return L10n.string("assistant.match.show", fallback: "Show or channel match")
        case "title_term_coverage", "description_term":
            return L10n.string("assistant.match.terms", fallback: "Matched search terms")
        default:
            return nil
        }
    }

    private var userWarning: String? {
        let warnings = result.warnings ?? []
        if warnings.contains("metadata_partial") {
            return L10n.string("assistant.warning.metadata_partial", fallback: "Some details are incomplete")
        }
        if warnings.contains("filter_best_effort") {
            return L10n.string("assistant.warning.filter_best_effort", fallback: "Time filters are best-effort")
        }
        return nil
    }
}
#endif
