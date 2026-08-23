#if os(iOS)
import SwiftData
import SwiftUI
import UIKit
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

extension YTVideoPlayerScreen {
    func ytPlayerPlatformChrome<Content: View, Subtitle: View>(
        _ content: Content,
        subtitleOverlay: Subtitle
    ) -> some View {
        YTPlayerChromeContainer(
            video: video,
            viewModel: viewModel,
            content: content,
            subtitleOverlay: subtitleOverlay
        )
    }

    var platformPlayerOverlay: some View {
        EmptyView()
    }

    var showsInlineSubtitleOverlay: Bool {
        true
    }
}

private enum YTPlayerLayoutMode {
    case tallCompact
    case tallRegular
    case wideShort
    case appFullscreen

    init(size: CGSize, isFullscreen: Bool) {
        if isFullscreen {
            self = .appFullscreen
        } else if size.height >= size.width {
            self = size.width < 700 ? .tallCompact : .tallRegular
        } else {
            self = .wideShort
        }
    }

    var isTall: Bool {
        self == .tallCompact || self == .tallRegular
    }
}

private struct YTPlayerChromeContainer<Content: View, Subtitle: View>: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings

    let video: YTVideoRecord
    let viewModel: YTVideoPlayerScreenViewModel
    let content: Content
    let subtitleOverlay: Subtitle

    @State private var showingSettings = false
    @State private var isAppFullscreen = false
    @State private var channelName: String?
    @State private var previousOrientation: UIInterfaceOrientation?
    @State private var fullscreenWindowScene: UIWindowScene?
    @State private var pendingOrientationRestore: UIInterfaceOrientationMask?
    @State private var usesSettingsSheet = true

    var body: some View {
        GeometryReader { proxy in
            let mode = YTPlayerLayoutMode(size: proxy.size, isFullscreen: isAppFullscreen)
            let usesReservedSubtitlePanel = usesReservedSubtitlePanel(mode: mode)
            let videoFrame = frameForVideo(
                mode: mode,
                size: proxy.size,
                reservesSubtitlePanel: usesReservedSubtitlePanel
            )

            ZStack(alignment: .top) {
                background(for: mode)

                if mode.isTall {
                    portraitContent(mode: mode, videoFrame: videoFrame)
                }

                content
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .clipShape(videoClipShape(for: mode))
                    .position(x: videoFrame.midX, y: videoFrame.midY)
                    .accessibilityIdentifier("player.surface")

                subtitlePlacement(
                    size: proxy.size,
                    videoFrame: videoFrame,
                    usesReservedPanel: usesReservedSubtitlePanel
                )

                playerControls(mode: mode, videoFrame: videoFrame, usesReservedPanel: usesReservedSubtitlePanel)

                if mode.isTall {
                    portraitControlDock
                        .padding(.horizontal, mode == .tallRegular ? 48 : 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .zIndex(3)
                }

                settingsOverlay(mode: mode)
                    .zIndex(4)
            }
            .onChange(of: proxy.size) { _, size in
                usesSettingsSheet = YTPlayerLayoutMode(
                    size: size,
                    isFullscreen: isAppFullscreen
                ).isTall
                if size.width < 32 || size.height < 32 {
                    exitFullscreen()
                }
            }
            .onAppear {
                usesSettingsSheet = mode.isTall
                guard UITestSupport.isEnabled else { return }
                let processInfo = ProcessInfo.processInfo
                if processInfo.environment["LINGUACAST_UI_START_FULLSCREEN"] == "1"
                    || processInfo.arguments.contains("-linguacast-ui-start-fullscreen") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        enterFullscreen()
                    }
                } else if processInfo.arguments.contains("-linguacast-ui-start-portrait") {
                    requestOrientations(.portrait, in: activeWindowScene)
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea(isAppFullscreen ? .all : [])
        .onReceive(NotificationCenter.default.publisher(for: .ytRequestAppFullscreen)) { _ in
            enterFullscreen()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                completePendingOrientationRestore()
            } else {
                exitFullscreen()
            }
        }
        .task(id: video.channelRecordID) {
            loadChannelName()
        }
        .onDisappear {
            exitFullscreen()
        }
        .sheet(isPresented: Binding(
            get: { showingSettings && !isAppFullscreen && usesSettingsSheet },
            set: { showingSettings = $0 }
        )) {
            settingsPanel
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .toolbar(isAppFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L10n.string("ytvideo_player.settings", fallback: "Settings"))
                .accessibilityIdentifier("player.settings.navigation")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .animation(.easeInOut(duration: 0.22), value: isAppFullscreen)
    }

    @ViewBuilder
    private func background(for mode: YTPlayerLayoutMode) -> some View {
        if mode.isTall {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        } else {
            Color.black
                .ignoresSafeArea()
        }
    }

    private func usesReservedSubtitlePanel(mode: YTPlayerLayoutMode) -> Bool {
        isUsingIFramePlayer
            && (mode == .wideShort || mode == .appFullscreen)
            && settings.committedConfiguration.subtitleDisplayMode != "off"
    }

    private var isUsingIFramePlayer: Bool {
        YTPlayerPlatformSupport.prefersOfficialIFramePlayer(
            committedConfiguration: settings.committedConfiguration
        )
    }

    private func frameForVideo(
        mode: YTPlayerLayoutMode,
        size: CGSize,
        reservesSubtitlePanel: Bool
    ) -> CGRect {
        switch mode {
        case .tallCompact:
            return CGRect(x: 0, y: 0, width: size.width, height: size.width * 9 / 16)
        case .tallRegular:
            let width = min(760, max(0, size.width - 64))
            return CGRect(x: (size.width - width) / 2, y: 24, width: width, height: width * 9 / 16)
        case .wideShort where reservesSubtitlePanel,
             .appFullscreen where reservesSubtitlePanel:
            return immersiveVideoFrame(in: size)
        case .wideShort, .appFullscreen:
            return CGRect(origin: .zero, size: size)
        }
    }

    private func immersiveVideoFrame(in size: CGSize) -> CGRect {
        let subtitleHeight = immersiveSubtitlePanelHeight(in: size)
        let availableHeight = max(0, size.height - subtitleHeight)
        let fittedWidth = min(size.width, availableHeight * 16 / 9)
        let fittedHeight = fittedWidth * 9 / 16
        return CGRect(
            x: (size.width - fittedWidth) / 2,
            y: (availableHeight - fittedHeight) / 2,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private func immersiveSubtitlePanelHeight(in size: CGSize) -> CGFloat {
        min(168, max(80, size.height * 0.22))
    }

    @ViewBuilder
    private func subtitlePlacement(
        size: CGSize,
        videoFrame: CGRect,
        usesReservedPanel: Bool
    ) -> some View {
        if usesReservedPanel {
            let panelHeight = immersiveSubtitlePanelHeight(in: size)
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                    .accessibilityElement()
                    .accessibilityLabel(
                        L10n.string("ytvideo_player.subtitles", fallback: "subtitles")
                    )
                    .accessibilityIdentifier("player.immersive-subtitle-panel")
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                subtitleOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: panelHeight)
            .position(
                x: size.width / 2,
                y: size.height - panelHeight / 2
            )
            .zIndex(2)
        } else {
            subtitleOverlay
                .frame(
                    width: videoFrame.width,
                    height: max(0, videoFrame.height - overlaidSubtitleBottomPadding),
                    alignment: .bottom
                )
                .position(
                    x: videoFrame.midX,
                    y: videoFrame.minY + max(0, videoFrame.height - overlaidSubtitleBottomPadding) / 2
                )
                .zIndex(2)
        }
    }

    private var overlaidSubtitleBottomPadding: CGFloat {
        66
    }

    @ViewBuilder
    private func playerControls(
        mode: YTPlayerLayoutMode,
        videoFrame: CGRect,
        usesReservedPanel: Bool
    ) -> some View {
        Group {
            if isUsingIFramePlayer, !UITestSupport.isEnabled {
                YTIFrameAppControlOverlay(
                    isFullscreen: mode == .appFullscreen,
                    // Landscape: drop the app's buttons below the iframe player's own
                    // top bar (title / CC / settings) so YouTube's controls stay tappable.
                    topClearance: mode.isTall ? 12 : 64,
                    onOpenSettings: { showingSettings = true },
                    onEnterFullscreen: enterFullscreen,
                    onExitFullscreen: exitFullscreen
                )
            } else {
                YTVideoControlOverlay(
                    currentTime: viewModel.currentTime,
                    duration: viewModel.duration,
                    controller: viewModel.playbackController,
                    configuredPlaybackRate: settings.configuration.videoPlaybackRate,
                    subtitleMode: settings.committedConfiguration.subtitleDisplayMode,
                    isFullscreen: mode == .appFullscreen,
                    settingsPresented: showingSettings,
                    hasInteractiveSubtitleCTA: !usesReservedPanel
                        && (viewModel.subtitleState.canGenerateFromAudio
                            || viewModel.subtitleState.cloudCheckRequired),
                    onOpenSettings: { showingSettings = true },
                    onEnterFullscreen: enterFullscreen,
                    onExitFullscreen: exitFullscreen
                )
            }
        }
        .frame(width: videoFrame.width, height: videoFrame.height)
        .clipShape(videoClipShape(for: mode))
        .position(x: videoFrame.midX, y: videoFrame.midY)
        .zIndex(3)
    }

    private func videoClipShape(for mode: YTPlayerLayoutMode) -> RoundedRectangle {
        RoundedRectangle(
            cornerRadius: mode == .tallRegular ? 16 : 0,
            style: .continuous
        )
    }

    private func portraitContent(mode: YTPlayerLayoutMode, videoFrame: CGRect) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Color.clear
                    .frame(height: videoFrame.maxY + 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .font(mode == .tallRegular ? .title2.weight(.bold) : .headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("player.video-title")

                    if let channelName, !channelName.isEmpty {
                        Text(channelName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                SubtitleStatusRow(video: video, subtitleState: viewModel.subtitleState)
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if viewModel.subtitleState.canGenerateFromAudio {
                    Button {
                        viewModel.subtitleState.requestGenerateFromAudio()
                    } label: {
                        Label(
                            L10n.string(
                                "ytvideo_player.generate_from_audio",
                                fallback: "Generate bilingual content from audio"
                            ),
                            systemImage: "waveform"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("player.generate-from-audio")
                }

                sentenceReadingCard
            }
            .frame(maxWidth: mode == .tallRegular ? 920 : .infinity, alignment: .leading)
            .padding(.horizontal, mode == .tallRegular ? 48 : 16)
            .padding(.bottom, 116)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var sentenceReadingCard: some View {
        let context = viewModel.playbackController.sentenceContext
        let subtitlesOff = settings.committedConfiguration.subtitleDisplayMode == "off"

        Group {
            if subtitlesOff {
                Label(
                    L10n.string("ytvideo_player.subtitles_disabled", fallback: "Subtitles are off"),
                    systemImage: "captions.bubble.slash"
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else {
                activeSentenceReadingCard(context: context)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func activeSentenceReadingCard(context: SentencePlaybackContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    L10n.string("ytvideo_player.current_sentence", fallback: "Current sentence"),
                    systemImage: "quote.bubble.fill"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                if context.current != nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(
                            L10n.string("ytvideo_player.following_playback", fallback: "Following playback"),
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .font(.caption2)
                        if let position = context.position {
                            Text("\(position) / \(context.totalCount)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let current = context.current {
                if let previous = context.previous {
                    sentenceLine(previous, opacity: 0.38)
                }
                sentenceLine(current, opacity: 1)
                    .padding(.vertical, 8)
                if let next = context.next {
                    sentenceLine(next, opacity: 0.38)
                }
            } else {
                Text(
                    YTSourceGenerationProgressText.title(
                        step: video.sourceGenerationStep,
                        progress: video.sourceGenerationProgress,
                        downloadProgress: viewModel.subtitleState.audioDownloadProgress,
                        bytesPerSecond: viewModel.subtitleState.audioDownloadBytesPerSecond
                    )
                    ?? L10n.string("common.subtitles_in_preparation", fallback: "Subtitles in preparation")
                )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                if video.sourceGenerationStep != nil {
                    if video.sourceGenerationStep == "downloading" {
                        if let progress = viewModel.subtitleState.audioDownloadProgress {
                            ProgressView(value: min(max(progress, 0), 1))
                        } else {
                            ProgressView()
                        }
                    } else {
                        ProgressView(value: min(max(video.sourceGenerationProgress ?? 0.05, 0), 1))
                    }
                }
            }

            Button {
                viewModel.playbackController.replayCurrentSentence()
            } label: {
                Label(
                    L10n.string("ytvideo_player.replay_current_sentence", fallback: "Replay current sentence"),
                    systemImage: "arrow.counterclockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(context.current == nil)
            .accessibilityIdentifier("player.sentence.replay")
        }
        .padding(18)
    }

    private func sentenceLine(_ segment: LearningSegment, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.text)
                .font(.system(
                    size: CGFloat(settings.committedSubtitlePresentation.englishPointSize()),
                    weight: opacity == 1 ? .semibold : .regular
                ))
                .fixedSize(horizontal: false, vertical: true)
            if settings.committedConfiguration.subtitleDisplayMode == "bilingual",
               !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(segment.translation)
                    .font(.system(
                        size: CGFloat(settings.committedSubtitlePresentation.targetPointSize()),
                        weight: .regular
                    ))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(opacity)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portraitControlDock: some View {
        YTSentenceControlDock(
            controller: viewModel.playbackController,
            playbackRate: settings.configuration.videoPlaybackRate,
            subtitlesEnabled: settings.committedConfiguration.subtitleDisplayMode != "off",
            onRateChange: { rate in
                settings.configuration.videoPlaybackRate = rate
                settings.save()
            }
        )
        .frame(maxWidth: 760)
    }

    @ViewBuilder
    private func settingsOverlay(mode: YTPlayerLayoutMode) -> some View {
        if showingSettings && isAppFullscreen {
            ZStack {
                Color.black.opacity(0.58)
                    .ignoresSafeArea()
                    .onTapGesture { showingSettings = false }
                settingsPanel
                    .frame(maxWidth: 520)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(32)
            }
            .transition(.opacity)
            .zIndex(2_000)
        } else if showingSettings && mode == .wideShort {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { showingSettings = false }
                settingsPanel
                    .frame(maxWidth: 520)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(32)
            }
            .transition(.opacity)
            .zIndex(2_000)
        }
    }

    private func enterFullscreen() {
        guard !isAppFullscreen else { return }
        showingSettings = false
        let scene = activeWindowScene
        fullscreenWindowScene = scene
        previousOrientation = scene?.interfaceOrientation
        isAppFullscreen = true
        requestOrientations(.landscape, in: scene)
    }

    private func exitFullscreen() {
        guard isAppFullscreen else { return }
        showingSettings = false
        isAppFullscreen = false
        let mask: UIInterfaceOrientationMask
        switch previousOrientation {
        case .landscapeLeft:
            mask = .landscapeLeft
        case .landscapeRight:
            mask = .landscapeRight
        case .portraitUpsideDown:
            mask = .portraitUpsideDown
        default:
            mask = .portrait
        }
        let scene = fullscreenWindowScene ?? activeWindowScene
        if scene?.activationState == .foregroundActive {
            requestOrientations(mask, in: scene)
            clearOrientationRestoreState()
        } else {
            pendingOrientationRestore = mask
        }
    }

    private func completePendingOrientationRestore() {
        guard let mask = pendingOrientationRestore else { return }
        requestOrientations(mask, in: fullscreenWindowScene ?? activeWindowScene)
        clearOrientationRestoreState()
    }

    private func clearOrientationRestoreState() {
        pendingOrientationRestore = nil
        previousOrientation = nil
        fullscreenWindowScene = nil
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private func requestOrientations(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene?) {
        guard let scene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            print("YT player orientation request was not applied: \(error.localizedDescription)")
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func loadChannelName() {
        let recordID = video.channelRecordID
        var descriptor = FetchDescriptor<YTChannelRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        channelName = try? modelContext.fetch(descriptor).first?.displayName
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.string("ytvideo_player.settings", fallback: "Settings"))
                    .font(.headline)
                Spacer()
                Button {
                    showingSettings = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(L10n.string("common.close", fallback: "Close"))
            }

            if !isUsingIFramePlayer {
                LabeledContent(L10n.string("ytvideo_player.quality", fallback: "Quality")) {
                    qualityMenu
                }
            }

            LabeledContent(L10n.string("ytvideo_player.playback_speed", fallback: "Playback speed")) {
                playbackRateMenu
            }

            LabeledContent(L10n.string("ytvideo_player.subtitles", fallback: "subtitles")) {
                subtitleModeMenu
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("ytvideo_player.subtitle_translation", fallback: "Subtitle translation"))
                    .font(.subheadline.weight(.semibold))
                SubtitleStatusRow(video: video, subtitleState: viewModel.subtitleState)
                if viewModel.canRetrySubtitles {
                    Button {
                        Task { await viewModel.retrySubtitles(settings: settings, context: modelContext) }
                    } label: {
                        Label(
                            viewModel.isRetryingSubtitles
                                ? L10n.string("ytvideo_player.retrying", fallback: "Retrying")
                                : L10n.string("ytvideo_player.retry_subtitle_translation", fallback: "Retry subtitle translation"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(viewModel.isRetryingSubtitles)
                }
                if viewModel.subtitleState.canGenerateFromAudio {
                    Button {
                        showingSettings = false
                        viewModel.subtitleState.requestGenerateFromAudio()
                    } label: {
                        Label(
                            L10n.string(
                                "ytvideo_player.generate_from_audio",
                                fallback: "Generate bilingual content from audio"
                            ),
                            systemImage: "waveform"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
    }

    private var qualityMenu: some View {
        Menu {
            qualityRow(title: L10n.string("ytvideo_player.quality_auto_default", fallback: "Auto (Default)"), rawValue: "")
            ForEach(viewModel.availableQualityTiers, id: \.storedRawValue) { option in
                qualityRow(title: option.menuTitle, rawValue: option.storedRawValue)
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentQualityTitle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func qualityRow(title: String, rawValue: String) -> some View {
        Button {
            settings.configuration.preferredVideoQuality = rawValue
            settings.save()
        } label: {
            if settings.configuration.preferredVideoQuality == rawValue {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var currentQualityTitle: String {
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

    private var playbackRateMenu: some View {
        Menu {
            ForEach(AppConfiguration.videoPlaybackRateOptions, id: \.self) { rate in
                Button {
                    settings.configuration.videoPlaybackRate = rate
                    settings.save()
                } label: {
                    if settings.configuration.videoPlaybackRate == rate {
                        Label(playbackRateTitle(rate), systemImage: "checkmark")
                    } else {
                        Text(playbackRateTitle(rate))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(playbackRateTitle(settings.configuration.videoPlaybackRate))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func playbackRateTitle(_ rate: Double) -> String {
        rate == 1
            ? L10n.string("ytvideo_player.playback_speed_normal", fallback: "Normal")
            : String(format: "%gx", rate)
    }

    private var subtitleModeMenu: some View {
        Menu {
            ForEach(AppConfiguration.subtitleDisplayModeOptions, id: \.self) { mode in
                Button {
                    settings.configuration.subtitleDisplayMode = mode
                    settings.save()
                    if mode == "off" {
                        viewModel.playbackController.disableSentenceRepeat()
                    }
                } label: {
                    if settings.configuration.subtitleDisplayMode == mode {
                        Label(subtitleModeTitle(mode), systemImage: "checkmark")
                    } else {
                        Text(subtitleModeTitle(mode))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(subtitleModeTitle(settings.configuration.subtitleDisplayMode))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func subtitleModeTitle(_ mode: String) -> String {
        switch mode {
        case "englishOnly":
            L10n.string("ytvideo_player.subtitles_english_only", fallback: "English only")
        case "off":
            L10n.string("ytvideo_player.subtitles_off", fallback: "Off")
        default:
            L10n.string("ytvideo_player.subtitles_bilingual", fallback: "Bilingual")
        }
    }
}

private struct YTSentenceControlDock: View {
    let controller: YTVideoPlaybackController
    let playbackRate: Double
    let subtitlesEnabled: Bool
    let onRateChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(AppConfiguration.videoPlaybackRateOptions, id: \.self) { rate in
                    Button(String(format: "%gx", rate)) {
                        onRateChange(rate)
                    }
                }
            } label: {
                Text(String(format: "%gx", playbackRate))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.string("ytvideo_player.playback_speed", fallback: "Playback speed"))

            dockButton(
                systemName: "backward.end.fill",
                label: L10n.string("ytvideo_player.previous_sentence", fallback: "Previous sentence"),
                identifier: "player.sentence.previous",
                disabled: !subtitlesEnabled || controller.sentenceContext.previous == nil,
                action: controller.moveToPreviousSentence
            )

            Button(action: controller.togglePlayback) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.white)
                    .background(LinguaTheme.accent, in: Circle())
            }
            .accessibilityLabel(
                controller.isPlaying
                    ? L10n.string("episode_detail.pause", fallback: "Pause")
                    : L10n.string("episode_detail.play", fallback: "Play")
            )
            .accessibilityIdentifier("player.play-pause")

            dockButton(
                systemName: "forward.end.fill",
                label: L10n.string("ytvideo_player.next_sentence", fallback: "Next sentence"),
                identifier: "player.sentence.next",
                disabled: !subtitlesEnabled || controller.sentenceContext.next == nil,
                action: controller.moveToNextSentence
            )

            dockButton(
                systemName: controller.isRepeatingSentence ? "repeat.1.circle.fill" : "repeat.1",
                label: L10n.string("ytvideo_player.single_sentence_repeat", fallback: "Repeat sentence"),
                identifier: "player.sentence.repeat",
                disabled: !subtitlesEnabled || controller.sentenceContext.current == nil,
                selected: controller.isRepeatingSentence,
                action: controller.toggleSentenceRepeat
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
    }

    private func dockButton(
        systemName: String,
        label: String,
        identifier: String,
        disabled: Bool,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(selected ? LinguaTheme.accent : Color.primary)
        }
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct YTIFrameAppControlOverlay: View {
    let isFullscreen: Bool
    /// Top inset for the button row. Landscape passes enough clearance to keep the
    /// app's buttons below the iframe's native top bar so they never overlap.
    let topClearance: CGFloat
    let onOpenSettings: () -> Void
    let onEnterFullscreen: () -> Void
    let onExitFullscreen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isFullscreen {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .accessibilityLabel(L10n.string("ytvideo_player.settings", fallback: "Settings"))
                .accessibilityIdentifier("player.settings.fullscreen")

                Button(action: onExitFullscreen) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .accessibilityLabel(L10n.string("ytvideo_player.exit_fullscreen", fallback: "Exit Full Screen"))
                .accessibilityIdentifier("player.fullscreen.exit")
            } else {
                Button(action: onEnterFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .accessibilityLabel(L10n.string("ytvideo_player.enter_fullscreen", fallback: "Enter Full Screen"))
                .accessibilityIdentifier("player.fullscreen.enter")
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, topClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

private struct YTVideoControlOverlay: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let controller: YTVideoPlaybackController
    let configuredPlaybackRate: Double
    let subtitleMode: String
    let isFullscreen: Bool
    let settingsPresented: Bool
    /// When true, keep the center clear so DualSubtitleOverlay CTAs (audio ASR / cloud bypass) remain tappable.
    var hasInteractiveSubtitleCTA = false
    let onOpenSettings: () -> Void
    let onEnterFullscreen: () -> Void
    let onExitFullscreen: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var controlsVisible = true
    @State private var scrubbingState = PlaybackScrubbingState()
    @State private var autoHideTask: Task<Void, Never>?

    private var displayedTime: TimeInterval {
        scrubbingState.displayedTime(playbackTime: currentTime)
    }

    var body: some View {
        ZStack {
            if hasInteractiveSubtitleCTA {
                // Only chrome strips capture taps; the center passes through to subtitle CTAs below.
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: isFullscreen ? 72 : 56)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleControls() }
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(height: isFullscreen ? 120 : 88)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleControls() }
                }
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
            }

            if controlsVisible {
                LinearGradient(
                    colors: [.black.opacity(0.58), .clear, .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                topControls

                if !hasInteractiveSubtitleCTA {
                    Button(action: controller.togglePlayback) {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: isFullscreen ? 34 : 26, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: isFullscreen ? 72 : 58, height: isFullscreen ? 72 : 58)
                            .background(.black.opacity(0.48), in: Circle())
                    }
                    .accessibilityLabel(
                        controller.isPlaying
                            ? L10n.string("episode_detail.pause", fallback: "Pause")
                            : L10n.string("episode_detail.play", fallback: "Play")
                    )
                    .accessibilityIdentifier("player.overlay.play-pause")
                }

                bottomControls
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        .onAppear { scheduleAutoHide() }
        .onChange(of: controller.isPlaying) { _, _ in scheduleAutoHide() }
        .onChange(of: settingsPresented) { _, _ in scheduleAutoHide() }
        .onChange(of: voiceOverEnabled) { _, _ in scheduleAutoHide() }
        .onChange(of: hasInteractiveSubtitleCTA) { _, active in
            if active {
                controlsVisible = true
                autoHideTask?.cancel()
            } else {
                scheduleAutoHide()
            }
        }
        .onDisappear { autoHideTask?.cancel() }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            if isFullscreen {
                Text(topStatusText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.48), in: Capsule())
            }
            Spacer()
            if isFullscreen {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(L10n.string("ytvideo_player.settings", fallback: "Settings"))
                .accessibilityIdentifier("player.settings.fullscreen")

                Button(action: onExitFullscreen) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(L10n.string("ytvideo_player.exit_fullscreen", fallback: "Exit Full Screen"))
                .accessibilityIdentifier("player.fullscreen.exit")
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(formatTime(displayedTime))
                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { value in
                            if scrubbingState.draftTime == nil {
                                scrubbingState.begin(at: currentTime, duration: duration)
                            }
                            scrubbingState.update(to: value, duration: duration)
                        }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            controlsVisible = true
                            autoHideTask?.cancel()
                        } else if let target = scrubbingState.end() {
                            controller.seek(to: target, resumeAfterSeek: controller.isPlaying)
                            scheduleAutoHide()
                        }
                    }
                )
                .environment(\.layoutDirection, .leftToRight)
                .tint(.white)
                .accessibilityIdentifier("player.timeline")
                Text(formatTime(duration))
            }
            .environment(\.layoutDirection, .leftToRight)
            .font(.caption.monospacedDigit())

            if isFullscreen {
                HStack(spacing: 20) {
                    sentenceButton(
                        systemName: "backward.end.fill",
                        label: L10n.string("ytvideo_player.previous_sentence", fallback: "Previous sentence"),
                        disabled: subtitleMode == "off" || controller.sentenceContext.previous == nil,
                        action: controller.moveToPreviousSentence
                    )
                    sentenceButton(
                        systemName: "arrow.counterclockwise",
                        label: L10n.string("ytvideo_player.replay_current_sentence", fallback: "Replay current sentence"),
                        disabled: subtitleMode == "off" || controller.sentenceContext.current == nil,
                        action: controller.replayCurrentSentence
                    )
                    sentenceButton(
                        systemName: "forward.end.fill",
                        label: L10n.string("ytvideo_player.next_sentence", fallback: "Next sentence"),
                        disabled: subtitleMode == "off" || controller.sentenceContext.next == nil,
                        action: controller.moveToNextSentence
                    )
                    sentenceButton(
                        systemName: controller.isRepeatingSentence ? "repeat.1.circle.fill" : "repeat.1",
                        label: L10n.string("ytvideo_player.single_sentence_repeat", fallback: "Repeat sentence"),
                        disabled: subtitleMode == "off" || controller.sentenceContext.current == nil,
                        action: controller.toggleSentenceRepeat
                    )
                }
            } else {
                HStack {
                    Spacer()
                    Button(action: onEnterFullscreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("ytvideo_player.enter_fullscreen", fallback: "Enter Full Screen"))
                    .accessibilityIdentifier("player.fullscreen.enter")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func sentenceButton(
        systemName: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 44, height: 44)
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var subtitleModeTitle: String {
        switch subtitleMode {
        case "englishOnly":
            L10n.string("ytvideo_player.subtitles_english_only", fallback: "English only")
        case "off":
            L10n.string("ytvideo_player.subtitles_off", fallback: "Off")
        default:
            L10n.string("ytvideo_player.subtitles_bilingual", fallback: "Bilingual")
        }
    }

    private var displayedPlaybackRate: Double {
        controller.isPlaying ? controller.effectivePlaybackRate : configuredPlaybackRate
    }

    private var topStatusText: String {
        "\(String(format: "%gx", displayedPlaybackRate)) · \(subtitleModeTitle)"
    }

    private func toggleControls() {
        controlsVisible.toggle()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard controller.isPlaying,
              !settingsPresented,
              !voiceOverEnabled,
              scrubbingState.draftTime == nil,
              controlsVisible
        else {
            if !controller.isPlaying || settingsPresented || voiceOverEnabled {
                controlsVisible = true
            }
            return
        }
        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                controlsVisible = false
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let seconds = Int(time.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
