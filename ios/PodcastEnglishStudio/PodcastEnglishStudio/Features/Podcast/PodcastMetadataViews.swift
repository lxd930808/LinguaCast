import SwiftUI
import DomainModels
import PodcastEnglishStudioCore

struct PodcastArtworkView: View {
    var urlString: String?
    var size: CGFloat
    var cornerRadius: CGFloat = 10
    var artworkSource: PodcastArtworkSource? = nil

    var body: some View {
        Group {
            if let urlString,
               let url = URL(string: urlString) {
                RemoteMediaImage(url: url, displaySize: CGSize(width: size, height: size)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ZStack {
                            placeholder
                            ProgressView()
                        }
                    case .failure:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if artworkSource == .apple {
                Image(systemName: "apple.logo")
                    .font(.caption2.bold())
                    .foregroundStyle(.primary)
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(L10n.string("podcast.artwork", fallback: "Podcast artwork"))
        .accessibilityHint(
            artworkSource == .apple
                ? L10n.string("podcast.open_in_apple_podcasts", fallback: "Listen on Apple Podcasts")
                : ""
        )
    }

    private var placeholder: some View {
        LinguaMediaPlaceholder(systemImage: "dot.radiowaves.left.and.right")
    }
}

struct PodcastProgramHeader: View {
    let subscription: PodcastSubscription
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    artwork
                    details
                }
                VStack(alignment: .leading, spacing: 14) {
                    artwork
                    details
                }
            }

            if let summary = nonEmpty(subscription.summaryText) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("podcast.program-summary")
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(
                            isExpanded
                                ? L10n.string("podcast.show_less", fallback: "Show less")
                                : L10n.string("podcast.show_more", fallback: "Show more")
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .background(LinguaTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LinguaTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcast.program-header")
    }

    private var artwork: some View {
        PodcastArtworkView(
            urlString: subscription.artworkURL,
            size: 132,
            cornerRadius: 16,
            artworkSource: subscription.artworkSourceKind
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(subscription.displayName)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            if let author = nonEmpty(subscription.authorName) {
                Label(author, systemImage: "person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let website = validURL(subscription.websiteURL) {
                Link(destination: website) {
                    Label(
                        L10n.string("podcast.open_website", fallback: "Open podcast website"),
                        systemImage: "safari"
                    )
                }
            }
            if subscription.artworkSource == "apple",
               let appleURL = validURL(subscription.applePodcastsURL) {
                Link(destination: appleURL) {
                    Label(
                        L10n.string("podcast.open_in_apple_podcasts", fallback: "Listen on Apple Podcasts"),
                        systemImage: "apple.logo"
                    )
                }
                .accessibilityIdentifier("podcast.apple-source-link")
            }
        }
        .buttonStyle(.bordered)
    }
}

struct PodcastEpisodeMetadataHeader: View {
    let episode: EpisodeRecord
    var fallbackArtworkURL: String?
    var fallbackArtworkSource: PodcastArtworkSource? = nil
    @State private var isSummaryExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                PodcastArtworkView(
                    urlString: episode.artworkURL ?? fallbackArtworkURL,
                    size: 104,
                    cornerRadius: 12,
                    artworkSource: episode.artworkURL == nil ? fallbackArtworkSource : nil
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(episode.episodeTitle)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(episode.showTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PodcastEpisodeFacts(episode: episode)
                }
            }
            if let summary = nonEmpty(episode.summaryText) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(isSummaryExpanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("podcast.episode-summary")
                    if shouldOfferSummaryToggle(summary) {
                        Button {
                            isSummaryExpanded.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Text(
                                    isSummaryExpanded
                                        ? L10n.string("podcast.show_less", fallback: "Show less")
                                        : L10n.string("podcast.show_more", fallback: "Show more")
                                )
                                Spacer()
                                Image(systemName: isSummaryExpanded ? "chevron.up" : "chevron.down")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(
                                Color.accentColor.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("podcast.episode-summary-toggle")
                        .accessibilityValue(isSummaryExpanded ? "expanded" : "collapsed")
                    }
                }
            }
            if let episodeURL = validURL(episode.episodeWebsiteURL) {
                Divider()
                    .padding(.top, 4)
                Link(destination: episodeURL) {
                    Label(
                        L10n.string("podcast.open_episode_website", fallback: "Open episode website"),
                        systemImage: "safari"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("podcast.episode-website-link")
            }
        }
        .padding(18)
        .background(LinguaTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LinguaTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcast.episode-metadata")
    }

    private func shouldOfferSummaryToggle(_ summary: String) -> Bool {
        summary.count > 240 || summary.filter(\.isNewline).count >= 4
    }
}

struct PodcastEpisodeFacts: View {
    let episode: EpisodeRecord

    var body: some View {
        HStack(spacing: 10) {
            if let publishedAt = episode.publishedAt {
                Text(publishedAt, style: .date)
            }
            if let duration = episode.mediaDurationSeconds {
                Label(podcastDurationText(duration), systemImage: "clock")
            }
            if let season = episode.seasonNumber,
               let number = episode.episodeNumber {
                Text(
                    L10n.format(
                        "podcast.season_episode",
                        fallback: "S%@ E%@",
                        String(season),
                        String(number)
                    )
                )
            } else if let number = episode.episodeNumber {
                Text(
                    L10n.format(
                        "podcast.episode_number",
                        fallback: "Episode %@",
                        String(number)
                    )
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

func podcastDurationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remainingSeconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return value
}

private func validURL(_ value: String?) -> URL? {
    guard let value = nonEmpty(value),
          let url = URL(string: value),
          url.scheme == "https" || url.scheme == "http"
    else { return nil }
    return url
}
