import SwiftUI
import SwiftData
import PodcastEnglishStudioCore
import CloudSyncKit
import DomainModels

enum AppTab: Hashable {
    case home
    case programs
    case subscriptions
    #if os(iOS)
    case assistant
    #endif
    case settings
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings
    @Environment(CloudSyncCoordinator.self) private var cloudSync
    @Environment(PlaybackCatalogRecoveryCoordinator.self) private var catalogRecovery
    @Environment(PipelineRunner.self) private var runner
    @Environment(SettingsNavigation.self) private var settingsNavigation
    @State private var selectedTab: AppTab
    @State private var youtubeService = YTLocalService()
    @State private var isBootstrappingCatalogs = false
    @State private var showingAccountSignIn = false

    init() {
        _selectedTab = State(initialValue: UITestSupport.isEnabled ? UITestSupport.initialTab : .home)
    }

    var body: some View {
        Group {
            if UITestSupport.isEnabled, UITestSupport.scenario.usesDirectScene {
                UITestScenarioView(scenario: UITestSupport.scenario)
            } else {
                tabContent
            }
        }
        .overlay(alignment: .topLeading) {
            LinguaThemeAppearanceProbe()
        }
        .preferredColorScheme(UITestSupport.colorSchemeOverride)
        .tint(LinguaTheme.accent)
        .sheet(isPresented: $showingAccountSignIn) {
            AccountSignInSheet()
        }
        .task {
            if UITestSupport.isEnabled {
                UITestSupport.installFixtures(in: modelContext)
                runner.reconcileCompletions(context: modelContext)
                // Fake cloud scenarios (WP14) pin static fixture states; the
                // orphan resumer would re-schedule them against the blocked
                // network and overwrite the fixture.
                if !UITestSupport.scenario.usesFakeCloudState && UITestSupport.scenario != .podcastRunning {
                    runner.resumeOrphanedPipelines(
                        context: modelContext,
                        configuration: settings.configuration
                    )
                }
            } else {
                // Account restore runs beside the launch reconcile so offline launches stay fast.
                Task {
                    await AccountController.shared.start()
                    if AccountController.shared.consumeFirstLaunchPrompt() {
                        showingAccountSignIn = true
                    }
                }
                runner.reconcileCompletions(context: modelContext)
                runner.resumeOrphanedPipelines(
                    context: modelContext,
                    configuration: settings.configuration
                )
                // WP14 lifecycle: explicit launch reconcile of remote content
                // jobs (adopt jobs submitted before the last quit).
                await runner.reconcileRemoteJobs(
                    context: modelContext,
                    configuration: settings.configuration
                )
                cloudSync.start(context: modelContext, settings: settings)
                // App finished launching: synchronize and recover the continue-playing catalog.
                await catalogRecovery.synchronizeAndRecover(trigger: .automatic)
                await bootstrapMissingCatalogs()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !UITestSupport.isEnabled else { return }
            // WP14 lifecycle: entering the background stops the high-frequency
            // cloud polling loops; the remote records persist, and returning
            // to the foreground re-attaches via reconcile.
            if phase == .background {
                stopHighFrequencyCloudPolling()
                return
            }
            guard phase == .active else { return }
            Task { await AccountController.shared.refreshIfNeeded() }
            runner.reconcileCompletions(context: modelContext)
            runner.resumeOrphanedPipelines(
                context: modelContext,
                configuration: settings.configuration
            )
            // Returning to the foreground reuses the in-flight recovery task (deduplicated).
            Task {
                // WP14 lifecycle: foreground reconcile of remote content jobs.
                await runner.reconcileRemoteJobs(
                    context: modelContext,
                    configuration: settings.configuration
                )
                await catalogRecovery.synchronizeAndRecover(trigger: .automatic)
                await bootstrapMissingCatalogs()
            }
        }
        .onChange(of: settingsNavigation.pendingDestination) { _, destination in
            if destination != nil {
                selectedTab = .settings
            }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if oldTab == .settings && newTab != .settings {
                settingsNavigation.resetPathOnLeavingSettings()
            }
        }
    }

    /// Stops cloud polling before suspension: every `running` episode task is a
    /// remote-job observation loop, so cancelling it is safe; the next foreground
    /// reconcile resumes from the persisted remote record.
    private func stopHighFrequencyCloudPolling() {
        let running = (try? modelContext.fetch(FetchDescriptor<EpisodeRecord>(
            predicate: #Predicate { $0.status == "running" }
        ))) ?? []
        for episode in running {
            runner.cancel(episodeID: episode.id)
        }
    }

    @MainActor
    private func bootstrapMissingCatalogs() async {
        guard !isBootstrappingCatalogs else { return }
        isBootstrappingCatalogs = true
        defer { isBootstrappingCatalogs = false }

        let subscriptions = (try? modelContext.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        for subscription in subscriptions where subscription.isEnabled && subscription.lastCheckedAt == nil {
            await runner.refresh(
                subscription: subscription,
                context: modelContext,
                mode: .recent(limit: 50)
            )
        }

        guard !settings.configuration.youtubeAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else { return }
        let channels = (try? modelContext.fetch(FetchDescriptor<YTChannelRecord>())) ?? []
        for channel in channels where channel.isEnabled && channel.lastCheckedAt == nil {
            await youtubeService.refreshChannel(
                channel,
                configuration: settings.configuration,
                context: modelContext
            )
        }
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label(L10n.string("navigation.home", fallback: "Home"), systemImage: "house")
                    .accessibilityIdentifier("tab.home")
            }
            .tag(AppTab.home)

            NavigationStack {
                ProgramsView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label(L10n.string("navigation.programs", fallback: "Programs"), systemImage: "headphones")
                    .accessibilityIdentifier("tab.programs")
            }
            .tag(AppTab.programs)

            NavigationStack {
                SubscriptionsView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label(L10n.string("navigation.subscriptions", fallback: "Subscriptions"), systemImage: "dot.radiowaves.left.and.right")
                    .accessibilityIdentifier("tab.subscriptions")
            }
            .tag(AppTab.subscriptions)

            #if os(iOS)
            NavigationStack {
                AssistantHomeView()
            }
            .tabItem {
                Label(L10n.string("navigation.assistant", fallback: "Assistant"), systemImage: "sparkles")
                    .accessibilityIdentifier("tab.assistant")
            }
            .tag(AppTab.assistant)
            #endif

            #if os(tvOS)
            SettingsView()
                .tabItem {
                    Label(L10n.string("navigation.settings", fallback: "Settings"), systemImage: "gearshape")
                        .accessibilityIdentifier("tab.settings")
                }
                .tag(AppTab.settings)
            #else
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(L10n.string("navigation.settings", fallback: "Settings"), systemImage: "gearshape")
                    .accessibilityIdentifier("tab.settings")
            }
            .tag(AppTab.settings)
            #endif
        }
        #if os(iOS)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(LinguaTheme.backgroundRaised.opacity(0.96), for: .tabBar)
        #endif
    }
}

