import SwiftUI
import UIKit
import PodcastEnglishStudioCore
import CloudSyncKit

#if os(tvOS)
@MainActor
enum TVSettingsCatalog {
    static func rootModel(
        settings: SettingsStore,
        cloudSync: CloudSyncCoordinator,
        localMedia: TVSettingsLocalMediaModel,
        readiness: ConfigurationReadiness
    ) -> TVSettingsScreenModel {
        var groups: [TVSettingsGroup] = []
        if let error = settings.lastError, !error.isEmpty {
            groups.append(
                TVSettingsGroup(title: nil, rows: [
                    infoRow(
                        id: "last-error",
                        title: L10n.string("settings.about.last_error", fallback: "Last Error"),
                        icon: "exclamationmark.triangle",
                        help: error,
                        value: L10n.string("settings.needs_attention", fallback: "Needs attention"),
                        identifier: "settings.last-error"
                    )
                ])
            )
        }
        groups.append(
            TVSettingsGroup(
                title: L10n.string("settings.group.icloud_and_setup", fallback: "iCloud and Setup"),
                rows: [
                    disclosure(
                        id: "icloud",
                        title: L10n.string("settings.icloud_sync", fallback: "iCloud Sync"),
                        icon: SettingsStatusFormatting.syncStatusIcon(phase: cloudSync.phase),
                        help: L10n.string(
                            "settings.icloud_sync.help",
                            fallback: "View sync status, subtitle cache, and sync now."
                        ),
                        summary: cloudSync.statusTitle,
                        route: .category(.iCloudSync),
                        identifier: "settings.row.icloud_sync"
                    ),
                    disclosure(
                        id: "setup",
                        title: L10n.string("settings.configuration_progress", fallback: "Setup Progress"),
                        icon: readiness.summary.isComplete ? "checkmark.seal.fill" : "key.fill",
                        help: L10n.string(
                            "settings.configuration_progress.help",
                            fallback: "See which API keys are still missing."
                        ),
                        summary: readiness.title,
                        route: .category(.setupProgress),
                        identifier: "settings.row.setup_progress"
                    )
                ]
            )
        )
        groups.append(
            TVSettingsGroup(
                title: L10n.string("settings.group.content_generation", fallback: "Content Generation"),
                rows: [
                    disclosure(
                        id: "cloud",
                        title: L10n.string("settings.cloud_service", fallback: "Cloud Generation Service"),
                        icon: "cloud.fill",
                        help: L10n.string(
                            "settings.cloud_service_help",
                            fallback: "Cloud generation runs on your own server, so this device does not need DashScope or translation keys."
                        ),
                        summary: SettingsStatusFormatting.onOff(settings.configuration.contentServiceEnabled),
                        route: .category(.cloudService),
                        identifier: "settings.row.cloud_service"
                    ),
                    disclosure(
                        id: "translation",
                        title: L10n.string("settings.translation", fallback: "Translation"),
                        icon: "globe",
                        help: L10n.string(
                            "settings.translation.help",
                            fallback: "Translation quality and the current subtitle language."
                        ),
                        summary: settings.configuration.translationTarget.autonym,
                        route: .category(.translation),
                        identifier: "settings.row.translation"
                    ),
                    disclosure(
                        id: "filter",
                        title: L10n.string("settings.content_filter", fallback: "Content Filter"),
                        icon: "line.3.horizontal.decrease.circle",
                        help: L10n.string(
                            "settings.content_filter_help",
                            fallback: "Matching episodes and videos are hidden from lists. Keywords apply instantly; the agent instruction uses the configured Translation LLM when available."
                        ),
                        summary: SettingsStatusFormatting.onOff(settings.configuration.contentFilterEnabled),
                        route: .category(.contentFilter),
                        identifier: "settings.row.content_filter"
                    )
                ]
            )
        )
        groups.append(
            TVSettingsGroup(
                title: L10n.string("settings.group.playback_and_subtitles", fallback: "Playback and Subtitles"),
                rows: [
                    disclosure(
                        id: "subtitles",
                        title: L10n.string("settings.subtitles", fallback: "Subtitles"),
                        icon: "captions.bubble.fill",
                        help: L10n.string(
                            "settings.subtitles.help",
                            fallback: "English size, translation size, and line order."
                        ),
                        summary: settings.configuration.translationTarget.autonym,
                        route: .category(.subtitles),
                        identifier: "settings.row.subtitles"
                    ),
                    disclosure(
                        id: "media",
                        title: L10n.string("settings.local_media_backend", fallback: "Cloud / Local Media Backend"),
                        icon: "externaldrive.connected.to.line.below",
                        help: L10n.string(
                            "settings.local_media_help",
                            fallback: "Self-hosted yt-dlp backend for HD. Default 720p saves disk. Leave disabled to use on-device extraction."
                        ),
                        summary: SettingsStatusFormatting.onOff(localMedia.enabled),
                        route: .category(.localMedia),
                        identifier: "settings.row.local_media"
                    )
                ]
            )
        )
        groups.append(
            TVSettingsGroup(
                title: L10n.string("settings.group.other", fallback: "Other"),
                rows: [
                    disclosure(
                        id: "advanced",
                        title: L10n.string("settings.advanced", fallback: "Advanced"),
                        icon: "gearshape.2",
                        help: L10n.string(
                            "settings.advanced.help",
                            fallback: "Optional object storage and TTS. Edit these on iPhone."
                        ),
                        summary: nil,
                        route: .category(.advanced),
                        identifier: "settings.row.advanced"
                    ),
                    disclosure(
                        id: "about",
                        title: L10n.string("settings.about_diagnostics", fallback: "About and Diagnostics"),
                        icon: "info.circle",
                        help: L10n.string(
                            "settings.about_diagnostics.help",
                            fallback: "Version, device, and diagnostic information."
                        ),
                        summary: appVersionText(),
                        route: .category(.about),
                        identifier: "settings.row.about"
                    ),
                    TVSettingsRowDescriptor(
                        id: "mobile-setup",
                        title: L10n.string("settings.mobile_setup", fallback: "Set Up by Phone"),
                        icon: "qrcode",
                        help: L10n.string(
                            "mobile_setup.scan_instructions",
                            fallback: "Scan with the iPhone camera, then configure APIs, Podcast subscriptions, or YouTube channels in Safari."
                        ),
                        kind: .action {},
                        accessory: nil,
                        accessibilityIdentifier: "settings.row.mobile_setup"
                    )
                ]
            )
        )
        return TVSettingsScreenModel(
            title: L10n.string("navigation.settings", fallback: "Settings"),
            defaultIcon: "gearshape",
            defaultHelp: L10n.string(
                "settings.root.help",
                fallback: "Choose a category. Changes apply immediately and sync with iCloud when available."
            ),
            groups: groups
        )
    }

