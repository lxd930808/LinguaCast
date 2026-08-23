import Foundation
import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

enum UITestScenario: String {
    case tabs
    case firstLaunch = "first-launch"
    case podcastQueued = "podcast-queued"
    case podcastQueuedMissingConfiguration = "podcast-queued-missing-configuration"
    case podcastRunning = "podcast-running"
    case podcastCompletionTransition = "podcast-completion-transition"
    case podcastReady = "podcast-ready"
    case podcastFollow = "podcast-follow"
    case podcastLockResume = "podcast-lock-resume"
    case podcastFailed = "podcast-failed"
    case podcastCloudCheckRequired = "podcast-cloud-check-required"
    case podcastLargeList = "podcast-large-list"
    case youtubePartial = "youtube-partial"
    case youtubeFailed = "youtube-failed"
    case youtubeReady = "youtube-ready"
    case youtubeChannel = "youtube-channel"
    case mobileSetup = "mobile-setup"

    var usesDirectScene: Bool {
        switch self {
        case .podcastQueued, .podcastQueuedMissingConfiguration, .podcastRunning, .podcastCompletionTransition, .podcastReady, .podcastFollow, .podcastLockResume, .podcastFailed, .podcastCloudCheckRequired, .podcastLargeList,
             .youtubePartial, .youtubeFailed, .youtubeReady, .youtubeChannel, .mobileSetup: true
        case .tabs, .firstLaunch: false
        }
    }
}

