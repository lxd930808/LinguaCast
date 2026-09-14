import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit
import PlayerKit

#if os(tvOS)
extension EpisodeDetailView {

    var tvOSBody: some View {
        VStack(spacing: 0) {
            TVEpisodeHeader(
                showTitle: episode.showTitle,
                episodeTitle: episode.episodeTitle,
                publishedAt: episode.publishedAt,
                showsSubtitleToggle: episode.status == "completed",
                showChinese: showChinese,
                onClose: { dismiss() },
                onToggleChinese: { showChinese.toggle() },
                onClearAndRegenerate: episode.status == "completed" ? clearAndRegenerateProcessing : nil
            )
            tvOSMainArea
        }
        .background(LinguaScreenBackground())
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    var tvOSMainArea: some View {
        if episode.status != "completed" {
            VStack(spacing: 18) {
                PodcastEpisodeMetadataHeader(
                    episode: episode,
                    fallbackArtworkURL: fallbackPodcastArtworkURL,
                    fallbackArtworkSource: fallbackPodcastArtworkSource
                )
                .frame(maxWidth: 1_100)
                TVEpisodeActionShelf(
                    episode: episode,
                    progressStepTitle: progressStepTitle,
                    processingAction: processingAction,
                    hasGenerationKeys: settings.configuration.hasRequiredGenerationKeys,
                    hasASRKey: settings.configuration.hasDashScopeASRKey,
                    hasTranslationKey: settings.configuration.hasTranslationKey,
                    cloudState: cloudGenerationState,
                    cloudSelected: cloudGenerationSelected,
                    queuedTitle: tvQueuedStateTitle,
                    displayErrorMessage: cloudAwareErrorMessage,
                    onStart: startProcessing,
                    onRetry: {
                        runner.retry(episode: episode, context: modelContext, configuration: settings.configuration)
                    },
                    cloudCheckRequired: cloudCheckRequired,
                    onGenerateAnyway: {
                        runner.generateWithoutCloudCheck(
                            episode: episode,
                            context: modelContext,
                            configuration: settings.configuration
                        )
                    },
                    onClearAndRegenerate: clearAndRegenerateProcessing,
                    onOpenSettings: openSettingsAndDismiss
                )
            }
        } else if isLoadingSegments {
            TVCenteredStatusPanel(
                state: .loading,
                systemImage: "text.quote",
                title: L10n.string("episode_detail.loading_bilingual_subtitles", fallback: "Loading bilingual subtitles"),
                message: L10n.string("episode_detail.ready_to_play_content", fallback: "Ready to play content")
            )
        } else if segmentLoadError != nil {
            TVCenteredStatusPanel(
                state: .failure,
                systemImage: "exclamationmark.triangle",
                title: L10n.string("episode_detail.failed_to_read_bilingual_subtitles", fallback: "Failed to read bilingual subtitles"),
                message: segmentLoadError ?? L10n.string("episode_detail.please_go_back_and_re_enter_this_episode", fallback: "Please go back and re-enter this episode.")
            )
        } else {
            VStack(spacing: 0) {
                tvOSReadingView
                    .frame(maxHeight: .infinity)
                TVPlayerBar(
                    player: player,
                    showsLocateButton: !isFollowingPlayback,
                    onLocate: locateCurrentPlayback,
                    onPlaybackTimeChanged: { persistPlaybackProgress($0) },
                    onDurationChanged: persistPlaybackDurationIfNeeded
                )
                    .focusSection()
            }
        }
    }

    var tvOSReadingView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                PodcastEpisodeMetadataHeader(
                    episode: episode,
                    fallbackArtworkURL: fallbackPodcastArtworkURL,
                    fallbackArtworkSource: fallbackPodcastArtworkSource
                )
                .padding(.bottom, 20)

                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    TVReadingSegment(
                        segment: segment,
                        isActive: player.activeSequence == segment.sequence,
                        showChinese: showChinese,
                        showsSpeaker: shouldShowSpeaker(at: index),
                        subtitlePresentation: settings.committedSubtitlePresentation,
                        onPlay: { player.play(segment: segment) }
                    )
                    .focused($focusedTranscriptSequence, equals: segment.sequence)
                    .id(segment.sequence)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 96)
            .padding(.top, 12)
            .padding(.bottom, 34)
        }
        // Shared top-biased anchor: keeps a multi-line active row fully visible instead of
        // clipping it when centered.
        .scrollPosition(id: $scrollPositionSequence, anchor: activeTranscriptScrollAnchor)
        .onAppear {
            scrollPositionSequence = player.activeSequence
            hasInitializedScroll = true
        }
        .onChange(of: player.activeSequence) { _, sequence in
            guard isFollowingPlayback else { return }
            scrollToSequence(sequence)
        }
        .onChange(of: locatePlaybackRequest) { _, _ in
            scrollToSequence(player.activeSequence)
        }
        .onChange(of: settings.committedSubtitlePresentation) { _, _ in
            // Size/order can change row height; re-anchor only while follow is on.
            guard isFollowingPlayback else { return }
            scrollToSequence(player.activeSequence)
        }
        .onChange(of: focusedTranscriptSequence) { previousSequence, sequence in
            suspendFollowingIfUserFocusedAnotherSegment(
                from: previousSequence,
                to: sequence
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle.ready-state")
    }

    func suspendFollowingIfUserFocusedAnotherSegment(
        from previousSequence: Int?,
        to sequence: Int?
    ) {
        guard hasInitializedScroll,
              isFollowingPlayback,
              previousSequence != nil,
              let sequence,
              sequence != player.activeSequence
        else { return }
        isFollowingPlayback = false
    }
}