    static func categoryModel(
        _ destination: SettingsDestination,
        settings: SettingsStore,
        cloudSync: CloudSyncCoordinator,
        localMedia: TVSettingsLocalMediaModel,
        cloudActiveJobCount: Int,
        readiness: ConfigurationReadiness
    ) -> TVSettingsScreenModel {
        switch destination {
        case .root:
            return rootModel(
                settings: settings,
                cloudSync: cloudSync,
                localMedia: localMedia,
                readiness: readiness
            )
        case .iCloudSync: return iCloudModel(cloudSync: cloudSync)
        case .setupProgress: return setupModel(readiness: readiness)
        case .cloudService: return cloudModel(settings: settings)
        case .translation: return translationModel(settings: settings)
        case .contentFilter: return filterModel(settings: settings)
        case .subtitles: return subtitlesModel(settings: settings)
        case .localMedia: return localMediaModel(localMedia: localMedia)
        case .advanced: return advancedModel(settings: settings)
        case .about:
            return aboutModel(
                settings: settings,
                cloudActiveJobCount: cloudActiveJobCount
            )
        }
    }

    static func iCloudModel(cloudSync: CloudSyncCoordinator) -> TVSettingsScreenModel {
        let syncEnabled = cloudSync.phase != .noAccount && cloudSync.phase != .syncing
        var rows: [TVSettingsRowDescriptor] = [
            infoRow(
                id: "status",
                title: L10n.string("settings.icloud_status", fallback: "Status"),
                icon: SettingsStatusFormatting.syncStatusIcon(phase: cloudSync.phase),
                help: cloudSync.statusDetail,
                value: cloudSync.statusTitle,
                identifier: "settings.icloud-status"
            ),
            infoRow(
                id: "cache",
                title: L10n.string("settings.icloud_subtitle_cache", fallback: "Cloud Subtitle Cache"),
                icon: "internaldrive",
                help: L10n.string(
                    "settings.icloud_cache.help",
                    fallback: "Completed bilingual subtitles stored in iCloud."
                ),
                value: SettingsStatusFormatting.subtitleCacheSummary(
                    count: cloudSync.subtitleArtifactCount,
                    byteCount: cloudSync.subtitleArtifactByteCount
                ),
                identifier: "settings.icloud-cache"
            )
        ]
        if cloudSync.phase == .awaitingAccountConfirmation {
            rows.append(
                TVSettingsRowDescriptor(
                    id: "confirm-merge",
                    title: L10n.string("settings.confirm_merge_into_new_icloud", fallback: "Confirm merge into new iCloud"),
                    icon: "person.crop.circle.badge.exclamationmark",
                    help: L10n.string(
                        "settings.confirm_merge.help",
                        fallback: "Merge local data into the new iCloud account."
                    ),
                    kind: .action {}
                )
            )
        } else {
            rows.append(
                TVSettingsRowDescriptor(
                    id: "sync-now",
                    title: L10n.string("settings.sync_now", fallback: "Sync now"),
                    icon: "arrow.triangle.2.circlepath",
                    help: L10n.string(
                        "settings.sync_now.help",
                        fallback: "Upload and download the latest settings and subtitles."
                    ),
                    kind: .action {},
                    accessibilityIdentifier: "settings.sync-now",
                    isEnabled: syncEnabled && !UITestSupport.isEnabled,
                    disabledReason: UITestSupport.isEnabled
                        ? L10n.string("settings.sync_unavailable_tests", fallback: "Sync is disabled during UI tests.")
                        : L10n.string(
                            "settings.sync_unavailable.help",
                            fallback: "Sign in to iCloud on this Apple TV to sync."
                        )
                )
            )
        }
        if cloudSync.subtitleArtifactCount > 0 {
            rows.append(
                TVSettingsRowDescriptor(
                    id: "clear-cache",
                    title: L10n.string("settings.clear_icloud_subtitle_cache", fallback: "Clear iCloud Subtitle Cache"),
                    icon: "trash",
                    help: L10n.string(
                        "settings.clear_cache.help",
                        fallback: "Remove bilingual subtitle files from iCloud. This cannot be undone."
                    ),
                    kind: .action {},
                    accessibilityIdentifier: "settings.clear-icloud-cache",
                    isDestructive: true
                )
            )
        }
        return TVSettingsScreenModel(
            title: L10n.string("settings.icloud_sync", fallback: "iCloud Sync"),
            defaultIcon: "icloud",
            defaultHelp: cloudSync.statusDetail,
            groups: [TVSettingsGroup(title: nil, rows: rows)]
        )
    }

