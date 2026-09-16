import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(CloudSyncCoordinator.self) private var cloudSync
    #if os(iOS)
    @State private var showingMobileSetup = false
    @State private var showingAdvancedCloudService = false
    @State private var showingClearSubtitleCacheConfirmation = false
    @State private var saveMessage: String?
    @State private var cloudActiveJobCount = 0
    @State private var localMediaEnabled = false
    @State private var localMediaBaseURL = ""
    @State private var localMediaToken = ""
    @State private var localMediaMode = YTLocalMediaMode.mp4
    @State private var localMediaPreferredHeight = 720
    #endif

    var body: some View {
        #if os(tvOS)
        TVSettingsRootScreen()
        #else
        iOSBody
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSBody: some View {
        @Bindable var settings = settings
        Form {
            Section {
                iOSSettingsOverview
            }
            .listRowBackground(Color.clear)

            AccountSettingsSection()

            Section(L10n.string("settings.icloud_sync", fallback: "iCloud Sync")) {
                Label(cloudSync.statusTitle, systemImage: syncStatusIcon)
                    .foregroundStyle(syncStatusColor)
                Text(cloudSync.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(
                    L10n.string("settings.icloud_subtitle_cache", fallback: "Cloud Subtitle Cache"),
                    value: subtitleCacheSummary
                )
                if cloudSync.subtitleArtifactCount > 0 {
                    Button(
                        L10n.string("settings.clear_icloud_subtitle_cache", fallback: "Clear iCloud Subtitle Cache"),
                        role: .destructive
                    ) {
                        showingClearSubtitleCacheConfirmation = true
                    }
                }
                if cloudSync.phase == .awaitingAccountConfirmation {
                    Button(L10n.string("settings.confirm_merge_into_new_icloud", fallback: "Confirm merge into new iCloud")) {
                        cloudSync.confirmAccountMigration()
                    }
                } else {
                    Button {
                        guard !UITestSupport.isEnabled else { return }
                        Task { await cloudSync.syncNow() }
                    } label: {
                        Label(L10n.string("settings.sync_now", fallback: "Sync now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(UITestSupport.isEnabled || cloudSync.phase == .syncing || cloudSync.phase == .noAccount)
                }
            }

            Section(L10n.string("settings.cloud_service", fallback: "Cloud Generation Service")) {
                cloudServiceFields
            }

            Section(L10n.string("settings.assistant_service", fallback: "Research Assistant Service")) {
                assistantServiceFields
            }

            Section(L10n.string("settings.configuration_progress", fallback: "Setup Progress")) {
                SetupChecklistView(
                    readiness: ConfigurationReadiness(configuration: settings.configuration),
                    showsSettingsButton: false
                ) {}
            }

            Section(L10n.string("common.youtube", fallback: "YouTube")) {
                SecureField(L10n.string("settings.youtube_data_api_key", fallback: "YouTube Data API Key"), text: $settings.configuration.youtubeAPIKey)
                Picker(
                    L10n.string("settings.ios_youtube_playback_mode", fallback: "iOS YouTube Playback"),
                    selection: $settings.configuration.iosYouTubePlaybackMode
                ) {
                    ForEach(IOSYouTubePlaybackMode.uiVisibleCases, id: \.rawValue) { mode in
                        Text(youTubePlaybackModeTitle(mode)).tag(mode.rawValue)
                    }
                }
                Text(L10n.string("settings.used_to_get_channels_video_lists_thumbnails_and_release_times_vi", fallback: "Used to get channels, video lists, thumbnails and release times via the official YouTube Data API v3. Apple TV Playback still retains the current compatible path."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string("settings.translation", fallback: "Translation")) {
                Picker(
                    L10n.string("settings.subtitle_target", fallback: "Subtitle Translation Language"),
                    selection: $settings.configuration.translationTargetLanguage
                ) {
                    ForEach(TranslationTarget.allCases, id: \.rawValue) { target in
                        Text(target.autonym).tag(target.rawValue)
                    }
                }
                Text(L10n.string(
                    "settings.subtitle_target_help",
                    fallback: "New subtitles use this language. Existing translations remain available on this device."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Picker(
                    L10n.string("settings.translation_quality_mode", fallback: "Translation Quality"),
                    selection: $settings.configuration.translationQualityMode
                ) {
                    Text(L10n.string("settings.translation_quality_quality", fallback: "Quality (reflective)"))
                        .tag(TranslationQualityMode.quality.rawValue)
                    Text(L10n.string("settings.translation_quality_fast", fallback: "Fast (direct)"))
                        .tag(TranslationQualityMode.fast.rawValue)
                }
                Text(L10n.string(
                    "settings.translation_quality_mode_help",
                    fallback: "Quality translates then refines each line; Fast translates in a single pass. Applies only to newly generated subtitles."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            AccountServerSection()

            Section(L10n.string("settings.advanced", fallback: "Advanced")) {
                // WP14 task 6: the content-service token lives only in this
                // advanced disclosure (or mobile QR setup) and is masked
                // everywhere else.
                DisclosureGroup(L10n.string("settings.cloud_service_advanced", fallback: "Cloud Service (Advanced)"), isExpanded: $showingAdvancedCloudService) {
                    TextField(L10n.string("settings.cloud_base_url", fallback: "Service Base URL"), text: $settings.configuration.contentServiceBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField(L10n.string("settings.cloud_access_token", fallback: "Access Token"), text: $settings.configuration.contentServiceToken)
                    Text(L10n.string("settings.cloud_token_privacy_note", fallback: "The token is stored in the Keychain and never shown in full."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SubtitlePresentationSettingsSection(settings: settings)

            if let error = settings.lastError {
                Section {
                    Text(error)
                        .foregroundStyle(LinguaTheme.danger)
                }
            }
            if let saveMessage {
                Section {
                    Label(saveMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(LinguaTheme.success)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LinguaScreenBackground())
        .foregroundStyle(LinguaTheme.primaryText)
        .tint(LinguaTheme.accent)
        .accessibilityIdentifier("screen.settings")
        .navigationTitle(L10n.string("navigation.settings", fallback: "Settings"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string("common.save", fallback: "Save")) {
                    persistLocalMediaBackendSettings()
                    let changed = settings.save()
                    saveMessage = changed.isEmpty
                        ? L10n.string("settings.no_changes", fallback: "No settings changed.")
                        : L10n.string("settings.saved_sync_pending", fallback: "Settings saved and waiting for iCloud sync.")
                }
            }
        }
        .sheet(isPresented: $showingMobileSetup) {
            MobileSetupView()
        }
        .confirmationDialog(
            L10n.string("settings.clear_icloud_subtitle_cache", fallback: "Clear iCloud Subtitle Cache"),
            isPresented: $showingClearSubtitleCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string("settings.clear_icloud_subtitle_cache", fallback: "Clear iCloud Subtitle Cache"),
                role: .destructive
            ) {
                Task { await cloudSync.clearCloudSubtitleCache() }
            }
        }
        .onAppear {
            let stored = YTLocalMediaServiceConfig.loadUserDefaults()
            localMediaEnabled = stored.enabled
            localMediaBaseURL = stored.baseURLString
            localMediaToken = stored.token
            localMediaMode = stored.mode
            localMediaPreferredHeight = stored.preferredHeight
        }
        .onDisappear {
            // Drop draft edits that were not committed via Save; players read committed only.
            settings.discardUnsavedChanges()
        }
        .task {
            // WP14 diagnostics: snapshot the in-flight remote job count. Kept
            // out of UI tests so fake cloud states stay fully offline.
            guard !UITestSupport.isEnabled else { return }
            guard let store = try? RemoteContentJobStore() else { return }
            cloudActiveJobCount = (try? await store.nonTerminalSnapshots().count) ?? 0
        }
    }

    private var localMediaBackendFields: some View {
        Group {
            Toggle(
                L10n.string("settings.local_media_enabled", fallback: "Use yt-dlp media service"),
                isOn: $localMediaEnabled
            )
            TextField(
                L10n.string("settings.local_media_base_url", fallback: "Base URL (https://…)"),
                text: $localMediaBaseURL
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            SecureField(
                L10n.string("settings.local_media_token", fallback: "Bearer token"),
                text: $localMediaToken
            )
            Picker(
                L10n.string("settings.local_media_mode", fallback: "Mode"),
                selection: $localMediaMode
            ) {
                Text(L10n.string("settings.local_media_mode_mp4", fallback: "MP4")).tag(YTLocalMediaMode.mp4)
                Text(L10n.string("settings.local_media_mode_hls", fallback: "HLS")).tag(YTLocalMediaMode.hls)
            }
            Picker(
                L10n.string("settings.local_media_height", fallback: "Preferred height"),
                selection: $localMediaPreferredHeight
            ) {
                Text(L10n.string("settings.local_media_height_720", fallback: "720p")).tag(720)
                Text(L10n.string("settings.local_media_height_1080", fallback: "1080p")).tag(1080)
            }
            Text(
                L10n.string(
                    "settings.local_media_help",
                    fallback: "Self-hosted yt-dlp backend for HD. Default 720p saves disk. Leave disabled to use on-device extraction."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func persistLocalMediaBackendSettings() {
        YTLocalMediaServiceConfig.saveUserDefaults(
            enabled: localMediaEnabled,
            baseURLString: localMediaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            token: localMediaToken.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: localMediaMode,
            preferredHeight: localMediaPreferredHeight
        )
        YTPlaybackBackend.resetLocalResolverCache()
    }

    // MARK: - Cloud generation service (V10 / WP14)

    private var cloudServiceStatusTitle: String {
        let configuration = settings.configuration
        guard configuration.contentServiceEnabled else {
            return L10n.string("settings.cloud_status_disabled", fallback: "Disabled")
        }
        guard !configuration.contentServiceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.string("settings.cloud_status_missing_token", fallback: "Access token not configured")
        }
        return L10n.string("settings.cloud_status_ready", fallback: "Ready")
    }

    /// Token is never shown in full (task 6): masked value only.
    private var maskedCloudTokenTitle: String {
        let masked = CloudTokenMasking.masked(settings.configuration.contentServiceToken)
        return masked.isEmpty
            ? L10n.string("settings.cloud_token_not_set", fallback: "Not set")
            : masked
    }

    @ViewBuilder
    private var cloudServiceFields: some View {
        @Bindable var settings = settings
        Toggle(
            L10n.string("settings.cloud_service_enabled", fallback: "Enable Cloud Generation Service"),
            isOn: $settings.configuration.contentServiceEnabled
        )
        .accessibilityIdentifier("settings.cloud-enabled")
        LabeledContent(
            L10n.string("settings.cloud_service_status", fallback: "Status"),
            value: cloudServiceStatusTitle
        )
        .accessibilityIdentifier("settings.cloud-status")
        LabeledContent(
            L10n.string("settings.cloud_base_url", fallback: "Service Base URL"),
            value: settings.configuration.normalizedContentServiceBaseURL
        )
        LabeledContent(
            L10n.string("settings.cloud_access_token", fallback: "Access Token"),
            value: maskedCloudTokenTitle
        )
        .accessibilityIdentifier("settings.cloud-token")
        // Diagnostics (task 5): in-flight remote job count from the WP11 store.
        LabeledContent(
            L10n.string("settings.cloud_active_jobs", fallback: "Active Cloud Jobs"),
            value: String(cloudActiveJobCount)
        )
        .accessibilityIdentifier("settings.cloud-active-jobs")
        Text(L10n.string(
            "settings.cloud_service_help",
            fallback: "Cloud generation runs on your own server, so this device does not need DashScope or translation keys."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var assistantServiceStatusTitle: String {
        let configuration = settings.configuration
        guard configuration.assistantServiceEnabled else {
            return L10n.string("settings.assistant_status_disabled", fallback: "Disabled")
        }
        guard !configuration.assistantServiceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.string("settings.assistant_status_missing_token", fallback: "Access token not configured")
        }
        return L10n.string("settings.assistant_status_ready", fallback: "Ready")
    }

    private var maskedAssistantTokenTitle: String {
        let masked = CloudTokenMasking.masked(settings.configuration.assistantServiceToken)
        return masked.isEmpty
            ? L10n.string("settings.assistant_token_not_set", fallback: "Not set")
            : masked
    }

    @ViewBuilder
    private var assistantServiceFields: some View {
        @Bindable var settings = settings
        Toggle(
            L10n.string("settings.assistant_service_enabled", fallback: "Enable Research Assistant"),
            isOn: $settings.configuration.assistantServiceEnabled
        )
        .accessibilityIdentifier("settings.assistant-enabled")
        LabeledContent(
            L10n.string("settings.assistant_service_status", fallback: "Status"),
            value: assistantServiceStatusTitle
        )
        TextField(
            L10n.string("settings.assistant_base_url", fallback: "Assistant Base URL"),
            text: $settings.configuration.assistantServiceBaseURL
        )
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        .accessibilityIdentifier("settings.assistant-base-url")
        SecureField(
            L10n.string("settings.assistant_access_token", fallback: "Assistant Access Token"),
            text: $settings.configuration.assistantServiceToken
        )
        .accessibilityIdentifier("settings.assistant-token")
        LabeledContent(
            L10n.string("settings.assistant_access_token", fallback: "Assistant Access Token"),
            value: maskedAssistantTokenTitle
        )
        Text(L10n.string(
            "settings.assistant_service_help",
            fallback: "The assistant service is separate from cloud generation. It uses its own HTTPS address and token."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var iOSSettingsOverview: some View {
        let readiness = ConfigurationReadiness(configuration: settings.configuration)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 250, maximum: 520), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            settingsOverviewCard(
                title: L10n.string("settings.icloud_sync", fallback: "iCloud Sync"),
                detail: cloudSync.statusTitle,
                systemImage: syncStatusIcon,
                color: syncStatusColor
            )
            settingsOverviewCard(
                title: L10n.string("settings.configuration_progress", fallback: "Setup Progress"),
                detail: readiness.title,
                systemImage: readiness.summary.isComplete ? "checkmark.seal.fill" : "key.fill",
                color: readiness.summary.isComplete ? LinguaTheme.success : LinguaTheme.warning
            )
            settingsOverviewCard(
                title: L10n.string("settings.subtitles", fallback: "Subtitles"),
                detail: settings.configuration.translationTarget.autonym,
                systemImage: "captions.bubble.fill",
                color: LinguaTheme.accent
            )
        }
        .padding(.vertical, 6)
    }

    private func settingsOverviewCard(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        LinguaCard {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2.bold())
                    .foregroundStyle(color)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitleCacheSummary: String {
        let size = ByteCountFormatter.string(
            fromByteCount: cloudSync.subtitleArtifactByteCount,
            countStyle: .file
        )
        return "\(cloudSync.subtitleArtifactCount) · \(size)"
    }

    private var syncStatusIcon: String {
        switch cloudSync.phase {
        case .synced: "checkmark.icloud"
        case .syncing, .starting: "icloud.and.arrow.up"
        case .noAccount: "icloud.slash"
        case .awaitingAccountConfirmation: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.icloud"
        }
    }

    private var syncStatusColor: Color {
        switch cloudSync.phase {
        case .synced: LinguaTheme.success
        case .failed, .awaitingAccountConfirmation: LinguaTheme.warning
        default: LinguaTheme.secondaryText
        }
    }

    private func youTubePlaybackModeTitle(_ mode: IOSYouTubePlaybackMode) -> String {
        switch mode {
        case .officialIFrame:
            return L10n.string(
                "settings.youtube_playback_official_iframe",
                fallback: "Official YouTube iframe"
            )
        case .localService:
            return L10n.string(
                "settings.youtube_playback_server_subscription",
                fallback: "Server Subscription"
            )
        }
    }
    #endif
}