enum UITestSupport {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-linguacast-ui-testing")
        #else
        false
        #endif
    }

    static var colorSchemeOverride: ColorScheme? {
        guard isEnabled else { return nil }
        switch ProcessInfo.processInfo.environment["LINGUACAST_UI_COLOR_SCHEME"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static var youtubePlaybackSegments: [LearningSegment] {
        [
            LearningSegment(
                sequence: 1,
                startMS: 0,
                endMS: 5_900,
                text: "A deterministic English subtitle.",
                translation: "一条稳定的英文字幕。"
            ),
            LearningSegment(
                sequence: 2,
                startMS: 6_000,
                endMS: 11_900,
                text: "Practice the current sentence.",
                translation: "练习当前这一句。"
            ),
            LearningSegment(
                sequence: 3,
                startMS: 12_000,
                endMS: 17_900,
                text: "Continue when you are ready.",
                translation: "准备好后继续。"
            )
        ]
    }

    static var fixtureConfiguration: AppConfiguration {
        var value = AppConfiguration()
        guard scenario != .firstLaunch, scenario != .podcastQueuedMissingConfiguration else { return value }
        value.youtubeAPIKey = "fixture-youtube"
        value.dashscopeAPIKey = "fixture-dashscope"
        value.translationAPIKey = "fixture-translation"
        value.translationTarget = .simplifiedChinese
        applySubtitlePresentationFixtureOverrides(to: &value)
        return value
    }

    /// Launch-env overrides for committed subtitle presentation fixtures.
    /// Supported keys: `LINGUACAST_UI_SUBTITLE_LEVEL`, `LINGUACAST_UI_SUBTITLE_SCALE`,
    /// `LINGUACAST_UI_SUBTITLE_ORDER`, `LINGUACAST_UI_SUBTITLE_DISPLAY_MODE`.
    static func applySubtitlePresentationFixtureOverrides(to configuration: inout AppConfiguration) {
        applySubtitlePresentationEnvOverrides(
            to: &configuration,
            levelKey: "LINGUACAST_UI_SUBTITLE_LEVEL",
            scaleKey: "LINGUACAST_UI_SUBTITLE_SCALE",
            orderKey: "LINGUACAST_UI_SUBTITLE_ORDER",
            displayModeKey: "LINGUACAST_UI_SUBTITLE_DISPLAY_MODE"
        )
    }

    /// Commits a second subtitle config while a player stays open (UI-test Apply button).
    /// Reads `LINGUACAST_UI_SUBTITLE_LEVEL_AFTER` / `_SCALE_AFTER` / `_ORDER_AFTER` /
    /// `_DISPLAY_MODE_AFTER` from launch environment.
    @MainActor
    @discardableResult
    static func applyPendingSubtitlePresentationUpdate(to settings: SettingsStore) -> Bool {
        guard isEnabled else { return false }
        let env = ProcessInfo.processInfo.environment
        let hasAfter =
            !(env["LINGUACAST_UI_SUBTITLE_LEVEL_AFTER"] ?? "").isEmpty
            || !(env["LINGUACAST_UI_SUBTITLE_SCALE_AFTER"] ?? "").isEmpty
            || !(env["LINGUACAST_UI_SUBTITLE_ORDER_AFTER"] ?? "").isEmpty
            || !(env["LINGUACAST_UI_SUBTITLE_DISPLAY_MODE_AFTER"] ?? "").isEmpty
        guard hasAfter else { return false }

        var updated = settings.committedConfiguration
        applySubtitlePresentationEnvOverrides(
            to: &updated,
            levelKey: "LINGUACAST_UI_SUBTITLE_LEVEL_AFTER",
            scaleKey: "LINGUACAST_UI_SUBTITLE_SCALE_AFTER",
            orderKey: "LINGUACAST_UI_SUBTITLE_ORDER_AFTER",
            displayModeKey: "LINGUACAST_UI_SUBTITLE_DISPLAY_MODE_AFTER"
        )
        settings.configuration = updated
        _ = settings.save()
        return true
    }

    private static func applySubtitlePresentationEnvOverrides(
        to configuration: inout AppConfiguration,
        levelKey: String,
        scaleKey: String,
        orderKey: String,
        displayModeKey: String
    ) {
        let env = ProcessInfo.processInfo.environment
        if let level = env[levelKey], !level.isEmpty {
            configuration.subtitleEnglishSizeLevel =
                SubtitlePresentationPreferences.normalizedEnglishSizeLevel(from: level)
        }
        if let scale = env[scaleKey], !scale.isEmpty {
            configuration.subtitleTargetScalePercent =
                SubtitlePresentationPreferences.normalizedTargetScalePercent(from: scale)
        }
        if let order = env[orderKey], !order.isEmpty {
            configuration.subtitleOrder = SubtitleOrder.normalized(order).rawValue
        }
        if let mode = env[displayModeKey], !mode.isEmpty {
            configuration[.subtitleDisplayMode] = mode
        }
    }

    static func installNetworkBlocker() {
        guard isEnabled else { return }
        URLProtocol.registerClass(UITestBlockingURLProtocol.self)
    }

    static var scenario: UITestScenario {
        if let value = ProcessInfo.processInfo.environment["LINGUACAST_UI_SCENARIO"],
           let scenario = UITestScenario(rawValue: value) {
            return scenario
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-linguacast-ui-scenario"),
              arguments.indices.contains(index + 1)
        else { return .tabs }
        return UITestScenario(rawValue: arguments[index + 1]) ?? .tabs
    }

    static var initialTab: AppTab {
        if let value = ProcessInfo.processInfo.environment["LINGUACAST_UI_TAB"] {
            return tab(named: value)
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-linguacast-ui-tab"),
              arguments.indices.contains(index + 1)
        else { return .home }
        return tab(named: arguments[index + 1])
    }

    private static func tab(named value: String) -> AppTab {
        switch value {
        case "programs": return .programs
        case "subscriptions": return .subscriptions
        case "settings": return .settings
        default: return .home
        }
    }

    @MainActor
    static func installFixtures(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        guard existing.isEmpty else { return }

        let podcast = PodcastSubscription(
            id: "ui-podcast",
            showURL: "https://example.com/podcast",
            displayName: "The Daily Language Lab",
            feedURL: "https://example.com/feed.xml",
            authorName: "LinguaCast Fixtures",
            summaryText: "A fixture summary that verifies the expandable podcast description.",
            artworkURL: "https://example.com/podcast.jpg",
            artworkSource: "apple",
            websiteURL: "https://example.com/podcast",
            applePodcastsURL: "https://podcasts.apple.com/podcast/id123456789",
            hasMoreEpisodes: true
        )
        let episode = EpisodeRecord(
            id: "ui-episode-\(scenario.rawValue)",
            subscriptionID: podcast.id,
            showTitle: podcast.displayName,
            showArtist: "LinguaCast Fixtures",
            episodeTitle: "A deterministic bilingual listening session",
            episodeGUID: "ui-episode-guid",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            enclosureURL: "https://example.com/audio.mp3",
            artworkURL: "https://example.com/episode.jpg",
            summaryText: "A complete fixture episode summary shown above playback and subtitles.",
            mediaDurationSeconds: 600,
            seasonNumber: 2,
            episodeNumber: 7,
            episodeWebsiteURL: "https://example.com/podcast/episode-7",
            status: "completed",
            pipelineStep: "completed",
            isNew: true
        )
        episode.playbackPositionSeconds = 75
        episode.playbackDurationSeconds = 600
        if scenario == .podcastQueued || scenario == .podcastQueuedMissingConfiguration {
            episode.status = "queued"
            episode.pipelineStep = "queued"
            episode.summaryText = Array(
                repeating: "A long episode detail paragraph used to verify that the pending episode screen remains scrollable.",
                count: 18
            ).joined(separator: "\n\n")
        } else if scenario == .podcastRunning {
            episode.status = "running"
            episode.pipelineStep = "translate"
            episode.pipelineProgress = 0.42
            episode.pipelineMessage = "translate"
        } else if scenario == .podcastCompletionTransition {
            // Orphaned completion: the pipeline crashed / was killed after the full
            // translation was written to disk but before the episode flipped to
            // `completed`. The reconciler must promote it to `completed` in-process.
            episode.status = "running"
            episode.pipelineStep = "build_learning_pack"
            episode.pipelineProgress = 0.9
            episode.pipelineMessage = "build_learning_pack"
            episode.activeTranslationTargetLanguage = TranslationTarget.simplifiedChinese.rawValue
        } else if scenario == .podcastFailed {
            episode.status = "failed"
            episode.pipelineStep = "failed"
            episode.errorMessage = L10n.string("subtitles.unavailable", fallback: "Subtitles Unavailable")
        } else if scenario == .podcastCloudCheckRequired {
            episode.status = "failed"
            episode.pipelineStep = "cloud_check"
            episode.pipelineMessage = "cloud_check_required"
            episode.errorMessage = L10n.string(
                "cloud.detail.starting",
                fallback: "Checking the account and cloud changes."
            )
        }

        let channel = YTChannelRecord(
            id: "ui-channel",
            channelID: "UC_LINGUACAST_FIXTURE",
            url: "https://youtube.com/@linguacast-fixture",
            displayName: "LinguaCast Video Lab"
        )
        channel.videoCount = 3
        let video = YTVideoRecord(
            id: "ui-video",
            channelRecordID: channel.id,
            channelID: channel.channelID,
            title: "A long deterministic video title for localization testing",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: "https://youtube.com/watch?v=fixture"
        )
        switch scenario {
        case .youtubeReady:
            video.subtitleStatus = "ready"
            video.subtitleTranslatedCount = 10
            video.subtitleTotalCount = 10
            video.zhVTTPath = "/private/tmp/ui-fixture.zh.vtt"
        case .youtubeFailed:
            video.subtitleStatus = "failed"
            video.subtitleTranslatedCount = 0
            video.subtitleTotalCount = 10
            video.lastError = L10n.string("subtitles.unavailable", fallback: "Subtitles Unavailable")
        default:
            video.subtitleStatus = "partial"
            video.subtitleTranslatedCount = 7
            video.subtitleTotalCount = 10
        }
        video.enVTTPath = "/private/tmp/ui-fixture.en.vtt"
        video.playbackPositionSeconds = 42
        video.playbackDurationSeconds = 300

        context.insert(podcast)
        context.insert(episode)
        context.insert(channel)
        context.insert(video)
        if scenario == .podcastLargeList {
            for index in 1..<1_000 {
                context.insert(EpisodeRecord(
                    id: "ui-large-episode-\(index)",
                    subscriptionID: podcast.id,
                    showTitle: podcast.displayName,
                    showArtist: "LinguaCast Fixtures",
                    episodeTitle: "Large podcast episode \(index)",
                    episodeGUID: "ui-large-guid-\(index)",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index * 86_400)),
                    enclosureURL: "https://example.com/audio-\(index).mp3"
                ))
            }
        } else if scenario == .podcastCompletionTransition {
            installCompleteTranslationArtifacts(for: episode)
            installSilentAudio(for: episode)
        } else if scenario == .podcastReady {
            episode.playbackPositionSeconds = 0.25
            episode.playbackDurationSeconds = 1
            let segment = SegmentRecord(
                id: "ui-segment",
                episodeID: episode.id,
                sequence: 1,
                startMS: 0,
                endMS: 1_000,
                text: "A deterministic English subtitle.",
                learningText: "A deterministic English subtitle.",
                translation: "确定性的双语字幕。"
            )
            context.insert(segment)
            installSilentAudio(for: episode)
        } else if scenario == .podcastFollow {
            episode.playbackPositionSeconds = 0
            episode.playbackDurationSeconds = 20
            for sequence in 1...20 {
                let startMS = (sequence - 1) * 1_000
                context.insert(
                    SegmentRecord(
                        id: "ui-follow-segment-\(sequence)",
                        episodeID: episode.id,
                        sequence: sequence,
                        startMS: startMS,
                        endMS: startMS + 999,
                        text: "Follow segment \(sequence)",
                        learningText: "Follow segment \(sequence) with enough text for a full subtitle row.",
                        translation: "自动跟随字幕第 \(sequence) 段。"
                    )
                )
            }
            installSilentAudio(for: episode, duration: 20)
        } else if scenario == .podcastLockResume {
            // Mid-episode resume fixture for lock → unlock → play acceptance.
            episode.playbackPositionSeconds = 8
            episode.playbackDurationSeconds = 20
            for sequence in 1...20 {
                let startMS = (sequence - 1) * 1_000
                context.insert(
                    SegmentRecord(
                        id: "ui-lock-resume-segment-\(sequence)",
                        episodeID: episode.id,
                        sequence: sequence,
                        startMS: startMS,
                        endMS: startMS + 999,
                        text: "Lock resume segment \(sequence)",
                        learningText: "Lock resume segment \(sequence) with enough text for a full subtitle row.",
                        translation: "锁屏恢复字幕第 \(sequence) 段。"
                    )
                )
            }
            installSilentAudio(for: episode, duration: 20)
        }
        try? context.save()
    }

    /// Writes a complete, valid translation for the episode's active target to disk,
    /// mirroring exactly what the pipeline leaves behind when it finishes translating
    /// but is killed before committing the `completed` status. The reconciler validates
    /// these artifacts (identity, pipeline version, full translation, fingerprint) and
    /// only then promotes the episode.
    private static func installCompleteTranslationArtifacts(for episode: EpisodeRecord) {
        guard let raw = episode.activeTranslationTargetLanguage,
              let target = TranslationTarget(rawValue: raw),
              let episodeFiles = try? LocalFileStore().episodeFiles(episodeID: episode.id),
              let translationFiles = try? LocalFileStore().translationFiles(episodeID: episode.id, target: target)
        else { return }
        let store = LocalFileStore()
        let bilingual = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "A deterministic English subtitle.", translation: "确定性的双语字幕。"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "Reconciled to completed in-process.", translation: "已在当前进程内恢复为完成。")
        ]
        let english = bilingual.map { segment in
            LearningSegment(sequence: segment.sequence, startMS: segment.startMS, endMS: segment.endMS, text: segment.text)
        }
        try? store.writeJSON(english, to: episodeFiles.rawTranscription)
        try? store.writeJSON(bilingual, to: translationFiles.segments)
        try? store.writeJSON(
            TranslationArtifactManifest(
                contentKind: TranslationContentKind.podcastEpisode.rawValue,
                contentID: episode.id,
                targetLanguage: target.rawValue,
                // Mirror the real 90% stall: translation finished on disk, manifest still running.
                status: TranslationVariantStatus.running.rawValue,
                updatedAt: Date(),
                artifacts: ["segments": translationFiles.segments.fileSystemPath],
                sourceFingerprint: TranscriptionFingerprint.make(segments: bilingual),
                pipelineVersion: SubtitlePipelineVersion.current
            ),
            to: translationFiles.manifest
        )
    }

    private static func installSilentAudio(for episode: EpisodeRecord, duration: UInt32 = 1) {
        guard let files = try? LocalFileStore().episodeFiles(episodeID: episode.id) else { return }
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = sampleRate * duration
        let dataSize = sampleCount * 2
        var wav = Data()
        func append(_ text: String) { wav.append(contentsOf: text.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        append("RIFF")
        append(UInt32(36) + dataSize)
        append("WAVEfmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        append("data")
        append(dataSize)
        wav.append(Data(repeating: 0, count: Int(dataSize)))
        try? wav.write(to: files.sourceAudio, options: .atomic)
        episode.localAudioPath = files.sourceAudio.fileSystemPath
    }
}

struct LinguaThemeAppearanceProbe: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if UITestSupport.isEnabled {
            Text(colorScheme == .light ? "light" : "dark")
                .font(.system(size: 1))
                .foregroundStyle(Color.primary.opacity(0.001))
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("theme.appearance")
                .accessibilityValue(colorScheme == .light ? "light" : "dark")
        }
    }
}