    static func setupModel(readiness: ConfigurationReadiness) -> TVSettingsScreenModel {
        let items: [(ConfigurationRequirement, String, String)] = [
            (
                .youtubeAPIKey,
                L10n.string("settings.youtube_data_api_key", fallback: "YouTube Data API Key"),
                "play.tv"
            ),
            (
                .dashscopeAPIKey,
                L10n.string("settings.dashscope_api_key", fallback: "DashScope API Key"),
                "waveform"
            ),
            (
                .translationAPIKey,
                L10n.string("root.translation_api_key", fallback: "Translation API Key"),
                "globe"
            )
        ]
        var rows: [TVSettingsRowDescriptor] = [
            infoRow(
                id: "progress",
                title: readiness.title,
                icon: readiness.summary.isComplete ? "checkmark.seal.fill" : "key.fill",
                help: readiness.subtitle,
                value: "\(readiness.summary.completedCount)/\(readiness.summary.totalCount)",
                identifier: "setup.configuration"
            )
        ]
        for (requirement, title, icon) in items {
            let missing = readiness.summary.missingRequirements.contains(requirement)
            rows.append(
                infoRow(
                    id: requirement.rawValue,
                    title: title,
                    icon: missing ? "circle" : "checkmark.circle.fill",
                    help: missing
                        ? L10n.string(
                            "settings.setup_item_missing.help",
                            fallback: "Configure this key on iPhone or with Set Up by Phone."
                        )
                        : L10n.string("settings.setup_item_ready.help", fallback: "This key is configured."),
                    value: missing
                        ? L10n.string("settings.not_configured", fallback: "Not configured")
                        : L10n.string("settings.configured", fallback: "Configured")
                )
            )
        }
        rows.append(mobileSetupRow())
        return TVSettingsScreenModel(
            title: L10n.string("settings.configuration_progress", fallback: "Setup Progress"),
            defaultIcon: "key.fill",
            defaultHelp: readiness.subtitle,
            groups: [TVSettingsGroup(title: nil, rows: rows)]
        )
    }

