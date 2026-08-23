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

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemDurationObservation: NSKeyValueObservation?
    @ObservationIgnored private var segments: [LearningSegment] = []
    @ObservationIgnored private var segmentIndex = EpisodePlaybackSegmentIndex(segments: [])
    @ObservationIgnored private var requestedInitialTime: TimeInterval?
    @ObservationIgnored private var isSeekingBeforePlay = false

    public init() {}

    deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
    }

    public func load(audioURL: URL, segments: [LearningSegment], initialTime: TimeInterval? = nil) {
        self.segments = EpisodePlaybackSegmentPolicy.sorted(segments)
        segmentIndex = EpisodePlaybackSegmentIndex(segments: self.segments)
        let transcriptExtent = EpisodePlaybackSegmentPolicy.inferredDuration(from: self.segments) ?? 0
        duration = transcriptExtent
        guard validateAudioFile(audioURL) else { return }
        let player = ensurePlayer()
        let item = AVPlayerItem(url: audioURL)
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

    public func playPause() {
        if isPlaying || isSeekingBeforePlay {
            pausePlayback()
        } else {
            beginPlayback()
        }
    }

    public func pausePlayback() {
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
                guard let self else { return }
                self.isSeekingBeforePlay = false
                guard finished else { return }
                self.player?.playImmediately(atRate: self.playbackRate)
                self.isPlaying = true
            }
        }
    }

    public func seek(to time: TimeInterval) {
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
                    guard let self else { return }
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

    private func observe(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .failed {
                    let detail = item.error?.localizedDescription
                        ?? PlayerKitL10n.string("error.unknown_detail", fallback: "Unknown error")
                    self.errorMessage = PlayerKitL10n.format("error.audio_load_failed_detail", fallback: "Audio could not be loaded.\nDetails: %@", detail)
                    self.isPlaying = false
                }
            }
        }
        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let mediaDuration = item.duration.seconds
            guard mediaDuration.isFinite, mediaDuration > 0 else { return }
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                self.duration = mediaDuration
                if let requestedInitialTime = self.requestedInitialTime {
                    self.requestedInitialTime = nil
                    // Restoration seek must not cancel a prepareResume() stashed after load().
                    self.seekInternal(to: requestedInitialTime)
                    if let pending = self.pendingResumeSeekTime {
                        self.prepareResume(at: min(pending, mediaDuration))
                    }
                } else if self.currentTime > mediaDuration {
                    self.seekInternal(to: mediaDuration)
                } else if let pending = self.pendingResumeSeekTime, pending > mediaDuration {
                    self.prepareResume(at: mediaDuration)
                }
            }
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
