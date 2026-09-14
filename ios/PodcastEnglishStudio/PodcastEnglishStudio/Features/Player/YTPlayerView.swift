import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

// 薄入口：状态装载在 YTPlayerViewModel，解析失败时的回退界面按平台分发
// （见 YTPlayerView+iOS.swift 的 iframe 回退与 YTPlayerView+tvOS.swift 的错误提示）。
struct YTPlayerView: View {
    @Environment(SettingsStore.self) var settings
    var videoID: String
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval
    var initialTime: TimeInterval?
    /// Known video length from metadata; feeds the composed-HLS playlist builder.
    var durationHint: TimeInterval? = nil
    var subtitleState: YTSubtitleDisplayState
    var playbackController: YTVideoPlaybackController
    var onPlaybackEnded: () -> Void = {}
    var onPlaybackMetricsChange: ((Int?, String?) -> Void)? = nil
    var onAvailableQualitiesChange: (([YTStreamSelectionPolicy]) -> Void)? = nil

    /// Shared with platform extensions (e.g. iOS local-service failure UI).
    @State var model = YTPlayerViewModel()
    /// Bumped when Debug local-service falls back to the official iframe so the view rebuilds.
    @State var playbackBackendEpoch = 0
    /// Explicit iframe fallback is scoped to this player presentation. Leaving
    /// and reopening the video must try the configured local service again.
    @State var forceOfficialIFrameForCurrentPlayer = false

    // The user's quality choice; nil means "use the platform default policy". Reads the
    // raw settings string so an unset/unknown value falls back to the platform behavior.
    private var preferredQuality: YTStreamSelectionPolicy? {
        YTStreamSelectionPolicy(storedRawValue: settings.configuration.preferredVideoQuality)
    }

    private var isAutoQuality: Bool {
        let raw = settings.configuration.preferredVideoQuality
        return raw.isEmpty || preferredQuality == .highestQuality || preferredQuality == nil
    }

    /// Effective playback mode resolved from the committed configuration — the single
    /// interface shared by the player, the iOS playback layout and subtitle loading.
    private var effectivePlaybackMode: IOSYouTubePlaybackMode {
        IOSYouTubePlaybackMode.effective(configured: settings.committedConfiguration.youTubePlaybackMode)
    }

    private var usesOfficialIFramePlayer: Bool {
        _ = playbackBackendEpoch
        return forceOfficialIFrameForCurrentPlayer ||
            YTPlayerPlatformSupport.prefersOfficialIFramePlayer(
                committedConfiguration: settings.committedConfiguration
            )
    }

    var body: some View {
        ZStack {
            if usesOfficialIFramePlayer {
                // Official iframe path (default, or after Debug local-service fallback).
                platformPlayerView(error: nil)
                    .id("iframe:\(videoID):\(playbackBackendEpoch)")
            } else if let playerItem = model.playerItem {
                YTNativePlayerView(
                    playerItem: playerItem,
                    auxiliaryAudioItem: model.auxiliaryAudioItem,
                    playbackItemToken: model.playbackItemToken,
                    playbackRecoveryTime: model.playbackRecoveryTime,
                    playbackRecoveryShouldResume: model.playbackRecoveryShouldResume,
                    currentTime: $currentTime,
                    duration: $duration,
                    initialTime: restoredPlaybackTime,
                    subtitleState: subtitleState,
                    subtitlePreferences: settings.committedSubtitlePresentation,
                    playbackRate: settings.configuration.videoPlaybackRate,
                    subtitleDisplayMode: YTPlayerPlatformSupport.normalizedSubtitleDisplayMode(
                        settings.committedConfiguration.subtitleDisplayMode
                    ),
                    playbackCommand: playbackController.command,
                    repeatRange: playbackController.repeatRange,
                    shouldResumeAfterInitialSeek: playbackController.isPlaying,
                    isAutoQuality: isAutoQuality,
                    onPlaybackStateChange: playbackController.report(isPlaying:),
                    onEffectiveRateChange: playbackController.report(effectivePlaybackRate:),
                    onPlaybackEnded: onPlaybackEnded,
                    onPlaybackFailed: { [expectedToken = model.playbackItemToken] status, time, wasPlaying in
                        Task {
                            await model.handlePlaybackFailure(
                                statusCode: status,
                                restoreTime: time,
                                wasPlaying: wasPlaying,
                                quality: preferredQuality,
                                expectedPlaybackItemToken: expectedToken
                            )
                        }
                    },
                    onAutoQualityStall: { [expectedToken = model.playbackItemToken] height, time, wasPlaying in
                        Task {
                            await model.handleAutoQualityStall(
                                currentHeight: height ?? model.actualPlaybackHeight,
                                quality: preferredQuality,
                                restoreTime: time,
                                wasPlaying: wasPlaying,
                                expectedPlaybackItemToken: expectedToken
                            )
                        }
                    },
                    onPresentationSizeChange: { size in
                        let height = Int(size.height.rounded())
                        if height > 0 {
                            model.actualPlaybackHeight = height
                            onPlaybackMetricsChange?(height, model.actualPlaybackCodec)
                        }
                    }
                )
            } else if let nativeStreamError = model.nativeStreamError {
                platformPlayerView(error: nativeStreamError)
            } else {
                Color.black
                ProgressView()
                    .tint(.white)
            }

            if let notice = model.qualityDegradedNotice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(.bottom, 36)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        // Re-resolve the stream whenever the video, preferred quality or effective
        // playback mode changes.
        .task(id: "\(videoID):\(settings.configuration.preferredVideoQuality):\(effectivePlaybackMode.rawValue):\(playbackBackendEpoch)") {
            guard !usesOfficialIFramePlayer else {
                onAvailableQualitiesChange?([])
                return
            }
            model.cloudConfiguration = settings.committedConfiguration
            model.resetAutoDowngrade()
            await model.load(
                videoID: videoID,
                initialTime: restoredPlaybackTime,
                currentTime: $currentTime,
                duration: $duration,
                quality: preferredQuality,
                wasPlaying: playbackController.isPlaying,
                durationHint: durationHint
            )
            onPlaybackMetricsChange?(model.actualPlaybackHeight, model.actualPlaybackCodec)
            onAvailableQualitiesChange?(model.availableQualityTiers)
        }
        .task(id: model.qualityDegradedNotice) {
            guard model.qualityDegradedNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            model.qualityDegradedNotice = nil
        }
        .task(id: YTPlaybackNetworkMonitor.shared.kind) {
            guard !usesOfficialIFramePlayer else { return }
            await model.handleNetworkChangeIfNeeded(
                quality: preferredQuality,
                wasPlaying: playbackController.isPlaying
            )
            onPlaybackMetricsChange?(model.actualPlaybackHeight, model.actualPlaybackCodec)
        }
        .onChange(of: model.actualPlaybackHeight) { _, height in
            onPlaybackMetricsChange?(height, model.actualPlaybackCodec)
        }
        .onChange(of: model.availableQualityTiers.map(\.storedRawValue).joined(separator: ",")) { _, _ in
            onAvailableQualitiesChange?(model.availableQualityTiers)
        }
    }

    var restoredPlaybackTime: TimeInterval? {
        currentTime > 0 ? currentTime : initialTime
    }
}