    static func cloudModel(settings: SettingsStore) -> TVSettingsScreenModel {
        let configuration = settings.configuration
        return TVSettingsScreenModel(
            title: L10n.string("settings.cloud_service", fallback: "Cloud Generation Service"),
            defaultIcon: "cloud.fill",
            defaultHelp: L10n.string(
                "settings.cloud_service_help",
                fallback: "Cloud generation runs on your own server, so this device does not need DashScope or translation keys."
            ),
            groups: [
                TVSettingsGroup(title: nil, rows: [
                    TVSettingsRowDescriptor(
                        id: "enabled",
                        title: L10n.string("settings.cloud_service_enabled", fallback: "Enable Cloud Generation Service"),
                        icon: "cloud.fill",
                        help: L10n.string(
                            "settings.cloud_service_help",
                            fallback: "Cloud generation runs on your own server, so this device does not need DashScope or translation keys."
                        ),
                        kind: .toggle(isOn: configuration.contentServiceEnabled, set: { _ in }),
                        accessory: SettingsStatusFormatting.onOff(configuration.contentServiceEnabled),
                        accessibilityIdentifier: "settings.cloud-enabled"
                    ),
                    TVSettingsRowDescriptor(
                        id: "backend",
                        title: L10n.string("settings.generation_backend", fallback: "Generation Backend"),
                        icon: "switch.2",
                        help: L10n.string(
                            "settings.generation_backend.help",
                            fallback: "Cloud Service runs generation on your server. On-Device uses keys stored on this device."
                        ),
                        kind: .value(.generationBackend),
                        accessory: backendTitle(configuration.generationBackendMode),
                        accessibilityIdentifier: "settings.generation-backend"
                    ),
                    infoRow(
                        id: "status",
                        title: L10n.string("settings.cloud_service_status", fallback: "Status"),
                        icon: "checkmark.seal",
                        help: L10n.string(
                            "settings.cloud_status.help",
                            fallback: "The service is ready when it is enabled and an access token is configured."
                        ),
                        value: SettingsStatusFormatting.cloudServiceStatusTitle(configuration: configuration),
                        identifier: "settings.cloud-status"
                    ),
                    infoRow(
                        id: "url",
                        title: L10n.string("settings.cloud_base_url", fallback: "Service Base URL"),
                        icon: "link",
                        help: L10n.string(
                            "settings.cloud_url.help",
                            fallback: "Set the service URL on iPhone or with Set Up by Phone."
                        ),
                        value: configuration.normalizedContentServiceBaseURL
                    ),
                    infoRow(
                        id: "token",
                        title: L10n.string("settings.cloud_access_token", fallback: "Access Token"),
                        icon: "key.fill",
                        help: L10n.string(
                            "settings.cloud_token.help",
                            fallback: "The token is stored in the Keychain and never shown in full."
                        ),
                        value: SettingsStatusFormatting.maskedCloudTokenTitle(token: configuration.contentServiceToken),
                        identifier: "settings.cloud-token"
                    ),
                    mobileSetupRow()
                ])
            ]
        )
    }

