import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

struct YTVideoPlayerScreen: View {
    @Environment(\.modelContext) var modelContext
    @Environment(SettingsStore.self) var settings
    let video: YTVideoRecord

    @State var viewModel: YTVideoPlayerScreenViewModel

    init(video: YTVideoRecord) {
        self.video = video
        _viewModel = State(initialValue: YTVideoPlayerScreenViewModel(video: video))
    }

    var body: some View {
        ytPlayerPlatformChrome(
            ZStack(alignment: .bottom) {
                playerSurface(viewModel)
                platformPlayerOverlay
            }
            .accessibilityIdentifier("screen.youtube-player")
            .background(.black)
            .ignoresSafeArea()
            .navigationTitle(L10n.string("ytvideo_player.shadowing", fallback: "Shadowing")),
            subtitleOverlay: playerSubtitleOverlay
        )
        .alert(L10n.string("ytvideo_player.subtitles", fallback: "subtitles"), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(L10n.string("ytvideo_player.ok", fallback: "OK"), role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task(id: video.id) {
            viewModel.loadPersistedPlaybackState()
            if UITestSupport.isEnabled {
                installUITestPlaybackFixture(in: viewModel)
            }
        }
        .onChange(of: viewModel.currentTime) { _, value in
            viewModel.persistPlaybackProgress(value, context: modelContext)
            viewModel.synchronizeSentenceContext()
        }
        .onChange(of: viewModel.subtitleState.segments) {
            viewModel.synchronizeSentenceContext()
        }
        .onChange(of: viewModel.duration) { _, value in
            viewModel.persistPlaybackDuration(value, context: modelContext)
        }
        .onDisappear {
            viewModel.persistPlaybackProgress(viewModel.currentTime, force: true, context: modelContext)
        }
    }

    @ViewBuilder
    private var playerSubtitleOverlay: some View {
        if UITestSupport.isEnabled {
            let segment = viewModel.subtitleState.segment(at: viewModel.currentTime)
            YTSubtitleDisplayView(
                english: segment?.text,
                translation: segment?.translation,
                errorMessage: nil,
                isPreparing: segment == nil,
                preferences: settings.committedSubtitlePresentation,
                displayMode: settings.committedConfiguration.subtitleDisplayMode
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        } else {
            DualSubtitleOverlay(
                video: video,
                currentTime: viewModel.currentTime,
                subtitleState: viewModel.subtitleState,
                showsDisplay: showsInlineSubtitleOverlay
            )
        }
    }

    @ViewBuilder
    private func playerSurface(_ viewModel: YTVideoPlayerScreenViewModel) -> some View {
        @Bindable var viewModel = viewModel
        if UITestSupport.isEnabled {
            Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.playbackController.command) { _, command in
                consumeUITestPlaybackCommand(command, in: viewModel)
            }
        } else {
            YTPlayerView(
                videoID: video.id,
                currentTime: $viewModel.currentTime,
                duration: $viewModel.duration,
                initialTime: viewModel.initialTime,
                durationHint: video.playbackDurationSeconds,
                subtitleState: viewModel.subtitleState,
                playbackController: viewModel.playbackController,
                onPlaybackEnded: { viewModel.markPlaybackCompleted(context: modelContext) },
                onPlaybackMetricsChange: { height, codec in
                    viewModel.updatePlaybackMetrics(height: height, codec: codec, context: modelContext)
                },
                onAvailableQualitiesChange: { tiers in
                    viewModel.availableQualityTiers = tiers.isEmpty
                        ? YTStreamSelectionPolicy.qualityTierOptions
                        : tiers
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        }
    }

    private func installUITestPlaybackFixture(in viewModel: YTVideoPlayerScreenViewModel) {
        guard viewModel.subtitleState.segments.isEmpty else { return }
        viewModel.duration = 18
        viewModel.subtitleState.segments = UITestSupport.youtubePlaybackSegments
        viewModel.synchronizeSentenceContext()
    }

    private func consumeUITestPlaybackCommand(
        _ command: YTPlaybackCommand?,
        in viewModel: YTVideoPlayerScreenViewModel
    ) {
        guard let command else { return }
        switch command.action {
        case .play:
            viewModel.playbackController.report(isPlaying: true)
        case .pause:
            viewModel.playbackController.report(isPlaying: false)
        case .seek(let time, let resumeAfterSeek):
            viewModel.currentTime = min(max(0, time), max(viewModel.duration, 0))
            viewModel.playbackController.report(isPlaying: resumeAfterSeek)
        }
        viewModel.synchronizeSentenceContext()
    }
}

struct SubtitleStatusRow: View {
    var video: YTVideoRecord
    var subtitleState: YTSubtitleDisplayState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(labelText, systemImage: iconName)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let generation = generationProgressText {
                if let generationProgressValue {
                    ProgressView(value: min(max(generationProgressValue, 0), 1))
                } else {
                    ProgressView()
                }
                Text(generation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let lastError = video.lastError, !lastError.isEmpty, video.sourceGenerationStep == nil {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var generationProgressText: String? {
        YTSourceGenerationProgressText.title(
            step: video.sourceGenerationStep,
            progress: video.sourceGenerationProgress,
            downloadProgress: subtitleState?.audioDownloadProgress,
            bytesPerSecond: subtitleState?.audioDownloadBytesPerSecond
        )
    }

    private var generationProgressValue: Double? {
        if video.sourceGenerationStep == "downloading" {
            return subtitleState?.audioDownloadProgress
        }
        return video.sourceGenerationProgress
    }

    private var labelText: String {
        if video.sourceGenerationStep != nil {
            return L10n.string(
                "ytvideo_player.generate_from_audio",
                fallback: "Generate bilingual content from audio"
            )
        }
        if video.bilingualSubtitlesCompleted { return L10n.string("ytvideo_player.bilingual_subtitles_are_ready", fallback: "Bilingual subtitles are ready") }
        switch video.subtitleStatus {
        case "ready": return L10n.string("ytvideo_player.bilingual_subtitles_are_ready", fallback: "Bilingual subtitles are ready")
        case "partial": return L10n.string("ytvideo_player.the_english_subtitles_have_been_saved_and_the_translation_will_b", fallback: "The English subtitles have been saved and the translation will be tried again.")
        case "running": return L10n.string("ytvideo_player.getting_english_subtitles", fallback: "Getting English subtitles")
        case "translating":
            if let progress {
                return L10n.format("subtitles.translating_progress", fallback: "LLM subtitle translation %@/%@", String(progress.translatedCount), String(progress.totalCount))
            }
            return L10n.string("ytvideo_player.translating_subtitles_in_llm", fallback: "Translating subtitles in LLM")
        case "failed": return L10n.string("ytvideo_player.subtitles_not_available", fallback: "Subtitles not available")
        default:
            if video.enReady { return L10n.string("ytvideo_player.the_english_subtitles_have_been_saved_and_the_translation_will_b", fallback: "The English subtitles have been saved and the translation will be tried again.") }
            return L10n.string("ytvideo_player.automatically_obtain_subtitles_after_entering_the_play_page", fallback: "Automatically obtain subtitles after entering the play page")
        }
    }

    private var iconName: String {
        if video.sourceGenerationStep != nil { return "waveform" }
        if video.bilingualSubtitlesCompleted { return "checkmark.circle" }
        if video.enReady { return "text.quote" }
        if video.subtitleStatus == "failed" { return "exclamationmark.triangle" }
        if video.subtitleStatus == "running" || video.subtitleStatus == "translating" { return "clock" }
        return "captions.bubble"
    }

    private var statusText: String {
        if video.sourceGenerationStep != nil {
            return L10n.string("ytvideo_player.fetching", fallback: "Fetching")
        }
        if video.bilingualSubtitlesCompleted { return L10n.string("common.ready", fallback: "Ready") }
        switch video.subtitleStatus {
        case "ready": return L10n.string("common.ready", fallback: "Ready")
        case "partial": return L10n.string("ytvideo_player.partially_ready", fallback: "Partially ready")
        case "running": return L10n.string("ytvideo_player.fetching", fallback: "Fetching")
        case "translating": return L10n.string("ytvideo_player.translating", fallback: "Translating")
        case "failed": return L10n.string("common.failed", fallback: "Failed")
        case "not_requested": return L10n.string("ytvideo_player.not_requested", fallback: "Not requested")
        default: return video.enReady ? L10n.string("ytvideo_player.partially_ready", fallback: "Partially ready") : L10n.string("ytvideo_player.not_requested", fallback: "Not requested")
        }
    }

    private var progress: YTSubtitleTranslationProgress? {
        guard let totalCount = video.subtitleTotalCount, totalCount > 0 else { return nil }
        return YTSubtitleTranslationProgress(
            translatedCount: video.subtitleTranslatedCount ?? 0,
            totalCount: totalCount
        )
    }
}
