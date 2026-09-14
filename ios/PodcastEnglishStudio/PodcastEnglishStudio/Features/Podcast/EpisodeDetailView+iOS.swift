import SwiftUI
import AVFoundation
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit
import PlayerKit

#if !os(tvOS)
extension EpisodeDetailView {

    var iOSBody: some View {
        Group {
            if episode.status != "completed" {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        PodcastEpisodeMetadataHeader(
                            episode: episode,
                            fallbackArtworkURL: fallbackPodcastArtworkURL,
                            fallbackArtworkSource: fallbackPodcastArtworkSource
                        )
                        .padding(.horizontal)
                        unavailableView
                    }
                    .padding(.vertical, 12)
                }
            } else if isLoadingSegments {
                loadingSegmentsView
            } else if segmentLoadError != nil {
                segmentUnavailableView
            } else {
                readingView
            }
        }
        .linguaPage()
        // Phase 0 attachment: keep the screen awake during playback. The modifier is a stub
        // until WT5 implements it (isIdleTimerDisabled) in KeepScreenAwakeModifier.swift.
        .keepScreenAwake(while: player.isPlaying || chinesePlayer.isPlaying || chinesePlayer.isPreparing || chinesePlayer.isBuffering)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if episode.status == "completed" {
                VStack(spacing: 0) {
                    chineseModeControl
                    if chinesePlayer.isSelected {
                        ChinesePlayerBar(player: chinesePlayer, onLocate: locateCurrentPlayback)
                    } else {
                        PlayerBar(
                            player: player,
                            showsLocateButton: !isFollowingPlayback,
                            onLocate: locateCurrentPlayback,
                            onPlaybackTimeChanged: { persistPlaybackProgress($0) },
                            onDurationChanged: persistPlaybackDurationIfNeeded,
                            onPlaybackStarted: handlePlaybackStarted
                        )
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("media.playback-controls")
            }
        }
        .navigationTitle(episode.episodeTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the bottom tab bar on the pushed (Home) player path; a no-op when presented
        // in a fullScreenCover (no TabView ancestor). iOS-only; tvOS hides its own tab bar.
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                Text(episode.episodeTitle)
                    .font(.headline)
                    .lineLimit(2)
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    Button {
                        showChinese.toggle()
                    } label: {
                        Text(
                            showChinese
                                ? L10n.string("subtitles.bilingual", fallback: "Bilingual")
                                : L10n.string("subtitles.english_only", fallback: "English Only")
                        )
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(
                        showChinese
                            ? L10n.string("subtitles.hide_translation", fallback: "Hide Translation")
                            : L10n.string("subtitles.show_translation", fallback: "Show Translation")
                    )
                    .accessibilityIdentifier("transcript.translation-toggle")
                    Button { showingPlaybackSettings = true } label: {
                        Image(systemName: "gearshape")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.string("playback.settings.title", fallback: "Playback Settings"))
                    .accessibilityIdentifier("player.settings.podcast")
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .sheet(isPresented: $showingPlaybackSettings) {
            PodcastPlaybackSettingsPanel(
                episode: episode, showChinese: $showChinese,
                playbackRate: Binding(get: {
                    chinesePlayer.isSelected ? chinesePlayer.playbackRate : player.playbackRate
                }, set: { rate in
                    if chinesePlayer.isSelected { chinesePlayer.playbackRate = rate }
                    else { player.playbackRate = rate }
                }),
                chinesePlayer: chinesePlayer, canSelectChinese: !segments.isEmpty,
                onSelectRhythm: selectChineseRhythm,
                onRegenerate: clearAndRegenerateProcessing
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               kind == AVAudioSession.InterruptionType.began.rawValue { chinesePlayer.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { chinesePlayer.pause() }
            // A new route moves the clock the next sentence was scheduled against.
            else { chinesePlayer.handleRouteChange() }
        }
        .onChange(of: chinesePlayer.originalTime) { _, time in
            if chinesePlayer.isSelected { persistPlaybackProgress(time, allowCompletion: false) }
        }
        .onChange(of: chinesePlayer.didFinishEpisode) { _, finished in
            if finished { persistPlaybackProgress(chinesePlayer.duration, force: true) }
        }
        .onChange(of: segments) { _, _ in
            chinesePlayer.invalidateIfChanged(episodeID: episode.id, language: settings.configuration.translationTargetLanguage, rows: segments)
        }
        .onChange(of: settings.configuration.translationTargetLanguage) { _, _ in chinesePlayer.stop() }
        .onChange(of: scenePhase) { _, phase in
            chinesePlayer.setForeground(phase == .active)
            if chinesePlayer.isSelected {
                if phase != .active { persistPlaybackProgress(chinesePlayer.originalTime, force: true, allowCompletion: false) }
            } else { handleScenePhaseChange(phase) }
        }
    }

    var displayedActiveSequence: Int? {
        chinesePlayer.isSelected ? chinesePlayer.activeSequence : player.activeSequence
    }

    var chineseModeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlaybackSegmentedControl(
                selection: chinesePlayer.isSelected,
                firstTitle: L10n.string("tts.original", fallback: "Original"),
                secondTitle: L10n.string("tts.chinese", fallback: "Chinese"),
                firstIdentifier: "player.mode-original", secondIdentifier: "player.mode-chinese",
                onSelect: selectPlaybackSource
            )
            .disabled(segments.isEmpty)
            if !chinesePlayer.isSelected, let error = chinesePlayer.errorMessage {
                Text(error).font(.caption).foregroundStyle(LinguaTheme.danger)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private func selectPlaybackSource(_ chinese: Bool) {
        guard chinese != chinesePlayer.isSelected else { return }
        if chinese {
            persistPlaybackProgress(player.currentTime, force: true)
            chinesePlayer.select(episodeID: episode.id, language: settings.configuration.translationTargetLanguage,
                rows: segments, original: AudioPlaybackControllerBridge(title: episode.episodeTitle, time: player.currentTime,
                    duration: player.duration, rate: player.playbackRate, isPlaying: player.isPlaying,
                    pause: { player.pausePlayback() }))
        } else {
            let resume = chinesePlayer.shouldResumeOriginal
            let time = chinesePlayer.originalSentenceStart
            chinesePlayer.stop()
            chinesePlayer.forgetSelectedMode()
            player.playbackRate = chinesePlayer.playbackRate
            player.prepareResume(at: time)
            if resume && !player.isPlaying { player.playPause() }
        }
    }

    private func selectChineseRhythm(natural: Bool) {
        chinesePlayer.selectRhythm(natural ? .natural : .current)
        guard !chinesePlayer.isSelected else { return }
        persistPlaybackProgress(player.currentTime, force: true)
        chinesePlayer.select(episodeID: episode.id, language: settings.configuration.translationTargetLanguage,
            rows: segments, original: AudioPlaybackControllerBridge(title: episode.episodeTitle, time: player.currentTime,
                duration: player.duration, rate: player.playbackRate, isPlaying: player.isPlaying,
                pause: { player.pausePlayback() }))
    }

    var readingView: some View {
        // Playback time changes every 200 ms. Keep those updates out of the lazy
        // scroll hierarchy: reapplying its layout can repeatedly adjust the inset
        // and move the retained viewport even without a new scroll request.
        StableTranscriptContent(
            state: TranscriptRenderState(episodeID: episode.id, segments: segments,
                activeSequence: displayedActiveSequence, followsPlayback: isFollowingPlayback,
                locateRequest: locatePlaybackRequest, showChinese: showChinese,
                presentation: settings.committedSubtitlePresentation),
            content: { transcriptScrollView }
        ).equatable()
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    PodcastEpisodeMetadataHeader(
                        episode: episode,
                        fallbackArtworkURL: fallbackPodcastArtworkURL,
                        fallbackArtworkSource: fallbackPodcastArtworkSource
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                    // Use the same stable identity for rows and scroll targets.
                    ForEach(Array(segments.enumerated()), id: \.element.sequence) { index, segment in
                        ReadingSegmentRow(
                            segment: segment,
                            isActive: displayedActiveSequence == segment.sequence,
                            showChinese: showChinese,
                            showsSpeaker: shouldShowSpeaker(at: index),
                            subtitlePresentation: settings.committedSubtitlePresentation,
                            onPlay: {
                                if chinesePlayer.isSelected { chinesePlayer.play(sequence: segment.sequence) }
                                else { player.play(segment: segment) }
                            }
                        )
                        .id(segment.sequence)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        guard hasInitializedScroll else { return }
                        transcriptScrollTask?.cancel()
                        updateTranscriptFollowing(after: .userDragBegan)
                    }
            )
            .onAppear {
                scrollToSequence(displayedActiveSequence, using: proxy)
                hasInitializedScroll = true
            }
            .onDisappear {
                transcriptScrollTask?.cancel()
                transcriptScrollTask = nil
            }
            .onChange(of: displayedActiveSequence) { _, sequence in
                guard isFollowingPlayback else { return }
                scrollToSequence(sequence, using: proxy)
            }
            .onChange(of: locatePlaybackRequest) { _, _ in
                scrollToSequence(displayedActiveSequence, using: proxy)
            }
            .onChange(of: showChinese) { _, _ in
                guard isFollowingPlayback else { return }
                scrollToSequence(displayedActiveSequence, using: proxy)
            }
            .onChange(of: settings.committedSubtitlePresentation) { _, _ in
                // Presentation size/order can change row height; re-anchor only while follow is on.
                guard isFollowingPlayback else { return }
                scrollToSequence(displayedActiveSequence, using: proxy)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("subtitle.ready-state")
        }
    }

    func scrollToSequence(_ sequence: Int?, using proxy: ScrollViewProxy) {
        transcriptScrollTask?.cancel()
        guard let sequence else { return }
        // LazyVStack may not have materialized the destination row yet — especially right
        // after scene reactivation. Yield so the next layout pass can build the cue before
        // scrollTo runs (otherwise the first post-unlock scroll is dropped).
        transcriptScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, isFollowingPlayback,
                  sequence == displayedActiveSequence else { return }
            proxy.scrollTo(sequence, anchor: activeTranscriptScrollAnchor)
        }
    }
}

private struct ChinesePlayerBar: View {
    @Bindable var player: EpisodeChinesePlayback
    let onLocate: () -> Void
    @State private var scrub: Double?
    var body: some View {
        VStack(spacing: 8) {
            // Keep the safe-area inset stable when synthesis/buffering changes.
            // Otherwise every buffer transition resizes the transcript during a scroll.
            HStack {
                ProgressView()
                ZStack {
                    Text(L10n.string("tts.buffering", fallback: "Buffering Chinese audio…"))
                        .opacity(player.isBuffering && !player.isPreparing ? 1 : 0)
                        .accessibilityHidden(!player.isBuffering || player.isPreparing)
                    Text(L10n.string("tts.preparing", fallback: "Preparing Chinese audio…"))
                        .opacity(player.isPreparing ? 1 : 0)
                        .accessibilityHidden(!player.isPreparing)
                }
            }
            .font(.caption)
            .opacity(player.isPreparing || player.isBuffering ? 1 : 0)
            .accessibilityHidden(!player.isPreparing && !player.isBuffering)
            if let error = player.errorMessage { Text(error).font(.caption).foregroundStyle(LinguaTheme.danger) }
            if player.stoppedSegmentID != nil {
                HStack(spacing: 16) {
                    if player.canRetryStoppedSegment {
                        Button(L10n.string("tts.retry", fallback: "Retry")) { player.retryStoppedSegment() }
                            .accessibilityIdentifier("player.chinese-retry")
                    }
                    Button(L10n.string("tts.skip_segment", fallback: "Skip this sentence")) { player.skipStoppedSegment() }
                        .accessibilityIdentifier("player.chinese-skip")
                    Spacer()
                }.font(.caption)
            }
            HStack {
                Text(L10n.string("tts.original_position", fallback: "Original timeline"))
                Spacer()
                Text(formatTime(scrub ?? player.originalTime) + " / " + formatTime(player.duration))
            }.font(.caption.monospacedDigit())
            Slider(value: Binding(get: { scrub ?? player.originalTime }, set: { scrub = $0 }),
                   in: 0...max(player.duration, 1), onEditingChanged: { editing in
                if !editing, let value = scrub { player.seek(to: value); scrub = nil }
            })
            .accessibilityIdentifier("player.chinese-progress")
            HStack(spacing: 12) {
                Button { player.seek(to: player.originalTime - 15) } label: { Image(systemName: "gobackward.15").frame(width: 44, height: 44)
                            .contentShape(Rectangle()) }
                Button { player.playPause() } label: {
                    Image(systemName: player.shouldResumeOriginal ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("player.chinese-play-pause")
                .accessibilityLabel(player.shouldResumeOriginal ? L10n.string("episode_detail.pause", fallback: "Pause") : L10n.string("episode_detail.play", fallback: "Play"))
                .accessibilityValue(player.isPreparing ? "preparing" : (player.isPlaying ? "playing" : "paused"))
                Button { player.seek(to: player.originalTime + 15) } label: { Image(systemName: "goforward.15").frame(width: 44, height: 44)
                            .contentShape(Rectangle()) }
                Button(action: onLocate) { Image(systemName: "scope").frame(width: 44, height: 44)
                            .contentShape(Rectangle()) }
                Spacer()
                Picker(L10n.string("episode_detail.speed", fallback: "speed"), selection: $player.playbackRate) {
                    Text(verbatim: "0.75x").tag(Float(0.75))
                    Text(verbatim: "1x").tag(Float(1))
                    Text(verbatim: "1.25x").tag(Float(1.25))
                }.pickerStyle(.menu)
            }
        }.padding(.horizontal, 16).padding(.bottom, 8).background(.ultraThinMaterial)
    }
}

private struct ReadingSegmentRow: View {
    let segment: LearningSegment
    let isActive: Bool
    let showChinese: Bool
    let showsSpeaker: Bool
    let subtitlePresentation: SubtitlePresentationPreferences
    let onPlay: () -> Void

    /// Dynamic Type scale applied after committed base point sizes.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var englishFontSize: CGFloat {
        CGFloat(subtitlePresentation.englishPointSize(on: .iOS)) * dynamicTypeScale
    }

    private var targetFontSize: CGFloat {
        CGFloat(subtitlePresentation.targetPointSize(on: .iOS)) * dynamicTypeScale
    }

    /// Non-empty translation when bilingual mode is on; otherwise nil (no empty row).
    private var visibleTranslation: String? {
        guard showChinese else { return nil }
        let trimmed = segment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : segment.translation
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 22)
                .opacity(isActive ? 1 : 0)

            Text(formatTime(segment.startMS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if showsSpeaker,
                   let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !speaker.isEmpty {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                orderedSubtitleLines
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? LinguaTheme.accent.opacity(0.16) : LinguaTheme.surface.opacity(0.42))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? LinguaTheme.accent.opacity(0.65) : Color.clear, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isActive ? LinguaTheme.accent : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .onTapGesture(perform: onPlay)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onPlay()
        }
        .accessibilityHint(formatTime(segment.startMS))
        .accessibilityValue(Text(verbatim: isActive ? "active" : "inactive"))
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
            // Highlight with the existing background, border and speaker marker.
            // Changing font weight can rewrap a row and move the lazy stack while scrolling.
            .font(.system(size: englishFontSize, weight: .regular))
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

private struct PlayerBar: View {
    @Bindable var player: AudioPlaybackController
    let showsLocateButton: Bool
    let onLocate: () -> Void
    let onPlaybackTimeChanged: (TimeInterval) -> Void
    let onDurationChanged: (TimeInterval) -> Void
    let onPlaybackStarted: () -> Void
    @State private var scrubbingState = PlaybackScrubbingState()
    @State private var isExpanded = false   // default: collapsed mini bar

    /// Fixed transport row height so lock/unlock safe-area recomputation cannot shift play/pause.
    private let transportRowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 6) {
            if let errorMessage = player.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(LinguaTheme.danger)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("player.error-message")
            }

            // Expanded-only section: time labels + locate + speed.
            if isExpanded {
                VStack(spacing: 6) {
                    HStack {
                        Text(formatTime(displayedPlaybackTime))
                        Spacer()
                        Text(formatTime(player.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                    HStack(spacing: 14) {
                        if showsLocateButton {
                            Button(action: onLocate) {
                                Image(systemName: "scope")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel(L10n.string("player.return_to_playback_position", fallback: "Return to Playback Position"))
                            .accessibilityIdentifier("player.locate-playback")
                        }

                        Spacer(minLength: 4)

                        Picker(L10n.string("episode_detail.speed", fallback: "speed"), selection: $player.playbackRate) {
                            Text(verbatim: "0.75x").tag(Float(0.75))
                            Text(verbatim: "1x").tag(Float(1.0))
                            Text(verbatim: "1.25x").tag(Float(1.25))
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Full-width slider in both states: `player.progress` never relocates during
            // toggle, and the scrub track stays wide enough for reliable progress adjust.
            Slider(
                value: playbackBinding,
                in: 0...max(player.duration, 1),
                onEditingChanged: handleScrubbing
            )
            .disabled(player.duration <= 0)
            .accessibilityIdentifier("player.progress")

            // Compact transport row — fixed geometry in both expand states and across
            // scene-phase safe-area changes so play/pause keeps the same on-screen slot.
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        player.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("player.back_15_seconds", fallback: "Back 15 Seconds"))
                    .accessibilityIdentifier("player.skip-back")

                    Button {
                        player.playPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(player.isPlaying ? L10n.string("episode_detail.pause", fallback: "Pause") : L10n.string("episode_detail.play", fallback: "Play"))
                    .accessibilityIdentifier("player.play-pause")

                    Button {
                        player.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("player.forward_15_seconds", fallback: "Forward 15 Seconds"))
                    .accessibilityIdentifier("player.skip-forward")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: transportRowHeight)
                .accessibilityLabel(
                    isExpanded
                        ? L10n.string("player.collapse_controls", fallback: "Collapse Playback Controls")
                        : L10n.string("player.expand_controls", fallback: "Expand Playback Controls")
                )
                .accessibilityIdentifier("player.toggle-controls")
            }
            .frame(height: transportRowHeight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.transport-row")
        }
        .padding(.horizontal, 16)
        .padding(.top, isExpanded ? 8 : 6)
        // Constant bottom padding (not tied to expand/collapse) keeps the transport row's
        // vertical slot stable when the bar height changes for other reasons.
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .background(LinguaTheme.backgroundRaised.opacity(0.94))
        .overlay(alignment: .top) {
            Divider()
        }
        .onChange(of: player.currentTime) { _, currentTime in
            onPlaybackTimeChanged(currentTime)
        }
        .onChange(of: player.duration) { _, duration in
            onDurationChanged(duration)
        }
        .onChange(of: player.isPlaying) { wasPlaying, isPlaying in
            // Cover the async seek-then-play path after unlock (isPlaying flips later).
            if isPlaying && !wasPlaying {
                onPlaybackStarted()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    private var playbackBinding: Binding<Double> {
        Binding(
            get: { displayedPlaybackTime },
            set: { scrubbingState.update(to: $0, duration: player.duration) }
        )
    }

    private var displayedPlaybackTime: TimeInterval {
        scrubbingState.displayedTime(
            playbackTime: min(player.currentTime, max(player.duration, 0))
        )
    }

    private func handleScrubbing(_ isEditing: Bool) {
        if isEditing {
            scrubbingState.begin(at: player.currentTime, duration: player.duration)
        } else if let target = scrubbingState.end() {
            player.seek(to: target)
        }
    }
}
#endif

private struct TranscriptRenderState: Equatable {
    let episodeID: String
    let segments: [LearningSegment]
    let activeSequence: Int?
    let followsPlayback: Bool
    let locateRequest: Int
    let showChinese: Bool
    let presentation: SubtitlePresentationPreferences
}

private struct StableTranscriptContent<Content: View>: View, Equatable {
    let state: TranscriptRenderState
    let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }

    var body: some View { content() }
}