private final class UITestBlockingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

struct UITestScenarioView: View {
    @Environment(SettingsStore.self) private var settings
    @Query private var episodes: [EpisodeRecord]
    @Query private var subscriptions: [PodcastSubscription]
    @Query private var videos: [YTVideoRecord]
    @Query private var channels: [YTChannelRecord]
    let scenario: UITestScenario
    @State private var showingUITestSettings = false

    @ViewBuilder
    var body: some View {
        Group {
            switch scenario {
            case .podcastQueued, .podcastQueuedMissingConfiguration, .podcastRunning, .podcastCompletionTransition, .podcastReady, .podcastFollow, .podcastLockResume, .podcastFailed, .podcastCloudCheckRequired:
                if let episode = episodes.first {
                    NavigationStack { EpisodeDetailView(episode: episode) }
                } else {
                    ProgressView().accessibilityIdentifier("fixture.loading")
                }
            case .podcastLargeList:
                if let subscription = subscriptions.first {
                    NavigationStack {
                        PodcastProgramDetailView(subscription: subscription, selectedTab: .constant(.programs))
                    }
                } else {
                    ProgressView().accessibilityIdentifier("fixture.loading")
                }
            case .youtubePartial, .youtubeFailed, .youtubeReady:
                if let video = videos.first {
                    NavigationStack { YTVideoPlayerScreen(video: video) }
                } else {
                    ProgressView().accessibilityIdentifier("fixture.loading")
                }
            case .youtubeChannel:
                if let channel = channels.first {
                    NavigationStack { YTChannelDetailView(channel: channel) }
                } else {
                    ProgressView().accessibilityIdentifier("fixture.loading")
                }
            case .mobileSetup:
                MobileSetupView()
            case .tabs, .firstLaunch:
                EmptyView()
            }
        }
        // Bottom overlay keeps nav-bar trailing controls (translation toggle) tappable.
        .overlay(alignment: .bottomLeading) {
            if scenarioShowsSubtitleTestChrome {
                uiTestSubtitleChrome
            }
        }
        .sheet(isPresented: $showingUITestSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showingUITestSettings = false }
                                .accessibilityIdentifier("uitest.close-settings")
                        }
                    }
            }
            .environment(settings)
        }
    }

    private var scenarioShowsSubtitleTestChrome: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment["LINGUACAST_UI_HIDE_TEST_CHROME"] == "1"
            || processInfo.arguments.contains("-linguacast-ui-hide-test-chrome") {
            return false
        }
        switch scenario {
        case .podcastReady, .podcastFollow, .podcastLockResume,
             .youtubeReady, .youtubePartial, .youtubeFailed:
            return true
        default:
            return false
        }
    }

    private var uiTestSubtitleChrome: some View {
        HStack(spacing: 8) {
            Button("Apply Subtitle Fixture") {
                _ = UITestSupport.applyPendingSubtitlePresentationUpdate(to: settings)
            }
            .accessibilityIdentifier("uitest.apply-subtitle-update")

            Button("UITest Settings") {
                showingUITestSettings = true
            }
            .accessibilityIdentifier("uitest.open-settings")
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 8)
        .padding(.bottom, 8)
    }
}
