#if os(tvOS)
import AVKit
import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

// tvOS platform hook: when native stream resolution fails, show an error view
// (tvOS has no WebKit iframe fallback).
extension YTPlayerView {
    @ViewBuilder
    func platformPlayerView(error: String?) -> some View {
        TVNativeStreamErrorView(error: error)
    }
}

/// The error state replaces `AVPlayerViewController`, so nothing in the hierarchy owns
/// focus or the remote's Menu press. Without a focusable control the press reaches the
/// system and quits the app instead of leaving the player, so this view keeps an
/// explicit Back button and handles the exit command itself.
private struct TVNativeStreamErrorView: View {
    @Environment(\.dismiss) private var dismiss

    let error: String?

    @FocusState private var isBackFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(L10n.string("ytplayer.the_current_video_cannot_be_parsed_and_played", fallback: "The current video cannot be parsed and played"))
                .font(.headline)
            Text(error ?? L10n.string(
                "ytplayer.the_current_video_cannot_be_parsed_and_played",
                fallback: "The current video cannot be parsed and played"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.string("ytplayer.go_back", fallback: "Back")) {
                dismiss()
            }
            .focused($isBackFocused)
            .padding(.top, 16)
        }
        .padding()
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onExitCommand { dismiss() }
        .onAppear {
            // Defer until the button exists in the hierarchy so focus can land on it.
            DispatchQueue.main.async {
                isBackFocused = true
            }
        }
    }
}

// tvOS platform hook: shared code (YTPlayerViewModel.swift, no #if) reads platform
// differences through this type.
enum YTPlayerPlatformSupport {
    /// tvOS never uses the iframe player and ignores the synced iOS playback-mode field.
    static func prefersOfficialIFramePlayer(committedConfiguration: AppConfiguration) -> Bool {
        false
    }
    static let streamSelectionPolicy: YTStreamSelectionPolicy = .highestQuality
    // A large television makes conservative adaptive startup quality especially
    // visible. Prefer the highest fixed stream and keep HLS as stall recovery.
    static let prefersFixedQualityOverAdaptiveHLS = true
    // tvOS 17–25: single synthesized-HLS AVPlayerItem so the system owns A/V sync.
    // tvOS 26+: dual AVPlayer — composed HLS hits a CoreMedia compatibility fault.
    static var prefersComposedHLSSinglePlayer: Bool {
        YTComposedPlaybackCompatibilityPolicy.prefersComposedHLSSinglePlayer(
            platform: .tvOS,
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }
    // Lift subtitles above the system transport scrubber and circular DPAD chrome icons.
    static let subtitleBottomOffset: CGFloat = -190
    static let subtitleOverlayInitiallyHidden = false

    static func normalizedSubtitleDisplayMode(_ mode: String) -> String {
        mode == "off" ? AppConfiguration.defaultSubtitleDisplayMode : mode
    }

    static func configurePlayerController(_ controller: AVPlayerViewController) {}

    static func autoplayIfNeeded(_ player: AVPlayer?) {
        player?.play()
    }
}
#endif
