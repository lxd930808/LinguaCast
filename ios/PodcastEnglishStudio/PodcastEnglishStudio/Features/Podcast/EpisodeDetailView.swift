import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit
import PlayerKit

struct EpisodeDetailRouteView: View {
    @Query private var episodes: [EpisodeRecord]
    var onOpenSettings: () -> Void

    init(episodeID: String, onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
        _episodes = Query(
            filter: #Predicate<EpisodeRecord> { $0.id == episodeID }
        )
    }

    var body: some View {
        if let episode = episodes.first {
            EpisodeDetailView(episode: episode, onOpenSettings: onOpenSettings)
        } else {
            LinguaEmptyState(L10n.string("common.the_single_episode_does_not_exist", fallback: "The single episode does not exist"), systemImage: "exclamationmark.triangle", kind: .failure)
        }
    }
}

struct EpisodeDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) var scenePhase
    @Environment(SettingsStore.self) var settings
    @Environment(PipelineRunner.self) var runner
    @Environment(SettingsNavigation.self) var settingsNavigation
    @Query var podcastSubscriptions: [PodcastSubscription]
    let episode: EpisodeRecord
    var onOpenSettings: () -> Void = {}
    let fileStore = LocalFileStore()

    @State var showChinese = true
    @State var isFollowingPlayback = true
    @State var locatePlaybackRequest = 0
    @State var hasInitializedScroll = false
    @State var scrollPositionSequence: Int?
    @State var transcriptScrollTask: Task<Void, Never>?
    #if os(iOS)
    @State var chinesePlayer = EpisodeChinesePlayback()
    @State var showingPlaybackSettings = false
    #endif
    @State var player = AudioPlaybackController()
    @State var segments: [LearningSegment] = []
    @State var isLoadingSegments = false
    @State var segmentLoadError: String?
    @State var isRepairingAudio = false
    @State var lastPersistedPlaybackTime: TimeInterval?
    @State var lastPersistedPlaybackAt: Date?
    /// Cached remote-job snapshot for the cloud backend (WP14); refreshed on
    /// appear and whenever the episode record changes (each poll updates it).
    @State var cloudJobSnapshot: CloudRemoteJobSnapshot?
    /// Lazily created WP11 store handle for production remote-job lookups.
    @State var remoteJobStore: RemoteContentJobStore?
    /// True after inactive/background handling until the next user-started play restores follow.
    @State var restoreFollowOnNextPlay = false
    /// Prevents treating the initial `.active` scene phase as a lock-screen resume.
    @State var hasSuspendedForScenePhase = false
    #if os(tvOS)
    @FocusState var focusedTranscriptSequence: Int?
    #endif

    var body: some View {
        platformBody
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.podcast-player")
        .task(id: "\(episode.id):\(episode.status):\(settings.configuration.translationTargetLanguage)") {
            lastPersistedPlaybackTime = episode.playbackPositionSeconds
            lastPersistedPlaybackAt = episode.playbackUpdatedAt
            refreshCloudJobSnapshot()
            // WP14 task 3: when a poll flips the episode to completed, this
            // task re-runs (status is part of the id) and loads the freshly
            // installed segments/audio automatically.
            guard episode.status == "completed" else { return }
            await loadSegmentsForEpisode()
            persistPlaybackDurationIfNeeded()
            await loadAudioForPlayback()
            #if os(iOS)
            #if DEBUG
            if UITestSupport.isEnabled,
               ProcessInfo.processInfo.environment["LINGUACAST_UI_REPLAY_CHINESE_SENTENCES"] == "1" {
                // Replay sentence-boundary UI updates after initial transcript invalidation settles.
                try? await Task.sleep(for: .milliseconds(500))
                chinesePlayer.duration = Double(segments.last?.endMS ?? 0) / 1000
                chinesePlayer.isSelected = true
                for sequence in 772...777 {
                    guard !Task.isCancelled else { return }
                    chinesePlayer.activeSequence = sequence
                    for tick in 0..<20 {
                        chinesePlayer.originalTime = Double(segments.first { $0.sequence == sequence }?.startMS ?? 0) / 1000 + Double(tick) * 0.1
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                return
            }
            #endif
            if !chinesePlayer.isSelected {
                chinesePlayer.restore(episodeID: episode.id, language: settings.configuration.translationTargetLanguage,
                    rows: segments, original: AudioPlaybackControllerBridge(title: episode.episodeTitle, time: player.currentTime, duration: player.duration,
                        rate: player.playbackRate, isPlaying: false, pause: { player.pausePlayback() }))
            }
            #endif
        }
        .onChange(of: episode.updatedAt) { _, _ in
            refreshCloudJobSnapshot()
        }
        .task(id: playerArtworkPrefetchToken) {
            await ArtworkPrefetchService.shared.prefetchUntilCancelled(
                urls: playerArtworkPrefetchURLs(),
                token: playerArtworkPrefetchToken
            )
        }
        .onDisappear {
            #if os(iOS)
            if chinesePlayer.isSelected {
                persistPlaybackProgress(chinesePlayer.originalTime, force: true, allowCompletion: false)
                chinesePlayer.stop()
            } else { persistPlaybackProgress(player.currentTime, force: true) }
            #else
            persistPlaybackProgress(player.currentTime, force: true)
            #endif
            if player.isPlaying {
                player.pausePlayback()
            }
        }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iOSBody
        #endif
    }

    private var playerArtworkPrefetchToken: String {
        "player:\(episode.id)"
    }

    private func playerArtworkPrefetchURLs() -> [URL] {
        let fallback = fallbackPodcastArtworkURL.flatMap(URL.init(string:))
        let current = episode.artworkURL.flatMap(URL.init(string:)) ?? fallback
        guard let subscriptionID = episode.subscriptionID else {
            return ArtworkPrefetchPolicy.playerNeighborURLs(
                current: current,
                orderedEpisodeURLs: [],
                currentIndex: nil
            )
        }
        let descriptor = FetchDescriptor<EpisodeRecord>(
            predicate: #Predicate { $0.subscriptionID == subscriptionID },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        let siblings = (try? modelContext.fetch(descriptor)) ?? []
        let orderedURLs: [URL] = siblings.compactMap { sibling in
            if let value = sibling.artworkURL, let url = URL(string: value) { return url }
            return fallback
        }
        let currentIndex = siblings.firstIndex(where: { $0.id == episode.id })
        return ArtworkPrefetchPolicy.playerNeighborURLs(
            current: current,
            orderedEpisodeURLs: orderedURLs,
            currentIndex: currentIndex
        )
    }

    var fallbackPodcastArtworkURL: String? {
        guard let subscriptionID = episode.subscriptionID else { return nil }
        return podcastSubscriptions.first { $0.id == subscriptionID }?.artworkURL
    }

    var fallbackPodcastArtworkSource: PodcastArtworkSource? {
        guard let subscriptionID = episode.subscriptionID else { return nil }
        return podcastSubscriptions.first { $0.id == subscriptionID }?.artworkSourceKind
    }
}

func formatTime(_ ms: Int) -> String {
    let total = ms / 1000
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = max(0, Int(seconds.rounded(.down)))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}