private enum TVDetailPalette {
    static let panelBackground = LinguaTheme.surfaceElevated
    static let rowBackground = LinguaTheme.surface
    static let controlBackground = LinguaTheme.surfaceElevated
}

private struct TVEpisodeHeader: View {
    let showTitle: String
    let episodeTitle: String
    let publishedAt: Date?
    let showsSubtitleToggle: Bool
    let showChinese: Bool
    let onClose: () -> Void
    let onToggleChinese: () -> Void
    var onClearAndRegenerate: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title2.weight(.semibold))
                    .frame(width: 58, height: 58)
                    .background(TVDetailPalette.controlBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("common.close", fallback: "Close"))
            .accessibilityIdentifier("podcast.close-detail")

            VStack(alignment: .leading, spacing: 7) {
                Text(showTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(episodeTitle)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .multilineTextAlignment(.leading)
                if let publishedAt {
                    Text(publishedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)

            if let onClearAndRegenerate {
                Button(action: onClearAndRegenerate) {
                    Label(
                        L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(width: 220, height: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("podcast.clear-and-regenerate")
            }

            if showsSubtitleToggle {
                Button(action: onToggleChinese) {
                    Label(
                        showChinese
                            ? L10n.string("subtitles.bilingual", fallback: "Bilingual")
                            : L10n.string("subtitles.english_only", fallback: "English Only"),
                        systemImage: showChinese ? "captions.bubble.fill" : "captions.bubble"
                    )
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .frame(width: 172, height: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                    showChinese
                        ? L10n.string("subtitles.hide_translation", fallback: "Hide Translation")
                        : L10n.string("subtitles.show_translation", fallback: "Show Translation")
                )
                .accessibilityIdentifier("transcript.translation-toggle")
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 48)
        .padding(.bottom, 18)
    }
}

private struct TVEpisodeActionShelf: View {
    private enum FocusedAction: Hashable {
        case start
        case retry
        case generateAnyway
        case clearAndRegenerate
        case settings
    }

    let episode: EpisodeRecord
    let progressStepTitle: String
    let processingAction: PodcastEpisodeProcessingAction
    let hasGenerationKeys: Bool
    let hasASRKey: Bool
    let hasTranslationKey: Bool
    let cloudState: CloudContentGenerationState
    let cloudSelected: Bool
    let queuedTitle: String
    /// Localized failure text (cloud codes resolved by the WP14 presenter).
    let displayErrorMessage: String?
    let onStart: () -> Void
    let onRetry: () -> Void
    let cloudCheckRequired: Bool
    let onGenerateAnyway: () -> Void
    let onClearAndRegenerate: () -> Void
    let onOpenSettings: () -> Void
    @FocusState private var focusedAction: FocusedAction?

    var body: some View {
        Group {
            if isRunning {
                runningContent
            } else {
                actionableContent
            }
        }
        .padding(38)
        .frame(maxWidth: 1240)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(TVDetailPalette.panelBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(LinguaTheme.border, lineWidth: 1)
                }
                .accessibilityElement()
                .accessibilityLabel(shelfAccessibilityLabel)
                .accessibilityIdentifier("podcast.action-shelf")
        }
        .padding(.horizontal, 96)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .focusSection()
        .onAppear { focusedAction = defaultFocusedAction }
        .onChange(of: processingAction) { _, _ in focusedAction = defaultFocusedAction }
    }

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    L10n.string("episode_detail.generating_bilingual_subtitles", fallback: "Generating bilingual subtitles"),
                    systemImage: "hourglass"
                )
                .font(.title2.bold())
                Spacer()

            }
            PodcastGenerationProgressView(episode: episode, showsBar: false)
                .font(.title3)
                .foregroundStyle(.secondary)
            PodcastPipelineStageRail(step: episode.pipelineStep)
            if cloudSelected, cloudState.audioReady, !cloudState.subtitlesReady {
                Label(
                    L10n.string(
                        "cloud.audio_ready",
                        fallback: "Audio is ready. Bilingual subtitles are still being generated."
                    ),
                    systemImage: "waveform.circle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(LinguaTheme.success)
                .accessibilityIdentifier("podcast.cloud-audio-ready")
            }
            if cloudSelected, let lastUpdated = cloudState.lastUpdated {
                Text(L10n.format(
                    "cloud.last_updated",
                    fallback: "Last updated %@",
                    lastUpdated.formatted(date: .omitted, time: .shortened)
                ))
                .font(.callout)
                .foregroundStyle(.tertiary)
            }
            Text(L10n.string("episode_detail.processing_continues_in_background", fallback: "You can leave this page. Processing will continue in the background."))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("podcast.processing-background-note")
            HStack(spacing: 14) {
                actionButton(
                    title: L10n.string("episode_detail.retry", fallback: "Retry"),
                    systemImage: "arrow.clockwise",
                    focus: .retry,
                    identifier: "subtitle.retry",
                    action: onRetry
                )
                actionButton(
                    title: L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"),
                    systemImage: "arrow.triangle.2.circlepath",
                    focus: .clearAndRegenerate,
                    identifier: "podcast.clear-and-regenerate",
                    action: onClearAndRegenerate
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcast.processing-progress")
    }

    private var actionableContent: some View {
        HStack(alignment: .center, spacing: 56) {
            HStack(alignment: .top, spacing: 22) {
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "waveform.badge.plus")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(isFailed ? LinguaTheme.danger : LinguaTheme.accent)
                    .frame(width: 56)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    stateTitle
                    Text(stateMessage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    if !hasGenerationKeys {
                        missingConfiguration
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                if cloudCheckRequired {
                    actionButton(
                        title: L10n.string("episode_detail.retry", fallback: "Retry"),
                        systemImage: "icloud.and.arrow.down",
                        focus: .retry,
                        identifier: "subtitle.cloud-retry",
                        action: onRetry
                    )
                    actionButton(
                        title: L10n.string("episodes.generate_bilingual_subtitles", fallback: "Generate bilingual subtitles"),
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                        focus: .generateAnyway,
                        identifier: "subtitle.cloud-bypass",
                        action: onGenerateAnyway
                    )
                } else if processingAction == .start {
                    actionButton(
                        title: L10n.string("episode_detail.start_processing", fallback: "Start processing"),
                        systemImage: "play.fill",
                        focus: .start,
                        identifier: "podcast.start-processing",
                        action: onStart
                    )
                } else if processingAction == .retry {
                    if cloudState.retryable {
                        actionButton(
                            title: L10n.string("episode_detail.retry", fallback: "Retry"),
                            systemImage: "arrow.clockwise",
                            focus: .retry,
                            identifier: "subtitle.retry",
                            action: onRetry
                        )
                    } else {
                        Text(L10n.string(
                            "cloud.error.not_retryable",
                            fallback: "This failure cannot be retried directly. Use Clear and regenerate to start over."
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 280)
                        .accessibilityIdentifier("podcast.cloud-not-retryable")
                    }
                    actionButton(
                        title: L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"),
                        systemImage: "arrow.triangle.2.circlepath",
                        focus: .clearAndRegenerate,
                        identifier: "podcast.clear-and-regenerate",
                        action: onClearAndRegenerate
                    )
                }

                if !cloudCheckRequired && processingAction == .openSettings {
                    settingsButton
                        .buttonStyle(.borderedProminent)
                } else if !cloudCheckRequired && processingAction == .retry {
                    settingsButton
                        .buttonStyle(.borderedProminent)
                        .tint(.gray)
                }
            }
            .frame(minWidth: 320)
        }
    }

    @ViewBuilder
    private var stateTitle: some View {
        let title = isFailed
            ? L10n.string("episode_detail.processing_failed", fallback: "Processing did not finish")
            : queuedTitle
        if isFailed {
            Text(title)
                .font(.title2.bold())
                .accessibilityIdentifier("subtitle.error-state")
        } else {
            Text(title)
                .font(.title2.bold())
        }
    }

    private var stateMessage: String {
        if isFailed {
            return displayErrorMessage ?? displayMessage
        }
        return L10n.string(
            "episode_detail.process_to_play_and_view_bilingual_subtitles",
            fallback: "Process this episode to play its audio and view bilingual subtitles."
        )
    }

    private var missingConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hasASRKey {
                Label(L10n.string("settings.dashscope_api_key", fallback: "DashScope API Key"), systemImage: "xmark.circle.fill")
            }
            if !hasTranslationKey {
                Label(L10n.string("settings.translation_api_key", fallback: "Translation API Key"), systemImage: "xmark.circle.fill")
            }
        }
        .font(.callout)
        .foregroundStyle(LinguaTheme.warning)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        focus: FocusedAction,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(width: 280, height: 58)
        }
        .buttonStyle(.borderedProminent)
        .focused($focusedAction, equals: focus)
        .accessibilityIdentifier(identifier)
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Label(L10n.string("episode_detail.go_to_settings", fallback: "Go to Settings"), systemImage: "gearshape")
                .frame(width: 280, height: 58)
        }
        .focused($focusedAction, equals: .settings)
        .accessibilityIdentifier("podcast.open-settings")
    }

    private var defaultFocusedAction: FocusedAction? {
        switch processingAction {
        case _ where cloudCheckRequired: .retry
        case .start: .start
        case .retry: .retry
        case .openSettings: .settings
        default: nil
        }
    }

    private var shelfAccessibilityLabel: String {
        if isRunning {
            return L10n.string("episode_detail.generating_bilingual_subtitles", fallback: "Generating bilingual subtitles")
        }
        if isFailed {
            return L10n.string("episode_detail.processing_failed", fallback: "Processing did not finish")
        }
        return L10n.string("episodes.queuing", fallback: "Not processed")
    }

    private var isRunning: Bool { episode.status == "running" }
    private var isFailed: Bool { episode.status == "failed" }

    private var displayMessage: String {
        ASRProgressText.display(
            message: episode.pipelineMessage,
            fallback: progressStepTitle
        )
    }
}

private struct TVCenteredStatusPanel: View {
    enum State { case loading, information, failure }
    var state: State = .information
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            if state == .loading { ProgressView() }
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(state == .failure ? LinguaTheme.danger : LinguaTheme.secondaryText)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if state == .failure {
                Text(L10n.string("empty.return_and_retry", fallback: "Return to the previous page and try again."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(38)
        .frame(maxWidth: 600)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TVDetailPalette.panelBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TVReadingSegment: View {
    let segment: LearningSegment
    let isActive: Bool
    let showChinese: Bool
    let showsSpeaker: Bool
    let subtitlePresentation: SubtitlePresentationPreferences
    let onPlay: () -> Void

    /// Dynamic Type scale applied after committed base point sizes.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var englishFontSize: CGFloat {
        CGFloat(subtitlePresentation.englishPointSize(on: .tvOS)) * dynamicTypeScale
    }

    private var targetFontSize: CGFloat {
        CGFloat(subtitlePresentation.targetPointSize(on: .tvOS)) * dynamicTypeScale
    }

    /// Non-empty translation when bilingual mode is on; otherwise nil (no empty row).
    private var visibleTranslation: String? {
        guard showChinese else { return nil }
        let trimmed = segment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : segment.translation
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 32)
                    .opacity(isActive ? 1 : 0)

                Text(formatTime(segment.startMS))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    if showsSpeaker,
                       let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !speaker.isEmpty {
                        Text(speaker)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    orderedSubtitleLines
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? LinguaTheme.accent.opacity(0.19) : TVDetailPalette.rowBackground.opacity(0.58))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? LinguaTheme.accent.opacity(0.8) : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(width: 5)
                    .padding(.vertical, 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcript.segment.\(segment.sequence)")
    }

    /// English stays primary; target secondary. Order follows committed prefs; VO matches visual order.
    @ViewBuilder
    private var orderedSubtitleLines: some View {
        switch subtitlePresentation.order {
        case .englishFirst:
            englishLine
            if let visibleTranslation {
                targetLine(visibleTranslation)
            }
        case .targetFirst:
            if let visibleTranslation {
                targetLine(visibleTranslation)
            }
            englishLine
        }
    }

    private var englishLine: some View {
        Text(segment.learningText)
            .font(.system(size: englishFontSize, weight: isActive ? .semibold : .regular))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func targetLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: targetFontSize, weight: .regular))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TVPlayerBar: View {
    private enum FocusedControl: Hashable {
        case skipBack
        case playPause
        case skipForward
        case locate
    }

    @Bindable var player: AudioPlaybackController
    let showsLocateButton: Bool
    let onLocate: () -> Void
    let onPlaybackTimeChanged: (TimeInterval) -> Void
    let onDurationChanged: (TimeInterval) -> Void
    @FocusState private var focusedControl: FocusedControl?

    var body: some View {
        VStack(spacing: 10) {
            if let errorMessage = player.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 16) {
                Text(formatTime(player.currentTime))
                LinguaProgressBar(value: player.currentTime / max(player.duration, 1))
                    .accessibilityIdentifier("player.progress")
                Text(formatTime(player.duration))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    player.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .frame(width: 70, height: 48)
                }
                .buttonStyle(.bordered)
                .focused($focusedControl, equals: .skipBack)
                .accessibilityLabel(L10n.string("player.back_15_seconds", fallback: "Back 15 Seconds"))
                .accessibilityIdentifier("player.skip-back")

                Button {
                    player.playPause()
                } label: {
                    Label(player.isPlaying ? L10n.string("episode_detail.pause", fallback: "Pause") : L10n.string("episode_detail.play", fallback: "Play"), systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: 124, height: 48)
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedControl, equals: .playPause)
                .accessibilityIdentifier("player.play-pause")

                Button {
                    player.skip(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .frame(width: 70, height: 48)
                }
                .buttonStyle(.bordered)
                .focused($focusedControl, equals: .skipForward)
                .accessibilityLabel(L10n.string("player.forward_15_seconds", fallback: "Forward 15 Seconds"))
                .accessibilityIdentifier("player.skip-forward")

                if showsLocateButton {
                    Button(action: onLocate) {
                        Label(L10n.string("player.return_to_playback_position", fallback: "Return to Playback Position"), systemImage: "location.fill")
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .frame(width: 210, height: 48)
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedControl, equals: .locate)
                    .accessibilityIdentifier("player.locate-playback")
                }

                Picker(L10n.string("episode_detail.speed", fallback: "speed"), selection: $player.playbackRate) {
                    Text(verbatim: "0.75x").tag(Float(0.75))
                    Text(verbatim: "1x").tag(Float(1.0))
                    Text(verbatim: "1.25x").tag(Float(1.25))
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.horizontal, 72)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .background(LinguaTheme.backgroundRaised.opacity(0.94))
        .background {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("media.playback-controls")
        }
        .onChange(of: player.currentTime) { _, currentTime in
            onPlaybackTimeChanged(currentTime)
        }
        .onChange(of: player.duration) { _, duration in
            onDurationChanged(duration)
        }
        .onAppear {
            focusedControl = .playPause
        }
    }

}
#endif
