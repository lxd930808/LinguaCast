import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

struct HomeView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PlaybackCatalogRecoveryCoordinator.self) private var catalogRecovery
    @Query private var subscriptions: [PodcastSubscription]
    @Query(sort: \EpisodeRecord.updatedAt, order: .reverse) private var episodes: [EpisodeRecord]
    @Query(sort: \YTVideoRecord.recordUpdatedAt, order: .reverse) private var videos: [YTVideoRecord]
    @Binding var selectedTab: AppTab

    init(selectedTab: Binding<AppTab> = .constant(.home)) {
        _selectedTab = selectedTab
    }

    private var continueItems: [HomeContentItem] {
        let podcastItems = episodes
            .filter { $0.appearsInSubscriptionLibrary && playbackCategory(for: $0) == .inProgress }
            .map(HomeContentItem.podcast)
        let videoItems = videos
            .filter { $0.appearsInSubscriptionLibrary && playbackCategory(for: $0) == .inProgress }
            .map(HomeContentItem.youtube)
        return (podcastItems + videoItems).sorted { $0.sortDate > $1.sortDate }
    }

    private var recentItems: [HomeContentItem] {
        let podcastItems = episodes
            .filter { $0.appearsInSubscriptionLibrary && playbackCategory(for: $0) == .unplayed }
            .map(HomeContentItem.podcast)
        let videoItems = videos
            .filter { $0.appearsInSubscriptionLibrary && playbackCategory(for: $0) == .unplayed }
            .map(HomeContentItem.youtube)
        return (podcastItems + videoItems).sorted { $0.publishOrCreateDate > $1.publishOrCreateDate }
    }

    private var assistantHomeItems: [HomeContentItem] {
        let podcastItems = episodes
            .filter(\.isPinnedAssistantHomeItem)
            .map(HomeContentItem.podcast)
        let videoItems = videos
            .filter(\.isPinnedAssistantHomeItem)
            .map(HomeContentItem.youtube)
        return (podcastItems + videoItems).sorted { $0.sortDate > $1.sortDate }
    }

    var body: some View {
        Group {
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .accessibilityIdentifier("screen.home")
        .navigationTitle(L10n.string("today.home", fallback: "Home"))
        // Home no longer syncs on appear: startup/foreground recovery is orchestrated by
        // RootView. Pull-to-refresh uses the manual synchronize-and-recover path, which may
        // bypass definitive misses and backoff but still enforces the 30-day / 20-item cap.
        .refreshable {
            guard !UITestSupport.isEnabled else { return }
            await catalogRecovery.synchronizeAndRecover(trigger: .manualRefresh)
        }
        .task(id: homePrefetchToken) {
            await ArtworkPrefetchService.shared.prefetchUntilCancelled(
                urls: homePrefetchURLs,
                token: homePrefetchToken
            )
        }
    }

    private var homePrefetchToken: String {
        let continueIDs = continueItems.map(\.id).joined(separator: ",")
        let assistantIDs = assistantHomeItems.map(\.id).joined(separator: ",")
        let readyIDs = readyCatalogItems.map(\.id).joined(separator: ",")
        return "home:\(continueIDs)|\(assistantIDs)|\(readyIDs)"
    }

    private var homePrefetchURLs: [URL] {
        ArtworkPrefetchPolicy.prioritizedURLs(
            continuePlaying: continueItems.compactMap {
                $0.thumbnailURL(podcastFallbackArtworkURL: fallbackArtworkURL(for: $0))
            },
            readyCatalog: readyCatalogItems.compactMap {
                $0.thumbnailURL(podcastFallbackArtworkURL: fallbackArtworkURL(for: $0))
            }
        )
    }

    private var readyCatalogItems: [HomeContentItem] {
        let podcastItems = episodes
            .filter { $0.appearsInSubscriptionLibrary && $0.status == "completed" }
            .map(HomeContentItem.podcast)
        let videoItems = videos
            .filter { $0.appearsInSubscriptionLibrary && $0.bilingualSubtitlesCompleted }
            .map(HomeContentItem.youtube)
        return (podcastItems + videoItems).sorted { $0.publishOrCreateDate > $1.publishOrCreateDate }
    }

    private var iOSBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                let readiness = ConfigurationReadiness(configuration: settings.configuration)
                if !readiness.summary.isComplete {
                    LinguaCard {
                        SetupChecklistView(readiness: readiness) {
                            selectedTab = .settings
                        }
                    }
                }

                LinguaSectionHeader(
                    title: L10n.string("today.continue_playing", fallback: "continue playing")
                )

                if continueItems.isEmpty {
                    emptyContinueCard
                } else {
                    navigationRow(for: continueItems[0], showsProgress: true, isHero: true)
                    ForEach(continueItems.dropFirst().prefix(3)) { item in
                        navigationRow(for: item, showsProgress: true)
                    }
                }

                if !assistantHomeItems.isEmpty {
                    LinguaSectionHeader(
                        title: L10n.string("home.assistant_section", fallback: "From Assistant")
                    )
                    ForEach(assistantHomeItems.prefix(8)) { item in
                        navigationRow(for: item, showsProgress: true)
                    }
                }

                LinguaSectionHeader(
                    title: L10n.string("today.latest_updates", fallback: "Latest updates")
                )

                if recentItems.isEmpty {
                    emptyRecentCard(readiness: readiness)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 280, maximum: 520), spacing: 14)
                        ],
                        spacing: 14
                    ) {
                        ForEach(recentItems.prefix(30)) { item in
                            navigationRow(for: item, showsProgress: false)
                        }
                    }
                }
            }
            .padding(.horizontal, LinguaTheme.pageHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .linguaContentWidth()
        }
        .linguaPage()
    }

    private var tvOSBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                let readiness = ConfigurationReadiness(configuration: settings.configuration)
                if !readiness.summary.isComplete {
                    LinguaCard {
                        SetupChecklistView(readiness: readiness) {
                            selectedTab = .settings
                        }
                    }
                    .frame(maxWidth: 1_100)
                }

                LinguaSectionHeader(
                    title: L10n.string("today.continue_playing", fallback: "continue playing")
                )

                if continueItems.isEmpty {
                    emptyContinueCard
                        .frame(maxWidth: 900)
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        navigationRow(for: continueItems[0], showsProgress: true, isHero: true)
                            .frame(width: 820)
                        if continueItems.count > 1 {
                            navigationRow(for: continueItems[1], showsProgress: true)
                                .frame(width: 520)
                        }
                    }
                }

                if !assistantHomeItems.isEmpty {
                    LinguaSectionHeader(
                        title: L10n.string("home.assistant_section", fallback: "From Assistant")
                    )
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 22) {
                            ForEach(assistantHomeItems.prefix(12)) { item in
                                navigationRow(for: item, showsProgress: true)
                                    .frame(width: 390)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                }

                LinguaSectionHeader(
                    title: L10n.string("today.latest_updates", fallback: "Latest updates")
                )

                if recentItems.isEmpty {
                    emptyRecentCard(readiness: readiness)
                        .frame(maxWidth: 900)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 22) {
                            ForEach(recentItems.prefix(20)) { item in
                                navigationRow(for: item, showsProgress: false)
                                    .frame(width: 390)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                }

                if !readyCatalogItems.isEmpty {
                    LinguaSectionHeader(
                        title: L10n.string("today.bilingual_ready", fallback: "Bilingual ready")
                    )
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 22) {
                            ForEach(readyCatalogItems.prefix(20)) { item in
                                navigationRow(for: item, showsProgress: false)
                                    .frame(width: 390)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                }
            }
            .padding(.horizontal, LinguaTheme.pageHorizontalPadding)
            .padding(.vertical, 30)
            .linguaContentWidth()
        }
        .linguaPage()
    }

    private var emptyContinueCard: some View {
        LinguaCard {
            ActionableEmptyStateView(
                title: L10n.string("today.there_is_no_content_currently_playing", fallback: "There is no content currently playing"),
                systemImage: "play.circle",
                message: L10n.string("today.the_played_podcast_or_youtube_videos_will_appear_here_for_easy_l", fallback: "The played Podcast or YouTube videos will appear here for easy listening."),
                primaryTitle: L10n.string("common.add_subscription", fallback: "Add subscription"),
                primarySystemImage: "plus",
                primaryAction: { selectedTab = .subscriptions },
                secondaryTitle: L10n.string("today.check_settings", fallback: "Check settings"),
                secondarySystemImage: "gearshape",
                secondaryAction: { selectedTab = .settings }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.empty-continue")
    }

    private func emptyRecentCard(readiness: ConfigurationReadiness) -> some View {
        LinguaCard {
            ActionableEmptyStateView(
                title: L10n.string("today.no_recent_updates", fallback: "No recent updates"),
                systemImage: "sparkles",
                message: L10n.string("today.open_a_channel_on_programs_to_refresh", fallback: "After adding a subscription, open its channel on the Programs page to refresh available episodes or videos."),
                primaryTitle: L10n.string("today.go_to_subscription_page", fallback: "Go to subscription page"),
                primarySystemImage: "dot.radiowaves.left.and.right",
                primaryAction: { selectedTab = .subscriptions },
                secondaryTitle: readiness.summary.isComplete ? nil : L10n.string("today.completion_settings", fallback: "Completion settings"),
                secondarySystemImage: readiness.summary.isComplete ? nil : "key",
                secondaryAction: readiness.summary.isComplete ? nil : { selectedTab = .settings }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.empty-recent")
    }

    @ViewBuilder
    private func navigationRow(
        for item: HomeContentItem,
        showsProgress: Bool,
        isHero: Bool = false
    ) -> some View {
        switch item {
        case .podcast(let episode):
            NavigationLink {
                EpisodeDetailView(episode: episode, onOpenSettings: {
                    selectedTab = .settings
                })
            } label: {
                HomeContentRow(
                    item: item,
                    showsProgress: showsProgress,
                    isHero: isHero,
                    podcastFallbackArtworkURL: fallbackArtworkURL(for: item),
                    podcastFallbackArtworkSource: fallbackArtworkSource(for: item)
                )
            }
            .homeCardButtonStyle()
        case .youtube(let video):
            NavigationLink {
                YTVideoPlayerScreen(video: video)
            } label: {
                HomeContentRow(
                    item: item,
                    showsProgress: showsProgress,
                    isHero: isHero,
                    podcastFallbackArtworkURL: nil,
                    podcastFallbackArtworkSource: nil
                )
            }
            .homeCardButtonStyle()
        }
    }

    private func fallbackArtworkURL(for item: HomeContentItem) -> String? {
        guard case .podcast(let episode) = item,
              let subscriptionID = episode.subscriptionID
        else { return nil }
        return subscriptions.first { $0.id == subscriptionID }?.artworkURL
    }

    private func fallbackArtworkSource(for item: HomeContentItem) -> PodcastArtworkSource? {
        guard case .podcast(let episode) = item,
              let subscriptionID = episode.subscriptionID
        else { return nil }
        return subscriptions.first { $0.id == subscriptionID }?.artworkSourceKind
    }

    private func playbackCategory(for episode: EpisodeRecord) -> PlaybackListCategory {
        PlaybackListPolicy.category(
            playbackPosition: episode.playbackPositionSeconds,
            duration: episode.playbackDurationSeconds,
            completedAt: episode.playbackCompletedAt
        )
    }

    private func playbackCategory(for video: YTVideoRecord) -> PlaybackListCategory {
        PlaybackListPolicy.category(
            playbackPosition: video.playbackPositionSeconds,
            duration: video.playbackDurationSeconds,
            completedAt: video.playbackCompletedAt
        )
    }
}

private enum HomeContentItem: Identifiable {
    case podcast(EpisodeRecord)
    case youtube(YTVideoRecord)

    var id: String {
        switch self {
        case .podcast(let episode): "podcast-\(episode.id)"
        case .youtube(let video): "youtube-\(video.id)"
        }
    }

    var title: String {
        switch self {
        case .podcast(let episode): episode.episodeTitle
        case .youtube(let video): video.title
        }
    }

    var sourceTitle: String {
        switch self {
        case .podcast(let episode): episode.showTitle
        case .youtube: L10n.string("common.youtube", fallback: "YouTube")
        }
    }

    var sourceLabel: String {
        switch self {
        case .podcast: L10n.string("common.podcast", fallback: "Podcast")
        case .youtube: L10n.string("common.youtube", fallback: "YouTube")
        }
    }

    var sourceIcon: String {
        switch self {
        case .podcast: "dot.radiowaves.left.and.right"
        case .youtube: "play.rectangle"
        }
    }

    func thumbnailURL(podcastFallbackArtworkURL: String?) -> URL? {
        switch self {
        case .podcast(let episode):
            return URL(string: episode.artworkURL ?? podcastFallbackArtworkURL ?? "")
        case .youtube(let video):
            return video.thumbnail.flatMap(URL.init(string:))
        }
    }

    var progress: Double? {
        switch self {
        case .podcast(let episode):
            return progressValue(position: episode.playbackPositionSeconds, duration: episode.playbackDurationSeconds)
        case .youtube(let video):
            return progressValue(position: video.playbackPositionSeconds, duration: video.playbackDurationSeconds)
        }
    }

    var sortDate: Date {
        switch self {
        case .podcast(let episode): episode.playbackUpdatedAt ?? episode.updatedAt
        case .youtube(let video): video.playbackUpdatedAt ?? video.recordUpdatedAt
        }
    }

    var publishOrCreateDate: Date {
        switch self {
        case .podcast(let episode): episode.publishedAt ?? episode.createdAt
        case .youtube(let video): video.publishedAt ?? video.createdAt
        }
    }

    private func progressValue(position: Double?, duration: Double?) -> Double? {
        guard let position,
              let duration,
              position.isFinite,
              duration.isFinite,
              duration > 0
        else { return nil }
        return min(max(position / duration, 0), 1)
    }
}

private struct HomeContentRow: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var item: HomeContentItem
    var showsProgress: Bool
    var isHero = false
    var podcastFallbackArtworkURL: String?
    var podcastFallbackArtworkSource: PodcastArtworkSource?

    var body: some View {
        LinguaCard(padding: isHero ? 20 : 14, cornerRadius: isHero ? LinguaTheme.heroRadius : LinguaTheme.cardRadius) {
            if isHero && horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 16) {
                    Thumbnail(
                        item: item,
                        isHero: true,
                        podcastFallbackArtworkURL: podcastFallbackArtworkURL,
                        podcastFallbackArtworkSource: podcastFallbackArtworkSource
                    )
                    .frame(maxWidth: .infinity)
                    details
                }
            } else {
                horizontalContent
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: LinguaTheme.cardRadius))
    }

    private var horizontalContent: some View {
            HStack(alignment: isHero ? .center : .top, spacing: isHero ? 18 : 12) {
                Thumbnail(
                    item: item,
                    isHero: isHero,
                    podcastFallbackArtworkURL: podcastFallbackArtworkURL,
                    podcastFallbackArtworkSource: podcastFallbackArtworkSource
                )

                details
                Spacer(minLength: 0)
#if !os(tvOS)
                // iOS list affordance; tvOS focus ring already signals tappable.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LinguaTheme.tertiaryText)
#endif
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: isHero ? 10 : 6) {
            Text(item.title)
                .font(isHero ? .title2.weight(.bold) : .headline)
                .lineLimit(isHero ? 3 : 2)
            Text(item.sourceTitle)
                .font(isHero ? .body : .subheadline)
                .foregroundStyle(LinguaTheme.secondaryText)
                .lineLimit(1)
            HStack(spacing: 8) {
                LinguaStatusChip(
                    title: item.sourceLabel,
                    systemImage: item.sourceIcon,
                    tone: .accent
                )
                if let progress = item.progress, showsProgress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LinguaTheme.secondaryText)
                }
            }
            if showsProgress, let progress = item.progress {
                LinguaProgressBar(value: progress)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("media.playback-progress")
                    .accessibilityValue(Text(verbatim: "ltr"))
            }
        }
    }

    private struct Thumbnail: View {
        var item: HomeContentItem
        var isHero: Bool
        var podcastFallbackArtworkURL: String?
        var podcastFallbackArtworkSource: PodcastArtworkSource?

        @ViewBuilder
        var body: some View {
            switch item {
            case .podcast(let episode):
                PodcastArtworkView(
                    urlString: episode.artworkURL ?? podcastFallbackArtworkURL,
                    size: isHero ? 118 : 64,
                    cornerRadius: isHero ? 16 : 10,
                    artworkSource: episode.artworkURL == nil
                        ? podcastFallbackArtworkSource
                        : nil
                )
            case .youtube:
                ZStack {
                    if let url = item.thumbnailURL(
                        podcastFallbackArtworkURL: podcastFallbackArtworkURL
                    ) {
                        RemoteMediaImage(
                            url: url,
                            displaySize: CGSize(
                                width: isHero ? 176 : 86,
                                height: isHero ? 100 : 58
                            )
                        ) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .empty, .failure:
                                placeholder
                            }
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(
                    width: isHero ? 176 : 86,
                    height: isHero ? 100 : 58
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: isHero ? 14 : 8,
                        style: .continuous
                    )
                )
            }
        }

        private var placeholder: some View {
            LinguaMediaPlaceholder(systemImage: item.sourceIcon)
        }
    }
}

private extension View {
    @ViewBuilder
    func homeCardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(LinguaFocusableCardStyle())
        #else
        buttonStyle(.plain)
        #endif
    }
}
