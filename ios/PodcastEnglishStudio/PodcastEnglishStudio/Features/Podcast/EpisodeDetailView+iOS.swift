import SwiftUI
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
        .keepScreenAwake(while: player.isPlaying)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if episode.status == "completed" {
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showChinese.toggle()
                } label: {
                    Text(
                        showChinese
                            ? L10n.string("subtitles.bilingual", fallback: "Bilingual")
                            : L10n.string("subtitles.english_only", fallback: "English Only")
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel(
                    showChinese
                        ? L10n.string("subtitles.hide_translation", fallback: "Hide Translation")
                        : L10n.string("subtitles.show_translation", fallback: "Show Translation")
                )
                .accessibilityIdentifier("transcript.translation-toggle")
            }
            if PodcastClearAndRegeneratePolicy.isAvailable(status: episode.status) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        clearAndRegenerateProcessing()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel(
                        L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate")
                    )
                    .accessibilityIdentifier("podcast.clear-and-regenerate")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
    }

    var readingView: some View {
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

                    ForEach(segments.indices, id: \.self) { index in
                        let segment = segments[index]
                        ReadingSegmentRow(
                            segment: segment,
                            isActive: player.activeSequence == segment.sequence,
                            showChinese: showChinese,
                            showsSpeaker: shouldShowSpeaker(at: index),
                            subtitlePresentation: settings.committedSubtitlePresentation,
                            onPlay: { player.play(segment: segment) }
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
                        updateTranscriptFollowing(after: .userDragBegan)
                    }
            )
            .onAppear {
                scrollToSequence(player.activeSequence, using: proxy)
                hasInitializedScroll = true
            }
            .onChange(of: player.activeSequence) { _, sequence in
                guard isFollowingPlayback else { return }
                scrollToSequence(sequence, using: proxy)
            }
            .onChange(of: locatePlaybackRequest) { _, _ in
                scrollToSequence(player.activeSequence, using: proxy)
            }
            .onChange(of: settings.committedSubtitlePresentation) { _, _ in
                // Presentation size/order can change row height; re-anchor only while follow is on.
                guard isFollowingPlayback else { return }
                scrollToSequence(player.activeSequence, using: proxy)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("subtitle.ready-state")
        }
    }

    func scrollToSequence(_ sequence: Int?, using proxy: ScrollViewProxy) {
        guard let sequence else { return }
        // LazyVStack may not have materialized the destination row yet — especially right
        // after scene reactivation. Yield so the next layout pass can build the cue before
        // scrollTo runs (otherwise the first post-unlock scroll is dropped).
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(sequence, anchor: activeTranscriptScrollAnchor)
        }
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
                .fill(isActive ? Color.accentColor : Color.clear)
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
            .font(.system(size: englishFontSize, weight: isActive ? .medium : .regular))
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
                                Image(systemName: "location.fill")
                                    .frame(width: 30, height: 30)
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
                            .frame(width: 30, height: 30)
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
                            .frame(width: 30, height: 30)
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
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 36, height: transportRowHeight)
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
