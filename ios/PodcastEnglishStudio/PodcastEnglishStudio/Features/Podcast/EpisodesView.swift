import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

struct ProgramsView: View {
    @Binding var selectedTab: AppTab
    @State private var selectedSource: ProgramSource = .podcast

    init(selectedTab: Binding<AppTab> = .constant(.programs)) {
        _selectedTab = selectedTab
    }

    var body: some View {
        listContent
        #if os(tvOS)
        .navigationDestination(for: ProgramNavigationRoute.self) { route in
            switch route.source {
            case .podcast:
                PodcastProgramRouteView(subscriptionID: route.id, selectedTab: $selectedTab)
            case .youtube:
                YTChannelRouteView(channelID: route.id)
            }
        }
        #endif
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                LinguaCard(padding: 8) {
                    Picker(L10n.string("common.source", fallback: "Source"), selection: $selectedSource) {
                        ForEach(ProgramSource.allCases, id: \.self) { source in
                            Label(source.title, systemImage: source.icon)
                                .tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch selectedSource {
                case .podcast:
                    PodcastProgramsSection(selectedTab: $selectedTab)
                case .youtube:
                    YouTubeProgramsSection()
                }
            }
            .padding(.horizontal, LinguaTheme.pageHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .linguaContentWidth()
        }
        .linguaPage()
        .accessibilityIdentifier("screen.programs")
        .navigationTitle(L10n.string("episodes.programs", fallback: "Programs"))
    }
}

#if os(tvOS)
private struct ProgramNavigationRoute: Hashable {
    var source: ProgramSource
    var id: String
}

private struct PodcastProgramRouteView: View {
    @Binding var selectedTab: AppTab
    @Query private var subscriptions: [PodcastSubscription]

    init(subscriptionID: String, selectedTab: Binding<AppTab>) {
        _selectedTab = selectedTab
        _subscriptions = Query(
            filter: #Predicate<PodcastSubscription> { $0.id == subscriptionID }
        )
    }

    var body: some View {
        if let subscription = subscriptions.first {
            PodcastProgramDetailView(subscription: subscription, selectedTab: $selectedTab)
        } else {
            ContentUnavailableView(L10n.string("episodes.the_program_does_not_exist", fallback: "The program does not exist"), systemImage: "dot.radiowaves.left.and.right")
        }
    }
}

private struct YTChannelRouteView: View {
    @Query private var channels: [YTChannelRecord]

    init(channelID: String) {
        _channels = Query(
            filter: #Predicate<YTChannelRecord> { $0.id == channelID }
        )
    }

    var body: some View {
        if let channel = channels.first {
            YTChannelDetailView(channel: channel)
        } else {
            ContentUnavailableView(L10n.string("common.channel_does_not_exist", fallback: "Channel does not exist"), systemImage: "play.rectangle")
        }
    }
}
#endif

private enum ProgramSource: CaseIterable {
    case podcast
    case youtube

    var title: String {
        switch self {
        case .podcast: L10n.string("common.podcast", fallback: "Podcast")
        case .youtube: L10n.string("common.youtube", fallback: "YouTube")
        }
    }

    var icon: String {
        switch self {
        case .podcast: "dot.radiowaves.left.and.right"
        case .youtube: "play.rectangle"
        }
    }
}

private struct PodcastProgramsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Binding var selectedTab: AppTab
    @Query(sort: \PodcastSubscription.updatedAt, order: .reverse) private var subscriptions: [PodcastSubscription]
    @Query(sort: \EpisodeRecord.updatedAt, order: .reverse) private var episodes: [EpisodeRecord]
    @State private var contentFilter = ContentFilterService()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LinguaSectionHeader(title: L10n.string("common.podcast", fallback: "Podcast"))
            if subscriptions.isEmpty {
                LinguaCard {
                    ContentUnavailableView(L10n.string("common.no_podcast_subscriptions_yet", fallback: "No Podcast subscriptions yet"), systemImage: "dot.radiowaves.left.and.right")
                }
            } else {
                #if os(tvOS)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 24) {
                        ForEach(visibleSubscriptions) { subscription in
                            NavigationLink(value: ProgramNavigationRoute(source: .podcast, id: subscription.id)) {
                                ProgramSourceRow(
                                    title: subscription.displayName,
                                    subtitle: subscription.showURL,
                                    icon: "dot.radiowaves.left.and.right",
                                    count: count(for: subscription),
                                    artworkURL: subscription.artworkURL,
                                    artworkSource: subscription.artworkSourceKind,
                                    showsPodcastArtwork: true
                                )
                            }
                            .frame(width: 560)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                .programCardButtonStyle()
                #else
                LazyVGrid(columns: programColumns, spacing: 16) {
                    ForEach(visibleSubscriptions) { subscription in
                        NavigationLink {
                            PodcastProgramDetailView(subscription: subscription, selectedTab: $selectedTab)
                        } label: {
                            ProgramSourceRow(
                                title: subscription.displayName,
                                subtitle: subscription.showURL,
                                icon: "dot.radiowaves.left.and.right",
                                count: count(for: subscription),
                                artworkURL: subscription.artworkURL,
                                artworkSource: subscription.artworkSourceKind,
                                showsPodcastArtwork: true
                            )
                        }
                    }
                }
                .programCardButtonStyle()
                #endif
            }
        }
        .task {
            contentFilter.update(configuration: settings.configuration)
            prefetchContentFilterVerdicts()
        }
        .onChange(of: settings.configuration) { _, configuration in
            contentFilter.update(configuration: configuration)
            prefetchContentFilterVerdicts()
        }
        .onChange(of: subscriptions.map(\.id)) { _, _ in
            prefetchContentFilterVerdicts()
        }
    }