    static func translationModel(settings: SettingsStore) -> TVSettingsScreenModel {
        let cloudHidesLegacy = settings.configuration.generationBackendMode == .cloud
            && settings.configuration.contentServiceEnabled
        var rows: [TVSettingsRowDescriptor] = [
            infoRow(
                id: "language",
                title: L10n.string("settings.subtitle_target", fallback: "Subtitle Translation Language"),
                icon: "globe",
                help: L10n.string(
                    "settings.translation_language.help",
                    fallback: "Change the translation language on iPhone or with Set Up by Phone. Existing translations remain available on this device."
                ),
                value: settings.configuration.translationTarget.autonym,
                identifier: "settings.translation-language"
            )
        ]
        if !cloudHidesLegacy {
            rows.append(
                infoRow(
                    id: "provider",
                    title: L10n.string("settings.provider", fallback: "Provider"),
                    icon: "building.2",
                    help: L10n.string(
                        "settings.provider.help",
                        fallback: "The on-device translation provider. Change it on iPhone."
                    ),
                    value: settings.configuration.translationProvider.capitalized
                )
            )
        }
        rows.append(
            TVSettingsRowDescriptor(
                id: "quality",
                title: L10n.string("settings.translation_quality_mode", fallback: "Translation Quality"),
                icon: "slider.horizontal.3",
                help: L10n.string(
                    "settings.translation_quality_mode_help",
                    fallback: "Quality translates then refines each line; Fast translates in a single pass. Applies only to newly generated subtitles."
                ),
                kind: .value(.translationQuality),
                accessory: qualityTitle(settings.configuration.translationQualityMode)
            )
        )
        rows.append(mobileSetupRow())
        return TVSettingsScreenModel(
            title: L10n.string("settings.translation", fallback: "Translation"),
            defaultIcon: "globe",
            defaultHelp: L10n.string(
                "settings.translation.help",
                fallback: "Translation quality and the current subtitle language."
            ),
            groups: [TVSettingsGroup(title: nil, rows: rows)]
        )
    }

    static func filterModel(settings: SettingsStore) -> TVSettingsScreenModel {
        let keywords = settings.configuration.contentFilterKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
        return TVSettingsScreenModel(
            title: L10n.string("settings.content_filter", fallback: "Content Filter"),
            defaultIcon: "line.3.horizontal.decrease.circle",
            defaultHelp: L10n.string(
                "settings.content_filter_help",
                fallback: "Matching episodes and videos are hidden from lists. Keywords apply instantly; the agent instruction uses the configured Translation LLM when available."
            ),
            groups: [
                TVSettingsGroup(title: nil, rows: [
                    TVSettingsRowDescriptor(
                        id: "enabled",
                        title: L10n.string("settings.content_filter_enabled", fallback: "Enable Content Filter"),
                        icon: "line.3.horizontal.decrease.circle",
                        help: L10n.string(
                            "settings.content_filter_help",
                            fallback: "Matching episodes and videos are hidden from lists. Keywords apply instantly; the agent instruction uses the configured Translation LLM when available."
                        ),
                        kind: .toggle(isOn: settings.configuration.contentFilterEnabled, set: { _ in }),
                        accessory: SettingsStatusFormatting.onOff(settings.configuration.contentFilterEnabled)
                    ),
                    infoRow(
                        id: "keywords",
                        title: L10n.string("settings.content_filter_keywords_label", fallback: "Keywords"),
                        icon: "text.magnifyingglass",
                        help: L10n.string(
                            "settings.filter_keywords.help",
                            fallback: "Edit keywords on iPhone or with Set Up by Phone."
                        ),
                        value: keywords.isEmpty
                            ? L10n.string("settings.none", fallback: "None")
                            : keywords
                    ),
                    mobileSetupRow()
                ])
            ]
        )
    }

