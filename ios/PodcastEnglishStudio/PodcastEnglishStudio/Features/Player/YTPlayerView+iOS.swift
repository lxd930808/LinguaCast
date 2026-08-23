#if os(iOS)
import AVKit
import SwiftUI
import WebKit
import PodcastEnglishStudioCore
import CloudSyncKit

// Notification posted when the native AVPlayer expand control is tapped so chrome
// can enter the shared app-owned fullscreen layout instead of system fullscreen.
extension Notification.Name {
    static let ytRequestAppFullscreen = Notification.Name("YTRequestAppFullscreen")
}

// iOS playback path: use YouTube's official iframe player by default.
extension YTPlayerView {
    @ViewBuilder
    func platformPlayerView(error: String?) -> some View {
        if let error, YTPlaybackBackend.kind() == .localService {
            localServiceFailureView(error: error)
        } else {
            officialIFramePlayerView
        }
    }

    @ViewBuilder
    private var officialIFramePlayerView: some View {
        YTIFramePlayerView(
            videoID: videoID,
            currentTime: $currentTime,
            duration: $duration,
            initialTime: restoredPlaybackTime,
            playbackRate: settings.configuration.videoPlaybackRate,
            playbackCommand: playbackController.command,
            repeatRange: playbackController.repeatRange,
            shouldResumeAfterInitialSeek: playbackController.isPlaying,
            onPlaybackStateChange: playbackController.report(isPlaying:),
            onEffectiveRateChange: playbackController.report(effectivePlaybackRate:),
            onPlaybackEnded: onPlaybackEnded
        )
    }

    @ViewBuilder
    private func localServiceFailureView(error: String) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                Text(L10n.string(
                    "ytplayer.the_current_video_cannot_be_parsed_and_played",
                    fallback: "The current video cannot be parsed and played"
                ))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button(L10n.string(
                    "ytvideo_player.retry_local_service",
                    fallback: "Retry Local Playback"
                )) {
                    model.nativeStreamError = nil
                    playbackBackendEpoch += 1
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.string("ytvideo_player.open_in_youtube", fallback: "Open in YouTube")) {
                    forceOfficialIFrameForCurrentPlayer = true
                    model.nativeStreamError = nil
                    playbackBackendEpoch += 1
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}

// iOS platform hooks read by shared code (YTPlayerViewModel.swift, no #if).
enum YTPlayerPlatformSupport {
    /// Default remains the official iframe player. Debug can opt into AVPlayer via
    /// `YT_PLAYBACK_BACKEND=local-service` (Mac SABR service) or `youtubekit`.
    /// The committed (saved) configuration feeds the effective playback mode so
    /// unsaved Settings drafts never switch the player.
    static func prefersOfficialIFramePlayer(committedConfiguration: AppConfiguration) -> Bool {
        switch YTPlaybackBackend.kind() {
        case .youTubeKit, .localService:
            return false
        case .officialIFrame:
            return IOSYouTubePlaybackMode.effective(
                configured: committedConfiguration.youTubePlaybackMode
            ) == .officialIFrame
        }
    }
    static let streamSelectionPolicy: YTStreamSelectionPolicy = .highestQuality
    static let prefersFixedQualityOverAdaptiveHLS = false
    // iOS keeps the proven dual-AVPlayer composed playback for now; the
    // synthesized single-item HLS path ships on tvOS first.
    static let prefersComposedHLSSinglePlayer = false
    static let subtitleBottomOffset: CGFloat = -28
    // Inline DualSubtitleOverlay stays visible; system fullscreen is redirected to
    // app-owned layout, so the content-overlay host starts and stays hidden.
    static let subtitleOverlayInitiallyHidden = true

    static func normalizedSubtitleDisplayMode(_ mode: String) -> String {
        mode
    }

    static func configurePlayerController(_ controller: AVPlayerViewController) {
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = false
        // Prefer app-owned reversible fullscreen over AVPlayerViewController system
        // fullscreen so native and iframe share one chrome state.
        controller.entersFullScreenWhenPlaybackBegins = false
    }