    private var visibleSubscriptions: [PodcastSubscription] {
        subscriptions.filter {
            !contentFilter.isFilteredOut(id: $0.id, title: $0.displayName, channel: $0.displayName)
        }
    }

    private func prefetchContentFilterVerdicts() {
        contentFilter.prefetchAgentVerdicts(subscriptions.map {
            ContentFilterService.Item(id: $0.id, title: $0.displayName, channel: $0.displayName)
        })
    }

    private func count(for subscription: PodcastSubscription) -> Int {
        episodes.filter { $0.subscriptionID == subscription.id }.count
    }

    private var programColumns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 520, maximum: 760), spacing: 20)]
        #else
        [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 16)]
        #endif
    }
}

private struct YouTubeProgramsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Query(sort: \YTChannelRecord.updatedAt, order: .reverse) private var channels: [YTChannelRecord]
    @Query(sort: \YTVideoRecord.recordUpdatedAt, order: .reverse) private var videos: [YTVideoRecord]
    @State private var contentFilter = ContentFilterService()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LinguaSectionHeader(title: L10n.string("common.youtube", fallback: "YouTube"))
            if channels.isEmpty {
                LinguaCard {
                    ContentUnavailableView(L10n.string("common.there_is_no_youtube_channel_yet", fallback: "There is no YouTube channel yet"), systemImage: "play.rectangle")
                }
            } else {
                #if os(tvOS)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 24) {
                        ForEach(visibleChannels) { channel in
                            NavigationLink(value: ProgramNavigationRoute(source: .youtube, id: channel.id)) {
                                ProgramSourceRow(
                                    title: channel.displayName,
                                    subtitle: channel.url,
                                    icon: "play.rectangle",
                                    count: channel.videoCount,
                                    artworkURL: channelArtworkURL(for: channel)
                                )
                            }
                            .frame(width: 560)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                .programCardButtonStyle()
                #else
                LazyVGrid(columns: programColumns, spacing: 16) {
                    ForEach(visibleChannels) { channel in
                        NavigationLink {
                            YTChannelDetailView(channel: channel)
                        } label: {
                            ProgramSourceRow(
                                title: channel.displayName,
                                subtitle: channel.url,
                                icon: "play.rectangle",
                                count: channel.videoCount,
                                artworkURL: channelArtworkURL(for: channel)
                            )
                        }
                    }
                }
                .programCardButtonStyle()
                #endif
            }
        }
        .task {
            contentFilter.update(configuration: settings.configuration)
            prefetchContentFilterVerdicts()
        }
        .onChange(of: settings.configuration) { _, configuration in
            contentFilter.update(configuration: configuration)
            prefetchContentFilterVerdicts()
        }
        .onChange(of: channels.map(\.id)) { _, _ in
            prefetchContentFilterVerdicts()
        }
    }

    private var visibleChannels: [YTChannelRecord] {
        channels.filter {
            !contentFilter.isFilteredOut(id: $0.id, title: $0.displayName, channel: $0.displayName)
        }
    }

    private func prefetchContentFilterVerdicts() {
        contentFilter.prefetchAgentVerdicts(channels.map {
            ContentFilterService.Item(id: $0.id, title: $0.displayName, channel: $0.displayName)
        })
    }

    private func channelArtworkURL(for channel: YTChannelRecord) -> String? {
        // Use the newest available remote video thumbnail as the channel card artwork.
        videos.first { $0.channelRecordID == channel.id }?.thumbnail
    }

    private var programColumns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 520, maximum: 760), spacing: 20)]
        #else
        [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 16)]
        #endif
    }
}