    static func subtitlesModel(settings: SettingsStore) -> TVSettingsScreenModel {
        let presentation = settings.configuration.subtitlePresentation
        let platform = SubtitleSizePlatform.current
        let targetName = settings.configuration.translationTarget.autonym
        var help = L10n.string(
            "settings.subtitles.help",
            fallback: "English size, translation size, and line order."
        )
        if presentation.isTargetSizeProtectedByMinimum(on: platform) {
            help = L10n.string(
                "settings.subtitle_min_size_hint",
                fallback: "Translation size is raised to the platform minimum for readability."
            )
        }
        return TVSettingsScreenModel(
            title: L10n.string("settings.subtitles", fallback: "Subtitles"),
            defaultIcon: "captions.bubble.fill",
            defaultHelp: help,
            groups: [
                TVSettingsGroup(title: nil, rows: [
                    TVSettingsRowDescriptor(
                        id: "english-size",
                        title: L10n.string("settings.subtitle_english_size", fallback: "English Size"),
                        icon: "textformat.size",
                        help: L10n.string(
                            "settings.subtitle_english_size_help",
                            fallback: "English subtitle size from level 1 (smallest) to 9 (largest)."
                        ),
                        kind: .value(.englishSize),
                        accessory: SubtitleOptionLabels.englishSize(
                            level: presentation.englishSizeLevel,
                            scalePercent: presentation.targetScalePercent,
                            order: presentation.order,
                            platform: platform
                        ),
                        accessibilityIdentifier: "settings.subtitle.english-size"
                    ),
                    TVSettingsRowDescriptor(
                        id: "target-scale",
                        title: L10n.string("settings.subtitle_target_scale", fallback: "Translation Size"),
                        icon: "textformat.size.smaller",
                        help: L10n.format(
                            "settings.subtitle_target_scale_help",
                            fallback: "Translation size as a percentage of English size. Current translation language: %@.",
                            targetName
                        ),
                        kind: .value(.targetScale),
                        accessory: SubtitleOptionLabels.targetScale(
                            percent: presentation.targetScalePercent,
                            englishSizeLevel: presentation.englishSizeLevel,
                            order: presentation.order,
                            platform: platform
                        ),
                        accessibilityIdentifier: "settings.subtitle.target-scale"
                    ),
                    TVSettingsRowDescriptor(
                        id: "order",
                        title: L10n.string("settings.subtitle_order", fallback: "Line Order"),
                        icon: "arrow.up.arrow.down",
                        help: L10n.string(
                            "settings.subtitle_order_help",
                            fallback: "Choose which language appears on the top line."
                        ),
                        kind: .value(.subtitleOrder),
                        accessory: SubtitleOptionLabels.orderValue(
                            order: presentation.order,
                            targetLanguageName: targetName
                        ),
                        accessibilityIdentifier: "settings.subtitle.order"
                    )
                ])
            ],
            showsSubtitlePreview: true
        )
    }

