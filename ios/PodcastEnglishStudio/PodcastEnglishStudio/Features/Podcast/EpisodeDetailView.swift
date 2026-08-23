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
            ContentUnavailableView(L10n.string("common.the_single_episode_does_not_exist", fallback: "The single episode does not exist"), systemImage: "exclamationmark.triangle")
        }
    }
}

struct EpisodeDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) var scenePhase
    @Environment(SettingsStore.self) var settings
    @Environment(PipelineRunner.self) var runner
    @Query var podcastSubscriptions: [PodcastSubscription]
    let episode: EpisodeRecord
    var onOpenSettings: () -> Void = {}
    let fileStore = LocalFileStore()

    @State var showChinese = true
    @State var isFollowingPlayback = true
    @State var locatePlaybackRequest = 0
    @State var hasInitializedScroll = false
    @State var scrollPositionSequence: Int?
    @State var player = AudioPlaybackController()
    @State var segments: [LearningSegment] = []
    @State var isLoadingSegments = false
    @State var segmentLoadError: String?
    @State var isRepairingAudio = false
    @State var lastPersistedPlaybackTime: TimeInterval?
    @State var lastPersistedPlaybackAt: Date?
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
            guard episode.status == "completed" else { return }
            await loadSegmentsForEpisode()
            persistPlaybackDurationIfNeeded()
            await loadAudioForPlayback()
        }
        .task(id: playerArtworkPrefetchToken) {
            await ArtworkPrefetchService.shared.prefetchUntilCancelled(
                urls: playerArtworkPrefetchURLs(),
                token: playerArtworkPrefetchToken
            )
        }
        .onDisappear {
            persistPlaybackProgress(player.currentTime, force: true)
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