private struct ProgramSourceRow: View {
    var title: String
    var subtitle: String
    var icon: String
    var count: Int
    var artworkURL: String? = nil
    var artworkSource: PodcastArtworkSource? = nil
    var showsPodcastArtwork = false

    var body: some View {
        LinguaCard {
            HStack(spacing: 14) {
                if showsPodcastArtwork {
                    PodcastArtworkView(
                        urlString: artworkURL,
                        size: artworkSize,
                        cornerRadius: 12,
                        artworkSource: artworkSource
                    )
                } else if let artworkURL,
                          let url = URL(string: artworkURL) {
                    RemoteMediaImage(
                        url: url,
                        displaySize: CGSize(width: artworkSize, height: artworkSize)
                    ) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty, .failure:
                            LinguaMediaPlaceholder(systemImage: icon)
                        }
                    }
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    LinguaMediaPlaceholder(systemImage: icon)
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(LinguaTheme.secondaryText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                        Text(verbatim: "\(count)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LinguaTheme.accent)
                }
                Spacer()
#if !os(tvOS)
                // iOS list affordance; tvOS focus ring already signals tappable.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LinguaTheme.tertiaryText)
#endif
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: LinguaTheme.cardRadius))
    }

    private var artworkSize: CGFloat {
        #if os(tvOS)
        108
        #else
        72
        #endif
    }
}