    static func autoplayIfNeeded(_ player: AVPlayer?) {}
}

// Redirect AVPlayerViewController system fullscreen into the shared app-owned layout.
extension YTNativePlayerView.Coordinator {
    @objc func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        NotificationCenter.default.post(name: .ytRequestAppFullscreen, object: nil)
        // Dismiss the system presentation as soon as it finishes presenting so the
        // player remains in the chrome container (layout-only fullscreen).
        coordinator.animate(alongsideTransition: nil) { _ in
            playerViewController.dismiss(animated: false)
        }
    }

    @objc func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.overlayHost?.view.isHidden = true
        }
    }
}

struct YTIFramePlayerView: UIViewRepresentable {
    var videoID: String
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval
    var initialTime: TimeInterval?
    var playbackRate: Double
    var playbackCommand: YTPlaybackCommand?
    var repeatRange: ClosedRange<TimeInterval>?
    var shouldResumeAfterInitialSeek: Bool
    var onPlaybackStateChange: (Bool) -> Void
    var onEffectiveRateChange: (Double) -> Void
    var onPlaybackEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            currentTime: $currentTime,
            duration: $duration,
            initialTime: initialTime,
            playbackRate: playbackRate,
            playbackCommand: playbackCommand,
            repeatRange: repeatRange,
            shouldResumeAfterInitialSeek: shouldResumeAfterInitialSeek,
            onPlaybackStateChange: onPlaybackStateChange,
            onEffectiveRateChange: onEffectiveRateChange,
            onPlaybackEnded: onPlaybackEnded
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = YTWebSession.shared.dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = webpagePreferences
        configuration.userContentController.add(context.coordinator, name: "youtubePlayer")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        context.coordinator.webView = webView
        context.coordinator.videoID = videoID
        Self.load(videoID: videoID, in: webView)
        context.coordinator.startPolling()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.initialTime = initialTime
        context.coordinator.playbackRate = playbackRate
        context.coordinator.shouldResumeAfterInitialSeek = shouldResumeAfterInitialSeek
        context.coordinator.onPlaybackStateChange = onPlaybackStateChange
        context.coordinator.onEffectiveRateChange = onEffectiveRateChange
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        context.coordinator.applyPlaybackRate()
        context.coordinator.updateRepeatRange(repeatRange)
        context.coordinator.consume(playbackCommand)
        if context.coordinator.videoID != videoID {
            context.coordinator.videoID = videoID
            context.coordinator.prepareForReload()
            context.coordinator.resetInitialSeek()
            Self.load(videoID: videoID, in: webView)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "youtubePlayer")
    }

    // YouTube requires the embedding page to identify itself through a real HTTPS
    // page origin/referrer. Using youtube.com here makes the locally generated page
    // look like a same-origin YouTube page embedding itself and is rejected with
    // player error 152 on current iOS WebKit.
    private static let embedPageURL = URL(string: "https://linguacast.example/")!
    private static let encodedEmbedOrigin = "https%3A%2F%2Flinguacast.example"
    private static let encodedWidgetReferrer = "https%3A%2F%2Flinguacast.example%2F"

    private static func load(videoID: String, in webView: WKWebView) {
        assert(embedPageURL.host?.hasSuffix("youtube.com") == false)
        print("YTIFramePlayerView: loading videoID=\(videoID) embedOrigin=\(embedPageURL.absoluteString)")
        webView.loadHTMLString(html(videoID: videoID), baseURL: embedPageURL)
    }

    private static func html(videoID: String) -> String {
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="strict-origin-when-cross-origin">
          <style>
            html, body, #player { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
            iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; background: #000; }
          </style>
        </head>
        <body>
          <iframe
            id="player"
            src="https://www.youtube.com/embed/\(videoID)?enablejsapi=1&origin=\(encodedEmbedOrigin)&widget_referrer=\(encodedWidgetReferrer)&playsinline=1&fs=0&rel=0&modestbranding=1&controls=1&cc_load_policy=0&iv_load_policy=3"
            title="YouTube video player"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            referrerpolicy="strict-origin-when-cross-origin">
          </iframe>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            var player;
            // Block WebKit / iframe native fullscreen; the app owns reversible fullscreen.
            ['fullscreenchange', 'webkitfullscreenchange'].forEach(function(name) {
              document.addEventListener(name, function() {
                var fullscreenElement = document.fullscreenElement || document.webkitFullscreenElement;
                if (fullscreenElement && document.exitFullscreen) {
                  document.exitFullscreen();
                } else if (fullscreenElement && document.webkitExitFullscreen) {
                  document.webkitExitFullscreen();
                }
              });
            });
            function postToApp(payload) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.youtubePlayer) {
                window.webkit.messageHandlers.youtubePlayer.postMessage(payload);
              }
            }
            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                events: {
                  'onReady': function() {
                    disableNativeCaptions();
                    postToApp({ event: 'ready' });
                  },
                  'onStateChange': function() {
                    disableNativeCaptions();
                    if (player && player.getPlayerState && player.getPlayerState() === 0) {
                      postToApp({ event: 'ended' });
                    }
                  },
                  'onError': function(event) {
                    postToApp({ event: 'error', code: event.data });
                  }
                }
              });
            }
            function disableNativeCaptions() {
              try {
                if (player && player.unloadModule) {
                  player.unloadModule('captions');
                }
              } catch (error) {
                postToApp({ event: 'caption-disable-error', message: String(error) });
              }
            }
            var captionDisableAttempts = 0;
            var captionDisableTimer = setInterval(function() {
              captionDisableAttempts += 1;
              disableNativeCaptions();
              if (captionDisableAttempts >= 20) {
                clearInterval(captionDisableTimer);
              }
            }, 250);
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var webView: WKWebView?
        var videoID: String?
        var initialTime: TimeInterval?
        private var currentTime: Binding<TimeInterval>
        private var duration: Binding<TimeInterval>
        var playbackRate: Double
        var shouldResumeAfterInitialSeek: Bool
        var onPlaybackStateChange: (Bool) -> Void
        var onEffectiveRateChange: (Double) -> Void
        var onPlaybackEnded: () -> Void
        private var timer: Timer?
        private var didSeekInitialPosition = false
        private var repeatRange: ClosedRange<TimeInterval>?
        private var isLoopSeekPending = false
        private var lastConsumedCommandSequence = 0
        private var isPlayerReady = false
        private var pendingCommands: [YTPlaybackCommand] = []

        init(
            currentTime: Binding<TimeInterval>,
            duration: Binding<TimeInterval>,
            initialTime: TimeInterval?,
            playbackRate: Double,
            playbackCommand: YTPlaybackCommand?,
            repeatRange: ClosedRange<TimeInterval>?,
            shouldResumeAfterInitialSeek: Bool,
            onPlaybackStateChange: @escaping (Bool) -> Void,
            onEffectiveRateChange: @escaping (Double) -> Void,
            onPlaybackEnded: @escaping () -> Void
        ) {
            self.currentTime = currentTime
            self.duration = duration
            self.initialTime = initialTime
            self.playbackRate = playbackRate
            self.repeatRange = repeatRange
            self.shouldResumeAfterInitialSeek = shouldResumeAfterInitialSeek
            self.onPlaybackStateChange = onPlaybackStateChange
            self.onEffectiveRateChange = onEffectiveRateChange
            self.onPlaybackEnded = onPlaybackEnded
            self.lastConsumedCommandSequence = playbackCommand?.sequence ?? 0
        }

        func startPolling() {
            stopPolling()
            let interval = repeatRange == nil ? 0.2 : 0.1
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.pollPlaybackState()
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        private func pollPlaybackState() {
            let script = """
            player && player.getCurrentTime && player.getDuration
              ? {
                  currentTime: player.getCurrentTime(),
                  duration: player.getDuration(),
                  state: player.getPlayerState ? player.getPlayerState() : -1,
                  rate: player.getPlaybackRate ? player.getPlaybackRate() : 1
                }
              : { currentTime: 0, duration: 0, state: -1, rate: 1 }
            """
            webView?.evaluateJavaScript(script) { [weak self] value, _ in
                guard let state = value as? [String: Any] else { return }
                let seconds = state["currentTime"] as? Double ?? 0
                let duration = state["duration"] as? Double ?? 0
                let playerState = state["state"] as? Double ?? -1
                let rate = state["rate"] as? Double ?? 1
                DispatchQueue.main.async {
                    self?.currentTime.wrappedValue = seconds
                    self?.onPlaybackStateChange(playerState == 1)
                    self?.onEffectiveRateChange(rate)
                    if duration.isFinite, duration > 0 {
                        self?.duration.wrappedValue = duration
                    }
                    self?.loopIfNeeded(at: seconds)
                }
            }
        }

        func consume(_ command: YTPlaybackCommand?) {
            guard let command, command.sequence > lastConsumedCommandSequence else { return }
            lastConsumedCommandSequence = command.sequence
            guard isPlayerReady else {
                pendingCommands.append(command)
                return
            }
            execute(command)
        }

        private func execute(_ command: YTPlaybackCommand) {
            let script: String
            switch command.action {
            case .play:
                script = "if (player && player.playVideo) { player.playVideo(); }"
            case .pause:
                script = "if (player && player.pauseVideo) { player.pauseVideo(); }"
            case .seek(let seconds, let resumeAfterSeek):
                let followup = resumeAfterSeek ? "player.playVideo();" : "player.pauseVideo();"
                script = "if (player && player.seekTo) { player.seekTo(\(max(0, seconds)), true); \(followup) }"
                currentTime.wrappedValue = max(0, seconds)
            }
            webView?.evaluateJavaScript(script)
        }

        private func playerDidBecomeReady() {
            isPlayerReady = true
            seekInitialPositionIfNeeded()
            applyPlaybackRate()
            let commands = pendingCommands
            pendingCommands.removeAll()
            commands.forEach(execute)
        }

        func updateRepeatRange(_ range: ClosedRange<TimeInterval>?) {
            guard repeatRange != range else { return }
            repeatRange = range
            isLoopSeekPending = false
            startPolling()
        }

        func prepareForReload() {
            isPlayerReady = false
            pendingCommands.removeAll()
        }

        func applyPlaybackRate() {
            guard playbackRate.isFinite, playbackRate > 0 else { return }
            webView?.evaluateJavaScript(
                "if (player && player.setPlaybackRate) { player.setPlaybackRate(\(playbackRate)); }"
            )
        }

        private func loopIfNeeded(at seconds: TimeInterval) {
            guard let repeatRange,
                  seconds >= repeatRange.upperBound,
                  !isLoopSeekPending
            else { return }
            isLoopSeekPending = true
            let script = "if (player && player.seekTo) { player.seekTo(\(repeatRange.lowerBound), true); player.playVideo(); }"
            webView?.evaluateJavaScript(script) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.currentTime.wrappedValue = repeatRange.lowerBound
                    self?.isLoopSeekPending = false
                }
            }
        }

        func resetInitialSeek() {
            didSeekInitialPosition = false
        }

        private func seekInitialPositionIfNeeded() {
            guard !didSeekInitialPosition else { return }
            didSeekInitialPosition = true
            guard let initialTime = PlaybackProgressPolicy.restorePosition(from: initialTime) else {
                if shouldResumeAfterInitialSeek {
                    webView?.evaluateJavaScript("if (player && player.playVideo) { player.playVideo(); }")
                }
                return
            }
            let followup = shouldResumeAfterInitialSeek ? "player.playVideo();" : ""
            let script = "if (player && player.seekTo) { player.seekTo(\(initialTime), true); \(followup) }"
            webView?.evaluateJavaScript(script)
            currentTime.wrappedValue = initialTime
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "youtubePlayer" else { return }
            if let body = message.body as? [String: Any],
               body["event"] as? String == "ready" {
                playerDidBecomeReady()
            }
            if let body = message.body as? [String: Any],
               body["event"] as? String == "ended" {
                onPlaybackEnded()
            }
            print("YouTube iframe event: \(message.body)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("YouTube iframe navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("YouTube iframe provisional navigation failed: \(error.localizedDescription)")
        }
    }
}
#endif
