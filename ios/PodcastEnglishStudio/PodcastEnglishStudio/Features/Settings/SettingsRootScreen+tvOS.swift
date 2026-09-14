import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

#if os(tvOS)
struct TVSettingsRootScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(CloudSyncCoordinator.self) private var cloudSync
    @Environment(SettingsNavigation.self) private var settingsNavigation
    @State private var path: [TVSettingsRoute] = []
    @State private var showingMobileSetup = false
    @State private var showingClearSubtitleCacheConfirmation = false
    @State private var localMedia = TVSettingsLocalMediaModel()
    @State private var commitCoordinator: TVSettingsCommitCoordinator?
    @State private var cloudActiveJobCount = 0
    @State private var lastFocusIDs: [String: String] = [:]

    var body: some View {
        NavigationStack(path: $path) {
            categoryScreen(for: .root)
                .navigationDestination(for: TVSettingsRoute.self) { route in
                    destination(route)
                }
        }
        .accessibilityIdentifier("screen.settings")
        .toolbar(.hidden, for: .automatic)
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
            if commitCoordinator == nil {
                commitCoordinator = TVSettingsCommitCoordinator(settings: settings)
            }
            applyPendingDestination()
        }
        .onChange(of: settingsNavigation.pendingDestination) { _, _ in
            applyPendingDestination()
        }
        .onChange(of: settingsNavigation.pathResetID) { _, _ in
            commitCoordinator?.flush()
            path = []
        }
        .onDisappear {
            commitCoordinator?.flush()
        }
        .task {
            guard !UITestSupport.isEnabled else { return }
            guard let store = try? RemoteContentJobStore() else { return }
            cloudActiveJobCount = (try? await store.nonTerminalSnapshots().count) ?? 0
        }
    }

    @ViewBuilder
    private func destination(_ route: TVSettingsRoute) -> some View {
        switch route {
        case .category(let destination):
            categoryScreen(for: destination)
        case .generationBackend:
            optionScreen(
                title: L10n.string("settings.generation_backend", fallback: "Generation Backend"),
                options: [
                    TVSettingsOption(
                        value: GenerationBackend.cloud,
                        title: L10n.string("settings.generation_backend_cloud", fallback: "Cloud Service"),
                        help: L10n.string(
                            "settings.generation_backend_cloud.help",
                            fallback: "Run transcription and translation on your server."
                        ),
                        icon: "cloud.fill"
                    ),
                    TVSettingsOption(
                        value: GenerationBackend.local,
                        title: L10n.string("settings.generation_backend_local", fallback: "On-Device (Legacy)"),
                        help: L10n.string(
                            "settings.generation_backend_local.help",
                            fallback: "Use DashScope and translation keys stored on this device."
                        ),
                        icon: "internaldrive"
                    )
                ],
                current: settings.configuration.generationBackendMode,
                onSelect: { value in
                    settings.configuration.generationBackendMode = value
                    commitCoordinator?.requestSave()
                }
            )
        case .translationQuality:
            optionScreen(
                title: L10n.string("settings.translation_quality_mode", fallback: "Translation Quality"),
                options: [
                    TVSettingsOption(
                        value: TranslationQualityMode.quality,
                        title: L10n.string("settings.translation_quality_quality", fallback: "Quality (reflective)"),
                        help: L10n.string(
                            "settings.translation_quality_quality.help",
                            fallback: "Translates, then refines each line."
                        ),
                        icon: "slider.horizontal.3"
                    ),
                    TVSettingsOption(
                        value: TranslationQualityMode.fast,
                        title: L10n.string("settings.translation_quality_fast", fallback: "Fast (direct)"),
                        help: L10n.string(
                            "settings.translation_quality_fast.help",
                            fallback: "Translates in a single pass."
                        ),
                        icon: "hare"
                    )
                ],
                current: settings.configuration.translationQuality,
                onSelect: { value in
                    settings.configuration.translationQuality = value
                    commitCoordinator?.requestSave()
                }
            )
        case .englishSize:
            optionScreen(
                title: L10n.string("settings.subtitle_english_size", fallback: "English Size"),
                options: englishSizeOptions,
                current: settings.configuration.subtitleEnglishSizeLevel,
                onSelect: { value in
                    settings.configuration.subtitleEnglishSizeLevel = value
                    commitCoordinator?.requestSave()
                }
            )
        case .targetScale:
            optionScreen(
                title: L10n.string("settings.subtitle_target_scale", fallback: "Translation Size"),
                options: targetScaleOptions,
                current: settings.configuration.subtitleTargetScalePercent,
                onSelect: { value in
                    settings.configuration.subtitleTargetScalePercent = value
                    commitCoordinator?.requestSave()
                }
            )
        case .subtitleOrder:
            optionScreen(
                title: L10n.string("settings.subtitle_order", fallback: "Line Order"),
                options: [
                    TVSettingsOption(
                        value: SubtitleOrder.englishFirst.rawValue,
                        title: L10n.string("settings.subtitle_order_english_first", fallback: "English first"),
                        help: L10n.string(
                            "settings.subtitle_order_help",
                            fallback: "Choose which language appears on the top line."
                        ),
                        icon: "arrow.up.arrow.down"
                    ),
                    TVSettingsOption(
                        value: SubtitleOrder.targetFirst.rawValue,
                        title: L10n.format(
                            "settings.subtitle_order_target_first",
                            fallback: "%@ first",
                            settings.configuration.translationTarget.autonym
                        ),
                        help: L10n.string(
                            "settings.subtitle_order_help",
                            fallback: "Choose which language appears on the top line."
                        ),
                        icon: "arrow.up.arrow.down"
                    )
                ],
                current: settings.configuration.subtitleOrder,
                onSelect: { value in
                    settings.configuration.subtitleOrder = value
                    commitCoordinator?.requestSave()
                }
            )
        case .localMediaMode:
            optionScreen(
                title: L10n.string("settings.local_media_mode", fallback: "Mode"),
                options: [
                    TVSettingsOption(
                        value: YTLocalMediaMode.mp4,
                        title: L10n.string("settings.local_media_mode_mp4", fallback: "MP4"),
                        help: L10n.string(
                            "settings.local_media_mode.help",
                            fallback: "MP4 downloads a file. HLS streams adaptive video."
                        ),
                        icon: "film"
                    ),
                    TVSettingsOption(
                        value: YTLocalMediaMode.hls,
                        title: L10n.string("settings.local_media_mode_hls", fallback: "HLS"),
                        help: L10n.string(
                            "settings.local_media_mode.help",
                            fallback: "MP4 downloads a file. HLS streams adaptive video."
                        ),
                        icon: "film"
                    )
                ],
                current: localMedia.mode,
                onSelect: { localMedia.setMode($0) }
            )
        case .localMediaHeight:
            optionScreen(
                title: L10n.string("settings.local_media_height", fallback: "Preferred height"),
                options: [
                    TVSettingsOption(
                        value: 720,
                        title: L10n.string("settings.local_media_height_720", fallback: "720p"),
                        help: L10n.string(
                            "settings.local_media_height.help",
                            fallback: "720p uses less disk. 1080p is sharper."
                        ),
                        icon: "rectangle"
                    ),
                    TVSettingsOption(
                        value: 1080,
                        title: L10n.string("settings.local_media_height_1080", fallback: "1080p"),
                        help: L10n.string(
                            "settings.local_media_height.help",
                            fallback: "720p uses less disk. 1080p is sharper."
                        ),
                        icon: "rectangle"
                    )
                ],
                current: localMedia.preferredHeight,
                onSelect: { localMedia.setPreferredHeight($0) }
            )
        }
    }

    private func categoryScreen(for destination: SettingsDestination) -> some View {
        let readiness = ConfigurationReadiness(configuration: settings.configuration)
        let model = TVSettingsCatalog.categoryModel(
            destination,
            settings: settings,
            cloudSync: cloudSync,
            localMedia: localMedia,
            cloudActiveJobCount: cloudActiveJobCount,
            readiness: readiness
        )
        return TVSettingsScene(
            model: model,
            iconColor: SettingsStatusFormatting.syncStatusColor(phase: cloudSync.phase),
            statusForRow: { row in
                if destination == .iCloudSync || row.id == "icloud" {
                    return cloudSync.statusDetail
                }
                return nil
            },
            initialFocusID: lastFocusIDs[focusKey(for: destination)]
        ) {
            SubtitlePresentationPreview(
                presentation: settings.configuration.subtitlePresentation,
                targetLanguage: settings.configuration.translationTarget
            )
        } onActivate: { row in
            activate(row, on: destination)
        } onFocusedRowChange: { row in
            if let row {
                lastFocusIDs[focusKey(for: destination)] = row.id
            }
        }
        .toolbar(.hidden, for: .automatic)
        .navigationBarBackButtonHidden(false)
    }

    private func optionScreen<Value: Hashable>(
        title: String,
        options: [TVSettingsOption<Value>],
        current: Value,
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        TVSettingsOptionScreen(
            title: title,
            options: options,
            current: current,
            onSelect: onSelect
        )
    }

    private var englishSizeOptions: [TVSettingsOption<Int>] {
        let presentation = settings.configuration.subtitlePresentation
        return Array(
            SubtitlePresentationPreferences.minimumEnglishSizeLevel
                ... SubtitlePresentationPreferences.maximumEnglishSizeLevel
        ).map { level in
            TVSettingsOption(
                value: level,
                title: SubtitleOptionLabels.englishSize(
                    level: level,
                    scalePercent: presentation.targetScalePercent,
                    order: presentation.order,
                    platform: .current
                ),
                help: L10n.string(
                    "settings.subtitle_english_size_help",
                    fallback: "English subtitle size from level 1 (smallest) to 9 (largest)."
                ),
                icon: "textformat.size"
            )
        }
    }

    private var targetScaleOptions: [TVSettingsOption<Int>] {
        let presentation = settings.configuration.subtitlePresentation
        return SubtitlePresentationPreferences.targetScalePercentOptions.map { percent in
            TVSettingsOption(
                value: percent,
                title: SubtitleOptionLabels.targetScale(
                    percent: percent,
                    englishSizeLevel: presentation.englishSizeLevel,
                    order: presentation.order,
                    platform: .current
                ),
                help: L10n.format(
                    "settings.subtitle_target_scale_help",
                    fallback: "Translation size as a percentage of English size. Current translation language: %@.",
                    settings.configuration.translationTarget.autonym
                ),
                icon: "textformat.size.smaller"
            )
        }
    }

    private func activate(_ row: TVSettingsRowDescriptor, on destination: SettingsDestination) {
        switch row.kind {
        case .disclosure(let route), .value(let route):
            path.append(route)
        case .toggle(let isOn, _):
            applyToggle(rowID: row.id, currentlyOn: isOn, destination: destination)
        case .action:
            applyAction(rowID: row.id, destination: destination)
        case .info:
            break
        }
    }

    private func applyToggle(rowID: String, currentlyOn: Bool, destination: SettingsDestination) {
        switch destination {
        case .cloudService:
            settings.configuration.contentServiceEnabled = !currentlyOn
            commitCoordinator?.requestSave()
        case .contentFilter:
            settings.configuration.contentFilterEnabled = !currentlyOn
            commitCoordinator?.requestSave()
        case .localMedia:
            localMedia.setEnabled(!currentlyOn)
        default:
            break
        }
    }

    private func applyAction(rowID: String, destination: SettingsDestination) {
        switch rowID {
        case "mobile-setup":
            showingMobileSetup = true
        case "sync-now":
            guard !UITestSupport.isEnabled else { return }
            Task { await cloudSync.syncNow() }
        case "confirm-merge":
            cloudSync.confirmAccountMigration()
        case "clear-cache":
            showingClearSubtitleCacheConfirmation = true
        default:
            if destination == .root && rowID == "mobile-setup" {
                showingMobileSetup = true
            }
        }
    }

    private func applyPendingDestination() {
        guard let pending = settingsNavigation.consumePendingDestination() else { return }
        if pending == .root {
            path = []
        } else {
            path = [.category(pending)]
        }
    }

    private func focusKey(for destination: SettingsDestination) -> String {
        destination.rawValue
    }
}
#endif