struct PodcastProgramDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(PipelineRunner.self) private var runner
    @Binding var selectedTab: AppTab
    let subscription: PodcastSubscription
    @Query private var episodes: [EpisodeRecord]
    private let fileStore = LocalFileStore()
    @State private var selectedEpisodeID: String?
    @State private var selectedPlaybackCategory: PlaybackListCategory = .unplayed
    @State private var isRefreshing = false
    @State private var isLoadingAll = false
    @State private var contentFilter = ContentFilterService()

    init(subscription: PodcastSubscription, selectedTab: Binding<AppTab>) {
        _selectedTab = selectedTab
        self.subscription = subscription
        let subscriptionID = subscription.id
        _episodes = Query(
            filter: #Predicate<EpisodeRecord> { $0.subscriptionID == subscriptionID },
            sort: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
    }

    var body: some View {
        ScrollView {
            PodcastProgramHeader(subscription: subscription)
                .padding(.horizontal)
                .padding(.top, 16)

            if isRefreshing || isLoadingAll {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(
                        isLoadingAll
                            ? L10n.string("episodes.fetching_all", fallback: "Fetching all episodes...")
                            : L10n.string("episodes.fetching_latest_fifty", fallback: "Fetching the latest 50 episodes...")
                    )
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .accessibilityIdentifier("podcast.refresh-progress")
            }

            if !episodes.isEmpty, let error = subscription.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(LinguaTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .accessibilityIdentifier("podcast.refresh-error")
            }

            if episodes.isEmpty {
                ContentUnavailableView(L10n.string("episodes.no_single_episode_yet", fallback: "No single episode yet"), systemImage: "headphones", description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.string("ytchannel_detail.playing_status", fallback: "Playing status"), selection: $selectedPlaybackCategory) {
                        ForEach(PlaybackListCategory.listTabs, id: \.category) { tab in
                            Text(verbatim: "\(tab.title) \(count(for: tab.category))")
                                .tag(tab.category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .accessibilityIdentifier("podcast.playback-category")

                    Text(selectedPlaybackTabTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .accessibilityIdentifier("podcast.playback-category-title")

                    if selectedPlaybackEpisodes.isEmpty {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(cardBackground)
                            .frame(height: 64)
                            .overlay(alignment: .leading) {
                                Text(L10n.string("common.none_yet", fallback: "None yet"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                            }
                            .padding(.horizontal)
                            .accessibilityIdentifier("podcast.playback-category-empty")
                    } else {
                        #if os(tvOS)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 24) {
                                ForEach(selectedPlaybackEpisodes) { episode in
                                    episodeButton(episode)
                                        .frame(width: 620)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                        }
                        .scrollClipDisabled()
                        #else
                        ForEach(selectedPlaybackEpisodes) { episode in
                            episodeButton(episode)
                            .padding(.horizontal)
                        }
                        #endif
                    }

                    archiveControl
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                .padding(.vertical, 24)
            }
        }
        .linguaPage()
        .navigationTitle(subscription.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing || isLoadingAll)
                .accessibilityLabel(L10n.string("episodes.refresh_latest", fallback: "Refresh the latest 50 episodes"))
                .accessibilityIdentifier("podcast.refresh-all")
            }
        }
        .refreshable {
            await refresh()
        }
        .task {
            contentFilter.update(configuration: settings.configuration)
            prefetchContentFilterVerdicts()
        }
        .task(id: programPrefetchToken) {
            await ArtworkPrefetchService.shared.prefetchUntilCancelled(
                urls: programPrefetchURLs,
                token: programPrefetchToken
            )
        }
        .onChange(of: settings.configuration) { _, configuration in
            contentFilter.update(configuration: configuration)
            prefetchContentFilterVerdicts()
        }
        .onChange(of: episodes.map(\.id)) { _, _ in
            prefetchContentFilterVerdicts()
        }
        .fullScreenCover(isPresented: isEpisodeDetailPresented) {
            if let selectedEpisodeID {
                NavigationStack {
                    EpisodeDetailRouteView(episodeID: selectedEpisodeID, onOpenSettings: openSettings)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    self.selectedEpisodeID = nil
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .accessibilityLabel(L10n.string("common.close", fallback: "Close"))
                            }
                        }
                }
            } else {
                ContentUnavailableView(L10n.string("common.the_single_episode_does_not_exist", fallback: "The single episode does not exist"), systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var isEpisodeDetailPresented: Binding<Bool> {
        Binding(
            get: { selectedEpisodeID != nil },
            set: { isPresented in
                if !isPresented {
                    selectedEpisodeID = nil
                }
            }
        )
    }

    private func episodeButton(_ episode: EpisodeRecord) -> some View {
        Button {
            selectedEpisodeID = episode.id
        } label: {
            PodcastEpisodeRow(
                episode: episode,
                fallbackArtworkURL: subscription.artworkURL,
                fallbackArtworkSource: subscription.artworkSourceKind
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                cardBackground,
                in: RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous)
            )
        }
        .podcastEpisodeButtonStyle()
        .accessibilityIdentifier("podcast.episode.\(episode.id)")
        .contextMenu {
            if PodcastClearAndRegeneratePolicy.isAvailable(status: episode.status) {
                Button {
                    Task {
                        await runner.clearAndRegenerate(
                            episode: episode,
                            context: modelContext,
                            configuration: settings.configuration
                        )
                    }
                } label: {
                    Label(
                        L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }
        }
        #if !os(tvOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if PodcastClearAndRegeneratePolicy.isAvailable(status: episode.status) {
                Button {
                    Task {
                        await runner.clearAndRegenerate(
                            episode: episode,
                            context: modelContext,
                            configuration: settings.configuration
                        )
                    }
                } label: {
                    Label(
                        L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .tint(LinguaTheme.warning)
                .accessibilityIdentifier("podcast.clear-and-regenerate")
            }
        }
        #endif
    }

    private var selectedPlaybackEpisodes: [EpisodeRecord] {
        visibleEpisodes.filter { playbackCategory(for: $0) == selectedPlaybackCategory }
    }

    private var visibleEpisodes: [EpisodeRecord] {
        episodes.filter {
            !contentFilter.isFilteredOut(id: $0.id, title: $0.episodeTitle, channel: $0.showTitle)
        }
    }

    private func prefetchContentFilterVerdicts() {
        contentFilter.prefetchAgentVerdicts(episodes.map {
            ContentFilterService.Item(id: $0.id, title: $0.episodeTitle, channel: $0.showTitle)
        })
    }

    private var programPrefetchToken: String {
        let continueIDs = episodes
            .filter { playbackCategory(for: $0) == .inProgress }
            .map(\.id)
            .joined(separator: ",")
        let readyIDs = episodes
            .filter { $0.status == "completed" }
            .map(\.id)
            .joined(separator: ",")
        return "program:\(subscription.id):\(continueIDs)|\(readyIDs)"
    }

    private var programPrefetchURLs: [URL] {
        let fallback = subscription.artworkURL.flatMap(URL.init(string:))
        let continueURLs = episodes
            .filter { playbackCategory(for: $0) == .inProgress }
            .compactMap { episode -> URL? in
                if let value = episode.artworkURL, let url = URL(string: value) { return url }
                return fallback
            }
        let readyURLs = episodes
            .filter { $0.status == "completed" }
            .compactMap { episode -> URL? in
                if let value = episode.artworkURL, let url = URL(string: value) { return url }
                return fallback
            }
        return ArtworkPrefetchPolicy.prioritizedURLs(
            continuePlaying: continueURLs,
            readyCatalog: readyURLs
        )
    }

    private var selectedPlaybackTabTitle: String {
        PlaybackListCategory.listTabs.first { $0.category == selectedPlaybackCategory }?.title
            ?? L10n.string("episodes.programs", fallback: "Programs")
    }

    private func count(for category: PlaybackListCategory) -> Int {
        visibleEpisodes.filter { playbackCategory(for: $0) == category }.count
    }

    private var emptyDescription: String {
        if let error = subscription.lastError, !error.isEmpty {
            return error
        }
        if let url = URL(string: subscription.showURL),
           PodcastSubscriptionURLInspector.isUnsupportedAppleChannel(url) {
            return PodcastFeedError.unsupportedAppleChannel.localizedDescription
        }
        return L10n.string("episodes.refresh_channel_to_fetch_latest", fallback: "Use Refresh to fetch the latest 50 playable episodes in this Podcast feed.")
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await runner.refresh(subscription: subscription, context: modelContext)
    }

    @ViewBuilder
    private var archiveControl: some View {
        if isLoadingAll {
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.string("episodes.fetching_all", fallback: "Fetching all episodes..."))
            }
            .frame(maxWidth: .infinity)
        } else if subscription.hasMoreEpisodes != false {
            Button {
                Task { await loadAllEpisodes() }
            } label: {
                Label(
                    L10n.string("episodes.fetch_all_history", fallback: "Fetch all historical episodes"),
                    systemImage: "arrow.down.circle"
                )
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(isRefreshing)
            .accessibilityIdentifier("podcast.fetch-all-history")
        } else {
            Label(
                L10n.string("episodes.all_loaded", fallback: "All episodes loaded"),
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private func loadAllEpisodes() async {
        guard !isLoadingAll else { return }
        isLoadingAll = true
        defer { isLoadingAll = false }
        await runner.refresh(
            subscription: subscription,
            context: modelContext,
            mode: .all
        )
    }

    private func openSettings() {
        selectedEpisodeID = nil
        selectedTab = .settings
    }

    private var cardBackground: Color {
        LinguaTheme.surfaceElevated
    }

    private func playbackCategory(for episode: EpisodeRecord) -> PlaybackListCategory {
        PlaybackListPolicy.category(
            playbackPosition: episode.playbackPositionSeconds,
            duration: episode.playbackDurationSeconds,
            completedAt: episode.playbackCompletedAt
        )
    }

    private func delete(_ episode: EpisodeRecord) {
        let episodeID = episode.id
        runner.cancel(episodeID: episodeID)
        deleteSegments(episodeID: episodeID)
        try? TranslationVariantRepository.deleteAll(
            contentKind: .podcastEpisode,
            contentID: episodeID,
            context: modelContext
        )
        resetSubscriptionIfNeeded(for: episode)
        // Deleting catalog rows invalidates the local baseline used by RSS validators.
        subscription.clearRSSValidators()
        if let files = try? fileStore.episodeFiles(episodeID: episodeID) {
            try? FileManager.default.removeItem(at: files.directory)
        }
        modelContext.delete(episode)
        try? modelContext.save()
    }

    private func deleteSegments(episodeID: String) {
        let segmentDescriptor = FetchDescriptor<SegmentRecord>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        for item in (try? modelContext.fetch(segmentDescriptor)) ?? [] {
            modelContext.delete(item)
        }
    }

    private func resetSubscriptionIfNeeded(for episode: EpisodeRecord) {
        if subscription.lastJobID == episode.id {
            subscription.lastJobID = nil
        }
        if subscription.lastEpisodeGUID == episode.episodeGUID {
            subscription.lastEpisodeGUID = nil
        }
        subscription.updatedAt = Date()
    }
}

private extension PlaybackListCategory {
    static let listTabs: [(category: PlaybackListCategory, title: String)] = [
        (.unplayed, L10n.string("common.unplayed", fallback: "Unplayed")),
        (.inProgress, L10n.string("common.in_progress", fallback: "In progress")),
        (.played, L10n.string("common.played", fallback: "Played"))
    ]
}

private struct PodcastEpisodeRow: View {
    let episode: EpisodeRecord
    var fallbackArtworkURL: String?
    var fallbackArtworkSource: PodcastArtworkSource?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PodcastArtworkView(
                urlString: episode.artworkURL ?? fallbackArtworkURL,
                size: 76,
                cornerRadius: 9,
                artworkSource: episode.artworkURL == nil ? fallbackArtworkSource : nil
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(episode.episodeTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    playbackIcon
                }
                if let summary = episode.summaryText,
                   !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                PodcastEpisodeFacts(episode: episode)
                HStack {
                    Label(statusLabel, systemImage: statusIcon)
                    if episode.status == "running" {
                        Text(
                            ASRProgressText.display(
                                message: episode.pipelineMessage,
                                fallback: stepLabel
                            )
                        )
                    }
                    if let error = episode.errorMessage {
                        Text(error)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(statusColor)
                if episode.status == "running" {
                    PodcastPipelineStageRail(step: episode.pipelineStep)
                } else if let playbackProgressValue {
                    ProgressView(value: playbackProgressValue)
                        .progressViewStyle(.linear)
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("media.playback-progress")
                        .accessibilityValue(Text(verbatim: "ltr"))
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var playbackIcon: some View {
        switch playbackCategory {
        case .played:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LinguaTheme.success)
        case .inProgress:
            Text((playbackProgressValue ?? 0).formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .unplayed:
            EmptyView()
        }
    }

    private var playbackCategory: PlaybackListCategory {
        PlaybackListPolicy.category(
            playbackPosition: episode.playbackPositionSeconds,
            duration: episode.playbackDurationSeconds,
            completedAt: episode.playbackCompletedAt
        )
    }

    private var playbackProgressValue: Double? {
        guard let position = episode.playbackPositionSeconds,
              let duration = episode.playbackDurationSeconds,
              position.isFinite,
              duration.isFinite,
              duration > 0
        else { return nil }
        return min(max(position / duration, 0), 1)
    }

    private var progressValue: Double {
        min(max(episode.pipelineProgress ?? fallbackProgress(for: episode.pipelineStep), 0), 1)
    }

    private var stepLabel: String {
        switch episode.pipelineStep {
        case "download": L10n.string("episodes.download_audio", fallback: "Download audio")
        case "oss_upload": L10n.string("episodes.upload_audio", fallback: "Upload audio")
        case "transcribe": L10n.string("episodes.speech_to_text", fallback: "Speech to text")
        case "translate": L10n.string("episodes.translate_content", fallback: "Translate content")
        case "build_learning_pack": L10n.string("episodes.generate_bilingual_subtitles", fallback: "Generate bilingual subtitles")
        default: episode.pipelineStep
        }
    }

    private func fallbackProgress(for step: String) -> Double {
        switch step {
        case "download": 0.12
        case "oss_upload": 0.28
        case "transcribe": 0.48
        case "translate": 0.72
        case "build_learning_pack": 0.9
        case "completed": 1.0
        default: 0.05
        }
    }

    private var statusLabel: String {
        switch episode.status {
        case "completed": L10n.string("common.ready", fallback: "Ready")
        case "running": L10n.string("episodes.generating", fallback: "Generating")
        case "failed": L10n.string("common.failed", fallback: "Failed")
        default: L10n.string("episodes.queuing", fallback: "Not processed")
        }
    }

    private var statusIcon: String {
        switch episode.status {
        case "completed": "checkmark.circle.fill"
        case "running": "hourglass"
        case "failed": "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    private var statusColor: Color {
        switch episode.status {
        case "completed": LinguaTheme.success
        case "failed": LinguaTheme.danger
        default: LinguaTheme.secondaryText
        }
    }
}

private struct PodcastPipelineStageRail: View {
    let step: String

    private var currentStage: Int {
        switch step {
        case "download", "oss_upload": 0
        case "transcribe": 1
        case "translate": 2
        case "build_learning_pack", "completed": 3
        default: 0
        }
    }

    private var titles: [String] {
        [
            L10n.string("episodes.download_audio", fallback: "Download audio"),
            L10n.string("episodes.speech_to_text", fallback: "Speech to text"),
            L10n.string("episodes.translate_content", fallback: "Translate content"),
            L10n.string("episodes.generate_bilingual_subtitles", fallback: "Generate bilingual subtitles")
        ]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(titles.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(index <= currentStage ? LinguaTheme.accent : LinguaTheme.progressTrack)
                        .frame(height: 4)
                    Text(titles[index])
                        .font(.caption2)
                        .foregroundStyle(index == currentStage ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(titles[currentStage])
    }
}

private extension View {
    @ViewBuilder
    func programCardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(LinguaFocusableCardStyle())
        #else
        buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    func podcastEpisodeButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(LinguaFocusableCardStyle())
        #else
        buttonStyle(.plain)
        #endif
    }
}
