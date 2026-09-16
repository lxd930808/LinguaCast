import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

struct YTChannelDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    let channel: YTChannelRecord
    @Query private var videos: [YTVideoRecord]

    @State private var localService = YTLocalService()
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var retryingVideoIDs: Set<String> = []
    @State private var selectedVideoID: String?
    @State private var selectedPlaybackCategory: PlaybackListCategory = .unplayed
#if os(tvOS)
    /// Debounced stream resolve for the focused poster so playback can hit cache.
    @FocusState private var focusedVideoID: String?
    @State private var streamPrewarmTask: Task<Void, Never>?
#endif

    init(channel: YTChannelRecord) {
        self.channel = channel
        let channelID = channel.id
        _videos = Query(
            filter: #Predicate<YTVideoRecord> { $0.channelRecordID == channelID },
            sort: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
    }

    var body: some View {
        videoList
        .navigationTitle(channel.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .refreshable {
            await refresh()
        }
        .task(id: channelPrefetchToken) {
            await ArtworkPrefetchService.shared.prefetchUntilCancelled(
                urls: channelPrefetchURLs,
                token: channelPrefetchToken
            )
        }
#if os(tvOS)
        .onChange(of: focusedVideoID) { _, videoID in
            scheduleStreamPrewarm(videoID: videoID)
        }
        .onDisappear {
            streamPrewarmTask?.cancel()
            streamPrewarmTask = nil
        }
#endif
        .accessibilityIdentifier("screen.youtube-channel")
    }

    @ViewBuilder
    private var videoList: some View {
        #if os(tvOS)
        listContent
            .navigationDestination(for: YTVideoNavigationRoute.self) { route in
                if let video = video(for: route.videoID) {
                    YTVideoPlayerScreen(video: video)
                } else {
                    LinguaEmptyState(L10n.string("ytchannel_detail.video_does_not_exist", fallback: "Video does not exist"), systemImage: "play.rectangle", kind: .failure)
                }
            }
        #else
        listContent
            .fullScreenCover(isPresented: isVideoPlayerPresented, onDismiss: {
                selectedVideoID = nil
            }) {
                if let selectedVideoID,
                   let video = video(for: selectedVideoID) {
                    YTVideoPlayerPresentation(video: video)
                } else {
                    LinguaEmptyState(L10n.string("ytchannel_detail.video_does_not_exist", fallback: "Video does not exist"), systemImage: "play.rectangle", kind: .failure)
                }
            }
        #endif
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                channelHeader

                if isLoading && videos.isEmpty {
                    LinguaCard {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                if let errorMessage = channel.lastError {
                    LinguaCard {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LinguaTheme.danger)
                    }
                }
                if videos.isEmpty && !isLoading {
                    LinguaCard {
                        LinguaEmptyState(
                            L10n.string("ytchannel_detail.no_video_yet", fallback: "No video yet"),
                            systemImage: "play.rectangle"
                        )
                    }
                }
                if !videos.isEmpty {
                    LinguaCard {
                        Picker(L10n.string("ytchannel_detail.playing_status", fallback: "Playing status"), selection: $selectedPlaybackCategory) {
                            ForEach(PlaybackListCategory.listTabs, id: \.category) { tab in
                            Text(verbatim: "\(tab.title) \(count(for: tab.category))")
                                .tag(tab.category)
                        }
                        }
                        .pickerStyle(.segmented)
                    }

                    LinguaSectionHeader(title: selectedPlaybackTabTitle)
                    if selectedPlaybackVideos.isEmpty {
                        LinguaCard {
                            Text(L10n.string("common.none_yet", fallback: "None yet"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        #if os(tvOS)
                        ScrollView(.horizontal) {
                            LazyHGrid(
                                rows: [
                                    GridItem(.fixed(340), spacing: 24),
                                    GridItem(.fixed(340), spacing: 24)
                                ],
                                spacing: 24
                            ) {
                                ForEach(selectedPlaybackVideos) { video in
                                    videoRow(for: video)
                                        .frame(width: 400)
                                }
                            }
                            .padding(.vertical, 20)
                        }
                        .scrollClipDisabled()
                        .focusSection()
                        #else
                        LazyVGrid(columns: videoColumns, spacing: 18) {
                            ForEach(selectedPlaybackVideos) { video in
                                videoRow(for: video)
                            }
                        }
                        #endif
                    }

                    LinguaCard {
                        loadMoreControl
                    }
                }
            }
            .linguaContentWidth()
        }
        .linguaPage()
    }

    private var channelHeader: some View {
        #if os(tvOS)
        ZStack(alignment: .bottomLeading) {
            immersiveHeaderBackground
            HStack(spacing: 18) {
                channelArtwork
                    .frame(width: 132, height: 132)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                VStack(alignment: .leading, spacing: 8) {
                    Text(channel.displayName)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                    Label(
                        L10n.plural("youtube.video_count", fallback: "%lld videos", count: visibleVideos.count),
                        systemImage: "play.rectangle"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                }
                Spacer(minLength: 0)
            }
            .padding(28)
        }
        // Fixed height + clip: RemoteMediaImage scaledToFill must not expand the header
        // into a full-screen blur slab that hides the foreground metadata.
        .frame(maxWidth: .infinity)
        .frame(height: 236)
        .clipShape(RoundedRectangle(cornerRadius: LinguaTheme.heroRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LinguaTheme.heroRadius, style: .continuous)
                .stroke(LinguaTheme.border, lineWidth: 1)
        }
        #else
        LinguaCard {
            HStack(spacing: 18) {
                channelArtwork
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(channel.displayName)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Label(
                        L10n.plural("youtube.video_count", fallback: "%lld videos", count: visibleVideos.count),
                        systemImage: "play.rectangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        #endif
    }

    #if os(tvOS)
    private var immersiveHeaderBackground: some View {
        ZStack {
            LinguaTheme.surface
            if let url = headerBackgroundURL {
                RemoteMediaImage(url: url, displaySize: CGSize(width: 1_200, height: 420)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 18)
                    case .empty, .failure:
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .allowsHitTesting(false)
            }
            LinearGradient(
                colors: [
                    Color.black.opacity(0.25),
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerBackgroundURL: URL? {
        visibleVideos.first?.thumbnail.flatMap(URL.init(string:))
    }
    #endif

    private var channelArtwork: some View {
        Group {
            if let value = visibleVideos.first?.thumbnail,
               let url = URL(string: value) {
                RemoteMediaImage(url: url, displaySize: CGSize(width: 104, height: 104)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        LinguaMediaPlaceholder(systemImage: "play.rectangle.fill")
                    }
                }
            } else {
                LinguaMediaPlaceholder(systemImage: "play.rectangle.fill")
            }
        }
    }

    private var videoColumns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 520, maximum: 760), spacing: 22, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 300, maximum: 560), spacing: 18, alignment: .top)]
        #endif
    }

    @ViewBuilder
    private var loadMoreControl: some View {
        if isLoadingMore {
            HStack {
                ProgressView()
                Text(L10n.string("ytchannel_detail.get_all_in", fallback: "Get all in..."))
                    .foregroundStyle(.secondary)
            }
        } else if channel.hasMoreVideos {
            Button {
                Task { await loadAll() }
            } label: {
                Label(L10n.string("ytchannel_detail.get_all", fallback: "Get all"), systemImage: "arrow.down.circle")
            }
            .disabled(isLoading)
        } else {
            Label(L10n.string("ytchannel_detail.all_loaded", fallback: "All loaded"), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedPlaybackVideos: [YTVideoRecord] {
        visibleVideos.filter { playbackCategory(for: $0) == selectedPlaybackCategory }
    }

    private var visibleVideos: [YTVideoRecord] {
        videos.filter { $0.appearsInSubscriptionLibrary }
    }

    private var channelPrefetchToken: String {
        let continueIDs = videos
            .filter { playbackCategory(for: $0) == .inProgress }
            .map(\.id)
            .joined(separator: ",")
        let readyIDs = videos
            .filter(\.bilingualSubtitlesCompleted)
            .map(\.id)
            .joined(separator: ",")
        return "ytchannel:\(channel.id):\(continueIDs)|\(readyIDs)"
    }

    private var channelPrefetchURLs: [URL] {
        let continueURLs = videos
            .filter { playbackCategory(for: $0) == .inProgress }
            .compactMap { $0.thumbnail.flatMap(URL.init(string:)) }
        let readyURLs = videos
            .filter(\.bilingualSubtitlesCompleted)
            .compactMap { $0.thumbnail.flatMap(URL.init(string:)) }
        return ArtworkPrefetchPolicy.prioritizedURLs(
            continuePlaying: continueURLs,
            readyCatalog: readyURLs
        )
    }

    private var selectedPlaybackTabTitle: String {
        PlaybackListCategory.listTabs.first { $0.category == selectedPlaybackCategory }?.title ?? L10n.string("ytchannel_detail.videos", fallback: "Videos")
    }

    private func count(for category: PlaybackListCategory) -> Int {
        visibleVideos.filter { playbackCategory(for: $0) == category }.count
    }

    private func playbackCategory(for video: YTVideoRecord) -> PlaybackListCategory {
        PlaybackListPolicy.category(
            playbackPosition: video.playbackPositionSeconds,
            duration: video.playbackDurationSeconds,
            completedAt: video.playbackCompletedAt
        )
    }

    @ViewBuilder
    private func videoRow(for video: YTVideoRecord) -> some View {
        #if os(tvOS)
        NavigationLink(value: YTVideoNavigationRoute(videoID: video.id)) {
            YTVideoPosterCardLabel(video: video)
        }
        .buttonStyle(LinguaFocusableCardStyle())
        .focused($focusedVideoID, equals: video.id)
        #else
        Button {
            selectedVideoID = video.id
        } label: {
            YTVideoNavigationRowLabel(video: video)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .contextMenu {
            if canRetrySubtitles(video) {
                Button(L10n.string("ytchannel_detail.retry_subtitles", fallback: "Retry subtitles")) {
                    Task { await retrySubtitles(video) }
                }
            }
        }
        #endif
        #endif
    }

#if os(tvOS)
    /// Fire-and-forget resolve after focus settles so enter-to-play skips network parse.
    private func scheduleStreamPrewarm(videoID: String?) {
        streamPrewarmTask?.cancel()
        guard let videoID else { return }
        streamPrewarmTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let resolver = YTPlaybackBackend.makeResolver()
            do {
                _ = try await resolver.resolve(videoID: videoID)
                print("YTChannelDetail: prewarmed stream resolve videoID=\(videoID)")
            } catch {
                print("YTChannelDetail: prewarm failed videoID=\(videoID) error=\(error.localizedDescription)")
            }
        }
    }
#endif

    private var isVideoPlayerPresented: Binding<Bool> {
        Binding(
            get: { selectedVideoID != nil },
            set: { isPresented in
                if !isPresented {
                    selectedVideoID = nil
                }
            }
        )
    }

    private func video(for videoID: String) -> YTVideoRecord? {
        videos.first { $0.id == videoID }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await localService.refreshChannel(channel, configuration: settings.configuration, context: modelContext)
    }

    private func loadAll() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await localService.loadAllVideos(channel, configuration: settings.configuration, context: modelContext)
    }

    private func canRetrySubtitles(_ video: YTVideoRecord) -> Bool {
        guard !retryingVideoIDs.contains(video.id) else { return false }
        return video.subtitleStatus == "failed"
            || video.subtitleStatus == "partial"
            || (video.enReady && !video.zhReady)
    }

    private func retrySubtitles(_ video: YTVideoRecord) async {
        guard !retryingVideoIDs.contains(video.id) else { return }
        retryingVideoIDs.insert(video.id)
        defer { retryingVideoIDs.remove(video.id) }
        do {
            _ = try await localService.retrySubtitles(
                video: video,
                configuration: settings.configuration,
                context: modelContext,
                captionIngestionPolicy: IOSYouTubePlaybackMode.effective(
                    configured: settings.committedConfiguration.youTubePlaybackMode
                ).captionIngestionPolicy
            )
        } catch {
            video.subtitleStatus = video.enReady ? "partial" : "failed"
            video.lastError = error.localizedDescription
            video.recordUpdatedAt = Date()
            try? modelContext.save()
        }
    }
}

#if os(tvOS)
private struct YTVideoNavigationRoute: Hashable {
    var videoID: String
}
#endif

private extension PlaybackListCategory {
    static let listTabs: [(category: PlaybackListCategory, title: String)] = [
        (.unplayed, L10n.string("common.unplayed", fallback: "Unplayed")),
        (.inProgress, L10n.string("common.in_progress", fallback: "In progress")),
        (.played, L10n.string("common.played", fallback: "Played"))
    ]
}

#if !os(tvOS)
private struct YTVideoPlayerPresentation: View {
    @Environment(\.dismiss) private var dismiss
    var video: YTVideoRecord

    var body: some View {
        NavigationStack {
            YTVideoPlayerScreen(video: video)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
        }
    }
}
#endif

#if os(tvOS)
private struct YTVideoPosterCardLabel: View {
    var video: YTVideoRecord

    private let posterWidth: CGFloat = 400
    private var posterHeight: CGFloat {
        198 - (video.subtitleStatus == "translating" && progress != nil ? 10 : 0)
            - (playbackProgressValue != nil ? 12 : 0)
    }

    var body: some View {
        LinguaCard(padding: 12, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 12) {
                posterThumbnail
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .font(.system(size: 25, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        LinguaStatusChip(
                            title: statusText,
                            systemImage: statusIcon,
                            tone: statusTone,
                            font: .system(size: 19, weight: .semibold)
                        )
                        .lineLimit(1)
                        .layoutPriority(1)
                        if video.subtitleStatus != "translating", let publishedAt = video.publishedAt {
                            Text(publishedAt, style: .date)
                                .font(.system(size: 19))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if video.subtitleStatus == "translating", let progress {
                        LinguaProgressBar(value: progress.fraction)
                    }
                    if let playbackProgressValue {
                        LinguaProgressBar(value: playbackProgressValue)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            }
        }
        .contentShape(Rectangle())
    }

    private var posterThumbnail: some View {
        Group {
            if let url = thumbnailURL {
                RemoteMediaImage(
                    url: url,
                    displaySize: CGSize(width: posterWidth, height: posterHeight)
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        LinguaMediaPlaceholder(systemImage: "play.rectangle")
                    case .empty:
                        ZStack {
                            LinguaMediaPlaceholder(systemImage: "play.rectangle")
                            ProgressView()
                        }
                    }
                }
            } else {
                LinguaMediaPlaceholder(systemImage: "play.rectangle")
            }
        }
        .frame(width: posterWidth - 24, height: posterHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let durationText {
                Text(durationText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .padding(10)
            }
        }
    }

    private var thumbnailURL: URL? {
        video.thumbnail.flatMap(URL.init(string:))
    }

    private var durationText: String? {
        guard let duration = video.playbackDurationSeconds, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var statusText: String {
        if video.bilingualSubtitlesCompleted {
            return L10n.string("common.bilingual_subtitles", fallback: "bilingual subtitles")
        }
        if video.subtitleStatus == "failed" {
            return L10n.string("common.subtitles_failed", fallback: "Subtitles failed")
        }
        if video.subtitleStatus == "translating", let progress {
            return YTSourceGenerationProgressText.title(step: "translating", progress: nil, completedCount: progress.translatedCount, totalCount: progress.totalCount) ?? PipelineStepTitle.display("translate")
        }
        if video.subtitleStatus == "translating" {
            return PipelineStepTitle.display("translate")
        }
        if video.subtitleStatus == "running" {
            return L10n.string("common.subtitles_in_preparation", fallback: "Subtitles in preparation")
        }
        if video.enReady {
            return L10n.string("common.english_subtitles", fallback: "English subtitles")
        }
        return L10n.string("ytchannel_detail.subtitles_not_requested", fallback: "Subtitles not requested")
    }

    private var statusIcon: String {
        if video.bilingualSubtitlesCompleted { return "checkmark.circle" }
        if video.subtitleStatus == "failed" { return "exclamationmark.triangle" }
        if video.subtitleStatus == "running" || video.subtitleStatus == "translating" { return "clock" }
        if video.enReady { return "text.quote" }
        return "captions.bubble"
    }

    private var statusTone: LinguaStatusChip.Tone {
        if video.bilingualSubtitlesCompleted { return .success }
        if video.subtitleStatus == "failed" { return .danger }
        if video.subtitleStatus == "running" || video.subtitleStatus == "translating" { return .warning }
        if video.enReady { return .accent }
        return .neutral
    }

    private var progress: YTSubtitleTranslationProgress? {
        guard let totalCount = video.subtitleTotalCount, totalCount > 0 else { return nil }
        return YTSubtitleTranslationProgress(
            translatedCount: video.subtitleTranslatedCount ?? 0,
            totalCount: totalCount
        )
    }

    private var playbackProgressValue: Double? {
        guard let position = video.playbackPositionSeconds,
              let duration = video.playbackDurationSeconds,
              duration > 0
        else { return nil }
        return min(max(position / duration, 0), 1)
    }
}
#endif

private struct YTVideoNavigationRowLabel: View {
    @Environment(\.isFocused) private var isFocused
    var video: YTVideoRecord

    var body: some View {
        LinguaCard(padding: 14) {
            HStack(spacing: 14) {
                YTVideoThumbnail(video: video)
                YTVideoRow(video: video)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                #if os(tvOS)
                if isFocused {
                    Label(L10n.string("episode_detail.play", fallback: "Play"), systemImage: "play.fill")
                        .font(.callout.bold())
                        .foregroundStyle(LinguaTheme.accent)
                }
                #else
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                #endif
            }
        }
        .contentShape(Rectangle())
    }
}

private struct YTVideoThumbnail: View {
    var video: YTVideoRecord

    var body: some View {
        Group {
            if let url = thumbnailURL {
                RemoteMediaImage(
                    url: url,
                    displaySize: CGSize(width: thumbnailWidth, height: thumbnailHeight)
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ZStack {
                            placeholder
                            ProgressView()
                        }
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var placeholder: some View {
        LinguaMediaPlaceholder(systemImage: "play.rectangle")
    }

    private var thumbnailURL: URL? {
        guard let thumbnail = video.thumbnail else { return nil }
        return URL(string: thumbnail)
    }

    private var thumbnailWidth: CGFloat {
        #if os(tvOS)
        192
        #else
        112
        #endif
    }

    private var thumbnailHeight: CGFloat {
        thumbnailWidth * 9 / 16
    }
}

private struct YTVideoRow: View {
    var video: YTVideoRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(video.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Label(statusText, systemImage: statusIcon)
                if let publishedAt = video.publishedAt {
                    Text(publishedAt, style: .date)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if showsTranslationProgress, let progress {
                LinguaProgressBar(value: progress.fraction)
            }
            if let playbackText {
                HStack(spacing: 8) {
                    Label(playbackText, systemImage: playbackIcon)
                    if let playbackUpdatedAt = video.playbackUpdatedAt {
                        Text(playbackUpdatedAt, style: .date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let playbackProgressValue {
                LinguaProgressBar(value: playbackProgressValue)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("media.playback-progress")
                    .accessibilityValue(Text(verbatim: "ltr"))
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if video.bilingualSubtitlesCompleted { return L10n.string("common.bilingual_subtitles", fallback: "bilingual subtitles") }
        if video.subtitleStatus == "failed" { return L10n.string("common.subtitles_failed", fallback: "Subtitles failed") }
        if video.subtitleStatus == "running" { return L10n.string("common.subtitles_in_preparation", fallback: "Subtitles in preparation") }
        if video.subtitleStatus == "translating" {
            if let progress {
                return YTSourceGenerationProgressText.title(step: "translating", progress: nil, completedCount: progress.translatedCount, totalCount: progress.totalCount) ?? PipelineStepTitle.display("translate")
            }
            return PipelineStepTitle.display("translate")
        }
        if video.subtitleStatus == "partial" {
            if let progress {
                return L10n.format("subtitles.retry_progress", fallback: "Translation retry pending %@/%@", String(progress.translatedCount), String(progress.totalCount))
            }
            return L10n.string("ytchannel_detail.translation_to_be_retried", fallback: "Translation to be retried")
        }
        if video.enReady { return L10n.string("common.english_subtitles", fallback: "English subtitles") }
        return L10n.string("ytchannel_detail.subtitles_not_requested", fallback: "Subtitles not requested")
    }

    private var statusIcon: String {
        if video.bilingualSubtitlesCompleted { return "checkmark.circle" }
        if video.subtitleStatus == "failed" { return "exclamationmark.triangle" }
        if video.subtitleStatus == "partial" { return "arrow.clockwise" }
        if video.subtitleStatus == "running" || video.subtitleStatus == "translating" { return "clock" }
        if video.enReady { return "text.quote" }
        return "captions.bubble"
    }

    private var showsTranslationProgress: Bool {
        video.subtitleStatus == "translating" || video.subtitleStatus == "partial"
    }

    private var progress: YTSubtitleTranslationProgress? {
        guard let totalCount = video.subtitleTotalCount, totalCount > 0 else { return nil }
        return YTSubtitleTranslationProgress(
            translatedCount: video.subtitleTranslatedCount ?? 0,
            totalCount: totalCount
        )
    }

    private var playbackCategory: PlaybackListCategory {
        PlaybackListPolicy.category(
            playbackPosition: video.playbackPositionSeconds,
            duration: video.playbackDurationSeconds,
            completedAt: video.playbackCompletedAt
        )
    }

    private var playbackText: String? {
        switch playbackCategory {
        case .unplayed:
            return nil
        case .inProgress:
            if let playbackProgressValue {
                return L10n.format(
                    "playback.progress",
                    fallback: "Played %@",
                    playbackProgressValue.formatted(.percent.precision(.fractionLength(0)))
                )
            }
            return formattedPosition.map { L10n.format("playback.position", fallback: "Played to %@", $0) }
        case .played:
            return L10n.string("common.played", fallback: "Played")
        }
    }

    private var playbackIcon: String {
        playbackCategory == .played ? "checkmark.circle" : "clock"
    }

    private var playbackProgressValue: Double? {
        guard let position = video.playbackPositionSeconds,
              let duration = video.playbackDurationSeconds,
              position.isFinite,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }
        return min(max(position / duration, 0), 1)
    }

    private var formattedPosition: String? {
        guard let position = video.playbackPositionSeconds,
              position.isFinite,
              position >= PlaybackProgressPolicy.minimumRestorablePosition
        else {
            return nil
        }
        let totalSeconds = Int(position.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
