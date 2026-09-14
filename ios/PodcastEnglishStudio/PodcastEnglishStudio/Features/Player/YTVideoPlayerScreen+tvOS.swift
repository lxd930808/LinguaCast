#if os(tvOS)
import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

extension YTVideoPlayerScreen {
    func ytPlayerPlatformChrome<Content: View, Subtitle: View>(
        _ content: Content,
        subtitleOverlay: Subtitle
    ) -> some View {
        // Wrap in a container view so the chrome can hold @State/@FocusState for the
        // DPAD-toggled controls (extensions cannot declare stored state).
        TVPlayerChromeContainer(
            video: video,
            viewModel: viewModel,
            content: content,
            subtitleLoader: subtitleOverlay
        )
    }

    @ViewBuilder
    var platformPlayerOverlay: some View {
        // All tvOS chrome (title, control buttons, actions overlay) is rendered by
        // TVPlayerChromeContainer so it can own focus and visibility state.
        EmptyView()
    }

    var showsInlineSubtitleOverlay: Bool {
        false
    }
}

// Full-screen chrome for the tvOS player. The top navigation bar is hidden while this
// screen is on the stack and restored automatically on pop. The video title and the
// bottom control row (Subtitles / Quality / Playback speed) stay hidden during
// playback: DPAD-UP reveals them, DPAD-DOWN collapses them.
private struct TVPlayerChromeContainer<Content: View, Subtitle: View>: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings

    let video: YTVideoRecord
    let viewModel: YTVideoPlayerScreenViewModel
    let content: Content
    let subtitleLoader: Subtitle

    // Focus targets for the DPAD chrome.
    private enum FocusedControl: Hashable {
        case subtitles
        case quality
        case speed
        case actions
    }

    private enum ChromePicker: String, Identifiable {
        case subtitles
        case quality
        case speed

        var id: String { rawValue }
    }

    @State private var controlsVisible = false
    @State private var autoHideTask: Task<Void, Never>?
    @State private var activePicker: ChromePicker?
    @FocusState private var focusedControl: FocusedControl?

    /// Leave room above the system transport scrubber for circular chrome icons + focus captions.
    private let chromeBottomInset: CGFloat = 148
    private let autoHideDelayNanoseconds: UInt64 = 6_000_000_000
    private let chromeButtonSize: CGFloat = 68

    var body: some View {
        ZStack {
            content
            // tvOS renders subtitle text inside AVPlayerViewController. Keep this
            // hidden SwiftUI view alive because it owns subtitle loading/generation.
            subtitleLoader
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
            // Hide nav/tab chrome while playing; popping back restores both bars.
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .overlay {
                chromeOverlay
            }
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    showControls()
                case .down:
                    hideControls()
                default:
                    // Left/right while chrome is visible should keep immersion chrome alive.
                    if controlsVisible {
                        scheduleAutoHide()
                    }
                }
            }
            // Menu first collapses the DPAD chrome, then leaves the player. Without this
            // the press can reach the system and quit the app whenever the embedded
            // AVPlayerViewController is absent (resolving, or a stream error).
            .onExitCommand {
                if controlsVisible || activePicker != nil {
                    hideControls()
                } else {
                    dismiss()
                }
            }
            .onChange(of: focusedControl) { _, _ in
                if controlsVisible {
                    scheduleAutoHide()
                }
            }
            .onDisappear {
                autoHideTask?.cancel()
                autoHideTask = nil
            }
            .confirmationDialog(
                L10n.string("settings.subtitles", fallback: "Subtitles"),
                isPresented: pickerPresented(.subtitles),
                titleVisibility: .visible
            ) {
                ForEach(AppConfiguration.subtitleDisplayModeOptions.filter { $0 != "off" }, id: \.self) { mode in
                    Button(subtitleModeTitle(mode)) {
                        settings.configuration.subtitleDisplayMode = mode
                        settings.save()
                        scheduleAutoHide()
                    }
                }
            }
            .confirmationDialog(
                L10n.string("ytvideo_player.quality", fallback: "Quality"),
                isPresented: pickerPresented(.quality),
                titleVisibility: .visible
            ) {
                Button(L10n.string("ytvideo_player.quality_auto_default", fallback: "Auto (Default)")) {
                    settings.configuration.preferredVideoQuality = ""
                    settings.save()
                    scheduleAutoHide()
                }
                ForEach(viewModel.availableQualityTiers, id: \.storedRawValue) { option in
                    Button(option.menuTitle) {
                        settings.configuration.preferredVideoQuality = option.storedRawValue
                        settings.save()
                        scheduleAutoHide()
                    }
                }
            }
            .confirmationDialog(
                L10n.string("episode_detail.speed", fallback: "speed"),
                isPresented: pickerPresented(.speed),
                titleVisibility: .visible
            ) {
                ForEach(AppConfiguration.videoPlaybackRateOptions, id: \.self) { rate in
                    Button(Self.playbackRateTitle(for: rate)) {
                        settings.configuration.videoPlaybackRate = rate
                        settings.save()
                        scheduleAutoHide()
                    }
                }
            }
    }

    private func pickerPresented(_ picker: ChromePicker) -> Binding<Bool> {
        Binding(
            get: { activePicker == picker },
            set: { isPresented in
                activePicker = isPresented ? picker : nil
                if isPresented {
                    autoHideTask?.cancel()
                    autoHideTask = nil
                } else if controlsVisible {
                    scheduleAutoHide()
                }
            }
        )
    }

    @ViewBuilder
    private var chromeOverlay: some View {
        ZStack {
            if controlsVisible {
                LinearGradient(
                    colors: [.black.opacity(0.48), .clear, .black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Keep the title separate from the action panel so long titles never
                // squeeze the focusable controls.
                HStack(alignment: .center, spacing: 24) {
                    Text(video.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                    Spacer(minLength: 24)
                }
                .padding(.top, 48)
                .padding(.horizontal, 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(2)

                // YouTube-style circular glass controls above the scrubber (right cluster).
                HStack(alignment: .top, spacing: 18) {
                    subtitlesMenu
                    qualityMenu
                    speedMenu
                    actionsButton
                }
                .focusSection()
                .padding(.trailing, 72)
                .padding(.bottom, chromeBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(2)
            }

            if viewModel.showingPlayerActions {
                TVSubtitleActionsOverlay(
                    video: video,
                    message: viewModel.subtitleActionMessage,
                    canRetrySubtitles: viewModel.canRetrySubtitles,
                    isRetryingSubtitles: viewModel.isRetryingSubtitles,
                    onRetry: {
                        Task { await viewModel.retrySubtitles(settings: settings, context: modelContext) }
                    },
                    onRegenerate: {
                        viewModel.showingPlayerActions = false
                        viewModel.errorMessage = viewModel.paraformerUnavailableMessage
                    },
                    onDismiss: {
                        viewModel.showingPlayerActions = false
                    }
                )
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private func showControls() {
        if controlsVisible {
            scheduleAutoHide()
            return
        }
        controlsVisible = true
        // Defer until the buttons exist in the hierarchy so focus can land on them.
        DispatchQueue.main.async {
            focusedControl = .subtitles
        }
        scheduleAutoHide()
    }

    private func hideControls() {
        guard controlsVisible || activePicker != nil else { return }
        autoHideTask?.cancel()
        autoHideTask = nil
        activePicker = nil
        controlsVisible = false
        focusedControl = nil
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: autoHideDelayNanoseconds)
            guard !Task.isCancelled else { return }
            hideControls()
        }
    }

    private func chromeIconButton(
        title: String,
        systemImage: String,
        detail: String? = nil,
        focus: FocusedControl,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedControl == focus
        return Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: chromeButtonSize, height: chromeButtonSize)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                            .overlay {
                                Circle()
                                    .fill(Color.white.opacity(isFocused ? 0.38 : 0.12))
                            }
                            .overlay {
                                Circle()
                                    .stroke(
                                        Color.white.opacity(isFocused ? 0.95 : 0.2),
                                        lineWidth: isFocused ? 2.5 : 1
                                    )
                            }
                    }
                    .scaleEffect(isFocused ? 1.08 : 1)
                    .shadow(
                        color: isFocused ? Color.white.opacity(0.3) : .clear,
                        radius: 16,
                        y: 4
                    )

                // YouTube: caption appears only under the focused circle.
                Text(isFocused ? (detail ?? title) : " ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 118)
                    .opacity(isFocused ? 1 : 0)
            }
            .frame(width: 118)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: focus)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
    }

    private var actionsButton: some View {
        chromeIconButton(
            title: L10n.string("ytvideo_player.view_translation_progress", fallback: "View translation progress"),
            systemImage: viewModel.subtitleStatusIcon,
            detail: viewModel.subtitleStatusText,
            focus: .actions
        ) {
            hideControls()
            viewModel.showingPlayerActions = true
        }
    }

    // Circular glass buttons open confirmationDialog pickers (tvOS Menu tiles are unreliable).
    private var subtitlesMenu: some View {
        chromeIconButton(
            title: L10n.string("settings.subtitles", fallback: "Subtitles"),
            systemImage: "captions.bubble",
            detail: subtitleModeTitle(settings.configuration.subtitleDisplayMode),
            focus: .subtitles
        ) {
            activePicker = .subtitles
        }
    }

    private func subtitleModeTitle(_ mode: String) -> String {
        switch mode {
        case "englishOnly":
            return L10n.string("subtitles.english_only", fallback: "English Only")
        default:
            return L10n.string("subtitles.bilingual", fallback: "Bilingual")
        }
    }

    private var qualityMenu: some View {
        chromeIconButton(
            title: L10n.string("ytvideo_player.quality", fallback: "Quality"),
            systemImage: "slider.horizontal.3",
            detail: currentQualityTitle,
            focus: .quality
        ) {
            activePicker = .quality
        }
    }

    private var currentQualityTitle: String {
        if viewModel.video.actualPlaybackCodec == "hls" {
            if let height = viewModel.video.actualPlaybackHeight, height > 0 {
                return "\(height)p · HLS"
            }
            let rawValue = settings.configuration.preferredVideoQuality
            if rawValue.isEmpty {
                return L10n.string("ytvideo_player.quality_auto_hls", fallback: "Auto · HLS")
            }
            return L10n.string("ytvideo_player.quality_hls", fallback: "HLS")
        }
        if let height = viewModel.video.actualPlaybackHeight, height > 0 {
            let codec = viewModel.video.actualPlaybackCodec.map { " \($0)" } ?? ""
            return "\(height)p\(codec)"
        }
        let rawValue = settings.configuration.preferredVideoQuality
        guard !rawValue.isEmpty else {
            return L10n.string("ytvideo_player.quality_auto_default", fallback: "Auto (Default)")
        }
        return YTStreamSelectionPolicy.qualityTierOptions
            .first { $0.storedRawValue == rawValue }?
            .menuTitle ?? rawValue
    }

    private var speedMenu: some View {
        chromeIconButton(
            title: L10n.string("episode_detail.speed", fallback: "speed"),
            systemImage: "speedometer",
            detail: currentPlaybackRateTitle,
            focus: .speed
        ) {
            activePicker = .speed
        }
    }

    private var currentPlaybackRateTitle: String {
        Self.playbackRateTitle(for: settings.configuration.videoPlaybackRate)
    }

    private static func playbackRateTitle(for rate: Double) -> String {
        String(format: "%g×", rate)
    }
}

private struct TVSubtitleActionsOverlay: View {
    private enum FocusedControl: Hashable {
        case close
        case retry
        case regenerate
    }

    var video: YTVideoRecord
    var message: String
    var canRetrySubtitles: Bool
    var isRetryingSubtitles: Bool
    var onRetry: () -> Void
    var onRegenerate: () -> Void
    var onDismiss: () -> Void

    @FocusState private var focusedControl: FocusedControl?

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: iconName)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("ytvideo_player.subtitle_translation_progress", fallback: "Subtitle translation progress"))
                            .font(.title2.bold())
                        Text(statusText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(width: 50, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedControl, equals: .close)
                    .accessibilityLabel(L10n.string("common.close", fallback: "Close"))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let progress {
                        LinguaProgressBar(value: progressValue(for: progress))
                    }
                }

                HStack(spacing: 14) {
                    if canRetrySubtitles {
                        Button(action: onRetry) {
                            Label(
                                isRetryingSubtitles ? L10n.string("ytvideo_player.retrying", fallback: "Retrying") : L10n.string("ytvideo_player.retry_subtitle_translation", fallback: "Retry subtitle translation"),
                                systemImage: "arrow.clockwise"
                            )
                            .frame(width: 190, height: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .focused($focusedControl, equals: .retry)
                        .disabled(isRetryingSubtitles)
                    }

                    Button(action: onRegenerate) {
                        Label(L10n.string("ytvideo_player.view_retranslation_restrictions", fallback: "View retranslation restrictions"), systemImage: "waveform")
                            .frame(width: 250, height: 52)
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedControl, equals: .regenerate)

                    Spacer()
                }
            }
            .focusSection()
            .padding(30)
            .frame(width: 720)
            .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .environment(\.colorScheme, .dark)
            .onAppear {
                focusedControl = canRetrySubtitles ? .retry : .regenerate
            }
            .onChange(of: canRetrySubtitles) { _, value in
                if value {
                    focusedControl = .retry
                } else if focusedControl == .retry {
                    focusedControl = .regenerate
                }
            }
        }
    }

    private var progress: YTSubtitleTranslationProgress? {
        guard let totalCount = video.subtitleTotalCount, totalCount > 0 else { return nil }
        return YTSubtitleTranslationProgress(
            translatedCount: video.subtitleTranslatedCount ?? 0,
            totalCount: totalCount
        )
    }

    private func progressValue(for progress: YTSubtitleTranslationProgress) -> Double {
        guard progress.totalCount > 0 else { return 0 }
        return min(max(Double(progress.translatedCount) / Double(progress.totalCount), 0), 1)
    }

    private var statusText: String {
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

    private var iconName: String {
        if video.bilingualSubtitlesCompleted { return "checkmark.circle" }
        if video.enReady { return "text.quote" }
        if video.subtitleStatus == "failed" { return "exclamationmark.triangle" }
        if video.subtitleStatus == "running" || video.subtitleStatus == "translating" { return "clock" }
        return "captions.bubble"
    }

    private var iconColor: Color {
        video.subtitleStatus == "failed" ? LinguaTheme.danger : LinguaTheme.accent
    }
}
#endif
