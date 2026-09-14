import SwiftData
import SwiftUI
import UIKit
import CloudSyncKit
import DomainModels

@main
struct PodcastEnglishStudioApp: App {
    @State private var settings: SettingsStore
    @State private var runner = PipelineRunner()
    @State private var cloudSync = CloudSyncCoordinator.shared
    @State private var catalogRecovery: PlaybackCatalogRecoveryCoordinator
    @State private var settingsNavigation = SettingsNavigation()
    private let modelContainer: ModelContainer

    init() {
        UITestSupport.installNetworkBlocker()
        RemoteMediaImageCache.configure(forUITesting: UITestSupport.isEnabled)
        // CloudSyncKit 不依赖 UIKit / app 层文件存储：远程通知注册与
        // 升级回填所需的 legacy segments 文件位置均由 app 侧注入。
        let coordinator = CloudSyncCoordinator.shared
        coordinator.remoteNotificationRegistrar = {
            UIApplication.shared.registerForRemoteNotifications()
        }
        coordinator.legacyPodcastSegmentsURLProvider = { episodeID in
            try? LocalFileStore().episodeFiles(episodeID: episodeID).segments
        }
        coordinator.legacyYouTubeSegmentsURLProvider = { videoID in
            try? YTSubtitleFileStore().files(videoID: videoID).segments
        }
        // Inject the targeted podcast RSS fetch used by continue-playing catalog recovery.
        coordinator.podcastFeedFetcher = PodcastFeedService()
        let settingsStore = UITestSupport.isEnabled
            ? SettingsStore(configuration: UITestSupport.fixtureConfiguration)
            : SettingsStore()
        // Inject the targeted YouTube videos.list fetch (reads the latest API key lazily).
        let ytService = YTLocalService()
        coordinator.youTubeVideoDetailsFetcher = AppYouTubeVideoDetailsFetcher(
            service: ytService,
            configurationProvider: { [settingsStore] in settingsStore.configuration }
        )
        _settings = State(initialValue: settingsStore)

        let schema = Schema([
            PodcastSubscription.self,
            EpisodeRecord.self,
            SegmentRecord.self,
            TranslationVariantRecord.self,
            YTChannelRecord.self,
            YTVideoRecord.self,
            // V10/WP14: registering the remote job record activates WP13's
            // in-context persistence (YTRemoteContentJobStore detects it here)
            // and lets detail views read audioReady/retryable snapshots.
            RemoteContentJobRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: UITestSupport.isEnabled,
            cloudKitDatabase: .none
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create the local model container: \(error)")
        }
        // Synchronize-and-recover orchestration: one operation, deduplicated across triggers.
        let container = modelContainer
        _catalogRecovery = State(initialValue: PlaybackCatalogRecoveryCoordinator(
            cloudSync: coordinator,
            contextProvider: { container.mainContext }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(runner)
                .environment(cloudSync)
                .environment(catalogRecovery)
                .environment(settingsNavigation)
                .onOpenURL { url in
                    #if os(iOS)
                    _ = PlaybackDeepLinkCoordinator.shared.handle(url)
                    #endif
                }
        }
        .modelContainer(modelContainer)
    }
}