    static func localMediaModel(localMedia: TVSettingsLocalMediaModel) -> TVSettingsScreenModel {
        TVSettingsScreenModel(
            title: L10n.string("settings.local_media_backend", fallback: "Cloud / Local Media Backend"),
            defaultIcon: "externaldrive.connected.to.line.below",
            defaultHelp: L10n.string(
                "settings.local_media_help",
                fallback: "Self-hosted yt-dlp backend for HD. Default 720p saves disk. Leave disabled to use on-device extraction."
            ),
            groups: [
                TVSettingsGroup(title: nil, rows: [
                    TVSettingsRowDescriptor(
                        id: "enabled",
                        title: L10n.string("settings.local_media_enabled", fallback: "Use yt-dlp media service"),
                        icon: "externaldrive.connected.to.line.below",
                        help: L10n.string(
                            "settings.local_media_help",
                            fallback: "Self-hosted yt-dlp backend for HD. Default 720p saves disk. Leave disabled to use on-device extraction."
                        ),
                        kind: .toggle(isOn: localMedia.enabled, set: { _ in }),
                        accessory: SettingsStatusFormatting.onOff(localMedia.enabled)
                    ),
                    infoRow(
                        id: "url",
                        title: L10n.string("settings.local_media_base_url", fallback: "Base URL (https://…)"),
                        icon: "link",
                        help: L10n.string(
                            "settings.local_media_url.help",
                            fallback: "Set the media service URL on iPhone or with Set Up by Phone."
                        ),
                        value: localMedia.baseURL.isEmpty
                            ? L10n.string("settings.not_configured", fallback: "Not configured")
                            : localMedia.baseURL
                    ),
                    infoRow(
                        id: "token",
                        title: L10n.string("settings.local_media_token", fallback: "Bearer token"),
                        icon: "key.fill",
                        help: L10n.string(
                            "settings.local_media_token.help",
                            fallback: "The token is stored on this device and never shown in full."
                        ),
                        value: localMedia.maskedToken
                    ),
                    TVSettingsRowDescriptor(
                        id: "mode",
                        title: L10n.string("settings.local_media_mode", fallback: "Mode"),
                        icon: "film",
                        help: L10n.string(
                            "settings.local_media_mode.help",
                            fallback: "MP4 downloads a file. HLS streams adaptive video."
                        ),
                        kind: .value(.localMediaMode),
                        accessory: localMedia.mode == .hls
                            ? L10n.string("settings.local_media_mode_hls", fallback: "HLS")
                            : L10n.string("settings.local_media_mode_mp4", fallback: "MP4")
                    ),
                    TVSettingsRowDescriptor(
                        id: "height",
                        title: L10n.string("settings.local_media_height", fallback: "Preferred height"),
                        icon: "rectangle",
                        help: L10n.string(
                            "settings.local_media_height.help",
                            fallback: "720p uses less disk. 1080p is sharper."
                        ),
                        kind: .value(.localMediaHeight),
                        accessory: localMedia.preferredHeight >= 1080
                            ? L10n.string("settings.local_media_height_1080", fallback: "1080p")
                            : L10n.string("settings.local_media_height_720", fallback: "720p")
                    ),
                    mobileSetupRow()
                ])
            ]
        )
    }

    static func advancedModel(settings: SettingsStore) -> TVSettingsScreenModel {
        let ossReady = !settings.configuration.ossAccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.configuration.ossBucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ttsReady = !settings.configuration.minimaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return TVSettingsScreenModel(
            title: L10n.string("settings.advanced", fallback: "Advanced"),
            defaultIcon: "gearshape.2",
            defaultHelp: L10n.string(
                "settings.advanced.help",
                fallback: "Optional object storage and TTS. Edit these on iPhone."
            ),
            groups: [
                TVSettingsGroup(title: nil, rows: [
                    infoRow(
                        id: "oss",
                        title: L10n.string("settings.aliyun_oss_optional", fallback: "Aliyun OSS (optional)"),
                        icon: "externaldrive",
                        help: L10n.string(
                            "settings.oss.help",
                            fallback: "Transcribed audio is uploaded to DashScope first. OSS is kept for later backup."
                        ),
                        value: ossReady
                            ? L10n.string("settings.configured", fallback: "Configured")
                            : L10n.string("settings.not_configured", fallback: "Not configured")
                    ),
                    infoRow(
                        id: "tts",
                        title: L10n.string("settings.optional_tts", fallback: "Optional TTS"),
                        icon: "waveform",
                        help: L10n.string(
                            "settings.tts.help",
                            fallback: "The first version does not generate Chinese synthesized episodes by default."
                        ),
                        value: ttsReady
                            ? L10n.string("settings.configured", fallback: "Configured")
                            : L10n.string("settings.not_configured", fallback: "Not configured")
                    ),
                    mobileSetupRow()
                ])
            ]
        )
    }