#Preview {
    RootView()
        .environment(SettingsStore())
        .environment(PipelineRunner())
        .environment(CloudSyncCoordinator.shared)
        .environment(PlaybackCatalogRecoveryCoordinator(cloudSync: .shared) { nil })
        .environment(SettingsNavigation())
        .environment(AccountController.shared)
}

struct ConfigurationReadiness {
    let summary: ConfigurationReadinessSummary

    init(configuration: AppConfiguration) {
        summary = ConfigurationReadinessPolicy.summary(
            youtubeAPIKey: configuration.youtubeAPIKey,
            cloudServiceReady: configuration.isCloudGenerationUsable
        )
    }

    var title: String {
        summary.isComplete
            ? L10n.string("root.configuration_completed", fallback: "Configuration completed")
            : L10n.plural("settings.missing_configuration_count", fallback: "%lld configuration items remaining", count: summary.missingRequirements.count)
    }

    var subtitle: String {
        if summary.isComplete {
            return L10n.string("root.subscriptions_can_be_added_content_refreshed_and_bilingual_subti", fallback: "Subscriptions can be added, content refreshed, and bilingual subtitles generated.")
        }
        if !summary.hasCloudService && !summary.hasYouTubeMetadataKey {
            return L10n.string(
                "root.setup_needs_youtube_key_and_cloud_service",
                fallback: "Add a YouTube Data API key and sign in or connect a server before adding or refreshing content."
            )
        }
        if !summary.hasCloudService {
            return L10n.string(
                "root.setup_needs_cloud_service",
                fallback: "Bilingual subtitle generation requires signing in or connecting a server."
            )
        }
        return L10n.string("root.youtube_channel_list_requires_youtube_data_api_key", fallback: "YouTube Channel list requires YouTube Data API Key.")
    }

    var progress: Double {
        guard summary.totalCount > 0 else { return 1 }
        return Double(summary.completedCount) / Double(summary.totalCount)
    }
}

struct SetupChecklistView: View {
    let readiness: ConfigurationReadiness
    var showsSettingsButton = true
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: readiness.summary.isComplete ? "checkmark.seal.fill" : "key.fill")
                    .font(.title3)
                    .foregroundStyle(readiness.summary.isComplete ? LinguaTheme.success : LinguaTheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(readiness.title)
                        .font(.headline)
                    Text(readiness.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LinguaProgressBar(value: readiness.progress)

            VStack(alignment: .leading, spacing: 8) {
                configurationRow(title: L10n.string("settings.youtube_data_api_key", fallback: "YouTube Data API Key"), requirement: .youtubeAPIKey)
                configurationRow(title: L10n.string("settings.cloud_service", fallback: "Cloud Generation Service"), requirement: .cloudService)
            }
            .font(.caption)

            if showsSettingsButton && !readiness.summary.isComplete {
                Button {
                    onOpenSettings()
                } label: {
                    Label(L10n.string("root.go_to_settings_api_key", fallback: "Go to Settings API Key"), systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier("setup.configuration")
        .padding(.vertical, 4)
    }

    private func configurationRow(title: String, requirement: ConfigurationRequirement) -> some View {
        let isMissing = readiness.summary.missingRequirements.contains(requirement)
        return Label(title, systemImage: isMissing ? "circle" : "checkmark.circle.fill")
            .foregroundStyle(isMissing ? Color.secondary : LinguaTheme.success)
    }
}

struct ActionableEmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String
    var primaryTitle: String
    var primarySystemImage: String
    var primaryAction: () -> Void
    var secondaryTitle: String?
    var secondarySystemImage: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            LinguaEmptyState(title, systemImage: systemImage, description: Text(message), kind: .guidance)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    actionButtons
                }
                VStack(spacing: 10) {
                    actionButtons
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            primaryAction()
        } label: {
            Label(primaryTitle, systemImage: primarySystemImage)
        }
        .buttonStyle(.borderedProminent)

        if let secondaryTitle,
           let secondarySystemImage,
           let secondaryAction {
            Button {
                secondaryAction()
            } label: {
                Label(secondaryTitle, systemImage: secondarySystemImage)
            }
            .buttonStyle(.bordered)
        }
    }
}
