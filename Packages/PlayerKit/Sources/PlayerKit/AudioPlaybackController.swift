import AVFoundation
import Foundation
import Observation
import PodcastEnglishStudioCore

@MainActor
@Observable
public final class AudioPlaybackController {
    public var activeSequence: Int?
    public var currentTime: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var isPlaying = false
    public var errorMessage: String?
    public var playbackRate: Float = 1.0 {
        didSet { player?.rate = isPlaying ? playbackRate : 0 }
    }

    /// When set, the next play restores the audio session and waits for seek to this
    /// position to finish before starting playback (lock/unlock resume path).
    public private(set) var pendingResumeSeekTime: TimeInterval?

    /// The source backing the current player item. In-memory only: signed URLs
    /// are never persisted (WP12).
    public private(set) var currentSource: AudioPlaybackSource?

    /// Validation policy for remote sources (HTTPS + optional host allowlist).
    /// Local-file sources are unaffected.
    public var remoteHostPolicy: RemoteAudioHostPolicy

    /// App-injected hook fired once per item when the current remote item fails
    /// (401/403/expired/transport). PlayerKit performs no networking; the app
    /// should fetch a fresh signed source and call replaceSourcePreservingPosition(_:).
    public var onSourceRefreshRequired: (@MainActor (AudioPlaybackSource) -> Void)?

    @ObservationIgnored private var playbackRequestID = UUID()
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemDurationObservation: NSKeyValueObservation?
    @ObservationIgnored private var segments: [LearningSegment] = []
    @ObservationIgnored private var segmentIndex = EpisodePlaybackSegmentIndex(segments: [])
    @ObservationIgnored private var requestedInitialTime: TimeInterval?
    @ObservationIgnored private var isSeekingBeforePlay = false
    @ObservationIgnored private var refreshRequestedForCurrentItem = false

    public init(remoteHostPolicy: RemoteAudioHostPolicy = .anySecureHost) {
        self.remoteHostPolicy = remoteHostPolicy
    }

    deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
    }

    /// Local-file entry point kept source-compatible; forwards to load(source:).
    public func load(audioURL: URL, segments: [LearningSegment], initialTime: TimeInterval? = nil) {
        load(source: .localFile(audioURL), segments: segments, initialTime: initialTime)
    }

    public func load(source: AudioPlaybackSource, segments: [LearningSegment], initialTime: TimeInterval? = nil) {
        pausePlayback()
        self.segments = EpisodePlaybackSegmentPolicy.sorted(segments)
        segmentIndex = EpisodePlaybackSegmentIndex(segments: self.segments)
        let transcriptExtent = EpisodePlaybackSegmentPolicy.inferredDuration(from: self.segments) ?? 0
        duration = transcriptExtent
        guard validateSource(source) else { return }
        currentSource = source
        let player = ensurePlayer()
        let item = AVPlayerItem(url: source.url)
        refreshRequestedForCurrentItem = false
        observe(item)
        player.replaceCurrentItem(with: item)
        requestedInitialTime = PlaybackProgressPolicy.restorePosition(from: initialTime)
        let restoreTime = PlaybackSeekPolicy.clampedTime(
            requestedInitialTime ?? 0,
            duration: duration
        )
        currentTime = restoreTime
        activeSequence = nearestSequence(at: restoreTime)
        pendingResumeSeekTime = nil
        isSeekingBeforePlay = false
        if restoreTime > 0 {
            let time = CMTime(seconds: restoreTime, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        errorMessage = nil
    }

    /// Signed-URL refresh: swaps only the player item, preserving currentTime,
    /// playbackRate, activeSequence and any unconsumed pending resume. When the
    /// new source fails validation the current state (including last position)
    /// is left untouched.
    public func replaceSourcePreservingPosition(_ source: AudioPlaybackSource) {
        guard validateSource(source) else { return }
        playbackRequestID = UUID()
        let restoredTime = pendingResumeSeekTime ?? currentTime
        let stashedResume = pendingResumeSeekTime
        currentSource = source
        let player = ensurePlayer()
        let item = AVPlayerItem(url: source.url)
        refreshRequestedForCurrentItem = false
        observe(item)
        player.replaceCurrentItem(with: item)
        // Re-apply the position when the real media duration arrives late,
        // mirroring the load(initialTime:) path.
        requestedInitialTime = PlaybackProgressPolicy.restorePosition(from: restoredTime)
        let target = PlaybackSeekPolicy.clampedTime(restoredTime, duration: duration)
        currentTime = target
        activeSequence = nearestSequence(at: target)
        pendingResumeSeekTime = stashedResume
        isSeekingBeforePlay = false
        if target > 0 {
            let time = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        errorMessage = nil
    }

    public func playPause() {
        if isPlaying || isSeekingBeforePlay {
            pausePlayback()
        } else {
            beginPlayback()
        }
    }

    public func pausePlayback() {
        playbackRequestID = UUID()
        player?.pause()
        isPlaying = false
        isSeekingBeforePlay = false
    }

    /// Stash a resume position and recompute the active subtitle cue without playing.
    public func prepareResume(at time: TimeInterval) {
        let target = PlaybackSeekPolicy.clampedTime(time, duration: max(duration, time))
        pendingResumeSeekTime = target
        currentTime = target
        refreshActiveSequence()
    }

    public func refreshActiveSequence() {
        activeSequence = nearestSequence(at: currentTime)
    }

    public func play(segment: LearningSegment) {
        playbackRequestID = UUID()
        let requestID = playbackRequestID
        guard prepareForPlayback(), let player else { return }
        pendingResumeSeekTime = nil
        activeSequence = segment.sequence
        // Point-sentence starts at the whole playback sentence, not the display sub-clause.
        let target = PlaybackSeekPolicy.clampedTime(Double(segment.playbackStartMS) / 1000, duration: duration)
        currentTime = target
        isSeekingBeforePlay = true
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.playbackRequestID == requestID else { return }
                self.isSeekingBeforePlay = false
                guard finished else { return }
                self.player?.playImmediately(atRate: self.playbackRate)
                self.isPlaying = true
            }
        }
    }

    public func seek(to time: TimeInterval) {
        playbackRequestID = UUID()
        isSeekingBeforePlay = false
        // User-driven seeks (scrub / skip callers) cancel a stashed lock-resume seek.
        pendingResumeSeekTime = nil
        seekInternal(to: time)
    }

    public func skip(by offset: TimeInterval) {
        seek(to: PlaybackSeekPolicy.offsetTime(from: currentTime, by: offset, duration: duration))
    }

    private func seekInternal(to time: TimeInterval) {
        guard let player, player.currentItem != nil else { return }
        let target = PlaybackSeekPolicy.clampedTime(time, duration: duration)
        currentTime = target
        activeSequence = nearestSequence(at: target)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func beginPlayback() {
        playbackRequestID = UUID()
        let requestID = playbackRequestID
        guard prepareForPlayback(), let player else { return }

        if let resumeTime = pendingResumeSeekTime {
            pendingResumeSeekTime = nil
            let target = PlaybackSeekPolicy.clampedTime(resumeTime, duration: max(duration, resumeTime))
            currentTime = target
            activeSequence = nearestSequence(at: target)
            isSeekingBeforePlay = true
            let time = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.playbackRequestID == requestID else { return }
                    self.isSeekingBeforePlay = false
                    guard finished else { return }
                    // Re-activate the session immediately before play; unlock can leave it inactive.
                    self.configureAudioSession()
                    guard self.errorMessage == nil else { return }
                    self.player?.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                }
            }
            return
        }

        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    private func ensurePlayer() -> AVPlayer {
        if let player {
            return player
        }

        let newPlayer = AVPlayer()
        newPlayer.volume = 1
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handle(time: time.seconds)
            }
        }
        player = newPlayer
        return newPlayer
    }

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            errorMessage = nil
        } catch {
            errorMessage = PlayerKitL10n.format("error.audio_session_failed_detail", fallback: "Audio playback could not start.\nDetails: %@", error.localizedDescription)
        }
        #else
        errorMessage = nil
        #endif
    }

    private func prepareForPlayback() -> Bool {
        guard let player, player.currentItem != nil else {
            errorMessage = PlayerKitL10n.string("error.audio_not_loaded", fallback: "Audio is not loaded. Return and open this episode again.")
            isPlaying = false
            return false
        }
        configureAudioSession()
        if errorMessage != nil {
            isPlaying = false
            return false
        }
        if let itemError = player.currentItem?.error {
            errorMessage = PlayerKitL10n.format("error.audio_load_failed_detail", fallback: "Audio could not be loaded.\nDetails: %@", itemError.localizedDescription)
            isPlaying = false
            return false
        }
        return true
    }

    private func validateSource(_ source: AudioPlaybackSource) -> Bool {
        switch source {
        case .localFile(let url):
            return validateAudioFile(url)
        case .remote(let url, _):
            // Remote sources only check HTTPS + host policy; never FileManager.exists.
            return validateRemoteURL(url)
        }
    }

    private func validateAudioFile(_ audioURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: audioURL.fileSystemPath) else {
            errorMessage = PlayerKitL10n.string("error.audio_file_missing", fallback: "The local audio file is missing. Generate bilingual subtitles again.")
            isPlaying = false
            return false
        }
        let size = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            errorMessage = PlayerKitL10n.string("error.audio_file_empty", fallback: "The local audio file is empty. Generate bilingual subtitles again.")
            isPlaying = false
            return false
        }
        return true
    }

    private func validateRemoteURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else {
            errorMessage = PlayerKitL10n.string("error.audio_remote_not_https", fallback: "The remote audio address is not a secure HTTPS address.")
            isPlaying = false
            return false
        }
        guard remoteHostPolicy.allows(url) else {
            errorMessage = PlayerKitL10n.string("error.audio_remote_host_not_allowed", fallback: "The remote audio host is not allowed for playback.")
            isPlaying = false
            return false
        }
        return true
    }

    private func observe(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item.status == .failed, self.player?.currentItem === item else { return }
                self.handleItemFailure(item.error)
            }
        }
        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let mediaDuration = item.duration.seconds
            guard mediaDuration.isFinite, mediaDuration > 0 else { return }
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                self.applyDiscoveredDuration(mediaDuration)
            }
        }
    }

    /// Handles a failed current item. Internal (not private) so tests can
    /// simulate remote-item failures that KVO cannot produce deterministically.
    func handleItemFailure(_ error: Error?) {
        let detail = error?.localizedDescription
            ?? PlayerKitL10n.string("error.unknown_detail", fallback: "Unknown error")
        if AudioPlaybackFailureClassifier.isOffline(error) {
            // Offline with no local copy surfaces as a playback error only;
            // subtitle-generation state is never touched here.
            errorMessage = PlayerKitL10n.format("error.audio_offline_detail", fallback: "The network is unavailable and there is no local audio copy.\nDetails: %@", detail)
        } else {
            errorMessage = PlayerKitL10n.format("error.audio_load_failed_detail", fallback: "Audio could not be loaded.\nDetails: %@", detail)
        }
        isPlaying = false
        // Remote 401/403/failure: signal the app to refresh the signed source
        // (deduplicated: at most once per swapped-in item).
        if let source = currentSource, source.isRemote, !refreshRequestedForCurrentItem {
            refreshRequestedForCurrentItem = true
            onSourceRefreshRequired?(source)
        }
    }

    /// Applies a late-arriving media duration over the transcript-inferred one.
    /// Internal (not private) so tests can drive it directly.
    func applyDiscoveredDuration(_ mediaDuration: TimeInterval) {
        duration = mediaDuration
        if let requested = requestedInitialTime {
            requestedInitialTime = nil
            // Restoration seek must not cancel a prepareResume() stashed after load().
            seekInternal(to: requested)
            if let pending = pendingResumeSeekTime {
                prepareResume(at: min(pending, mediaDuration))
            }
        } else if currentTime > mediaDuration {
            seekInternal(to: mediaDuration)
        } else if let pending = pendingResumeSeekTime, pending > mediaDuration {
            prepareResume(at: mediaDuration)
        }
    }

    private func handle(time seconds: Double) {
        // Avoid overwriting the stashed resume position while waiting for the first play after unlock.
        guard pendingResumeSeekTime == nil, !isSeekingBeforePlay else { return }
        currentTime = PlaybackSeekPolicy.clampedTime(seconds, duration: duration)
        activeSequence = nearestSequence(at: currentTime)
    }

    private func nearestSequence(at seconds: TimeInterval) -> Int? {
        segmentIndex.nearestSequence(at: seconds)
    }
}