    static func aboutModel(settings: SettingsStore, cloudActiveJobCount: Int) -> TVSettingsScreenModel {
        let error = settings.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TVSettingsScreenModel(
            title: L10n.string("settings.about_diagnostics", fallback: "About and Diagnostics"),
            defaultIcon: "info.circle",
            defaultHelp: L10n.string(
                "settings.about_diagnostics.help",
                fallback: "Version, device, and diagnostic information."
            ),
            groups: [
                TVSettingsGroup(title: nil, rows: [
                    infoRow(
                        id: "version",
                        title: L10n.string("settings.about.version", fallback: "Version"),
                        icon: "info.circle",
                        help: L10n.string("settings.about.version.help", fallback: "App marketing version and build number."),
                        value: appVersionText(),
                        identifier: "settings.about.version"
                    ),
                    infoRow(
                        id: "system",
                        title: L10n.string("settings.about.system", fallback: "System"),
                        icon: "appletv",
                        help: L10n.string("settings.about.system.help", fallback: "The tvOS version on this Apple TV."),
                        value: UIDevice.current.systemVersion
                    ),
                    infoRow(
                        id: "device",
                        title: L10n.string("settings.about.device", fallback: "Device"),
                        icon: "tv",
                        help: L10n.string("settings.about.device.help", fallback: "The device model identifier."),
                        value: UIDevice.current.model
                    ),
                    infoRow(
                        id: "jobs",
                        title: L10n.string("settings.cloud_active_jobs", fallback: "Active Cloud Jobs"),
                        icon: "list.number",
                        help: L10n.string(
                            "settings.about.jobs.help",
                            fallback: "Remote generation jobs that have not finished."
                        ),
                        value: String(cloudActiveJobCount),
                        identifier: "settings.cloud-active-jobs"
                    ),
                    infoRow(
                        id: "error",
                        title: L10n.string("settings.about.last_error", fallback: "Last Error"),
                        icon: "exclamationmark.triangle",
                        help: error.isEmpty
                            ? L10n.string("settings.about.error.help", fallback: "The last settings save error, if any.")
                            : error,
                        value: error.isEmpty
                            ? L10n.string("settings.none", fallback: "None")
                            : L10n.string("settings.needs_attention", fallback: "Needs attention")
                    ),
                    mobileSetupRow()
                ])
            ]
        )
    }

    static func backendTitle(_ backend: GenerationBackend) -> String {
        switch backend {
        case .cloud:
            return L10n.string("settings.generation_backend_cloud", fallback: "Cloud Service")
        case .local:
            return L10n.string("settings.generation_backend_local", fallback: "On-Device (Legacy)")
        }
    }

    static func qualityTitle(_ raw: String) -> String {
        if raw == TranslationQualityMode.fast.rawValue {
            return L10n.string("settings.translation_quality_fast", fallback: "Fast (direct)")
        }
        return L10n.string("settings.translation_quality_quality", fallback: "Quality (reflective)")
    }

    static func appVersionText() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    static func disclosure(
        id: String,
        title: String,
        icon: String,
        help: String,
        summary: String?,
        route: TVSettingsRoute,
        identifier: String
    ) -> TVSettingsRowDescriptor {
        TVSettingsRowDescriptor(
            id: id,
            title: title,
            icon: icon,
            help: help,
            kind: .disclosure(route),
            accessory: summary,
            accessibilityIdentifier: identifier
        )
    }

    static func infoRow(
        id: String,
        title: String,
        icon: String,
        help: String,
        value: String,
        identifier: String? = nil
    ) -> TVSettingsRowDescriptor {
        TVSettingsRowDescriptor(
            id: id,
            title: title,
            icon: icon,
            help: help,
            kind: .info,
            accessory: value,
            accessibilityIdentifier: identifier,
            isFocusable: false
        )
    }

    static func mobileSetupRow() -> TVSettingsRowDescriptor {
        TVSettingsRowDescriptor(
            id: "mobile-setup",
            title: L10n.string("settings.mobile_setup", fallback: "Set Up by Phone"),
            icon: "qrcode",
            help: L10n.string(
                "mobile_setup.scan_instructions",
                fallback: "Scan with the iPhone camera, then configure APIs, Podcast subscriptions, or YouTube channels in Safari."
            ),
            kind: .action {},
            accessibilityIdentifier: "settings.mobile-setup"
        )
    }
}
#endif
