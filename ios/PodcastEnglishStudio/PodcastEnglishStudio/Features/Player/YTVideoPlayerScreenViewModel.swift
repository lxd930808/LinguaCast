import Foundation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

@MainActor
@Observable
final class YTVideoPlayerScreenViewModel {
    let video: YTVideoRecord

    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var errorMessage: String?
    var lastPersistedPlaybackTime: TimeInterval?
    var lastPersistedPlaybackAt: Date?
    var subtitleState = YTSubtitleDisplayState()
    var playbackController = YTVideoPlaybackController()
    var localService = YTLocalService()
    var isRetryingSubtitles = false
    var showingPlayerActions = false
    var availableQualityTiers: [YTStreamSelectionPolicy] = YTStreamSelectionPolicy.qualityTierOptions

    init(video: YTVideoRecord) {
        self.video = video
    }

    func synchronizeSentenceContext() {
        playbackController.updateTimeline(
            currentTime: currentTime,
            segments: subtitleState.segments
        )
    }

    var initialTime: TimeInterval? {
        PlaybackProgressPolicy.restorePosition(from: video.playbackPositionSeconds)
    }

    var canRetrySubtitles: Bool {
        !isRetryingSubtitles
            && (video.subtitleStatus == "failed"
                || video.subtitleStatus == "partial"
                || (video.enReady && !video.zhReady))
    }

    var subtitleActionMessage: String {
        if video.bilingualSubtitlesCompleted { return L10n.string("ytvideo_player.bilingual_subtitles_are_ready", fallback: "Bilingual subtitles are ready") }
        switch video.subtitleStatus {
        case "ready": return L10n.string("ytvideo_player.bilingual_subtitles_are_ready", fallback: "Bilingual subtitles are ready")
        case "partial": return L10n.string("ytvideo_player.the_english_subtitles_have_been_saved_and_the_translation_will_b", fallback: "The English subtitles have been saved and the translation will be tried again.")
        case "running": return L10n.string("ytvideo_player.getting_english_subtitles", fallback: "Getting English subtitles")
        case "translating":
            if let totalCount = video.subtitleTotalCount, totalCount > 0 {
                return L10n.format("subtitles.translating_progress", fallback: "LLM subtitle translation %@/%@", String(video.subtitleTranslatedCount ?? 0), String(totalCount))
            }
            return L10n.string("ytvideo_player.translating_subtitles_in_llm", fallback: "Translating subtitles in LLM")
        case "failed":
            return L10n.string("subtitles.unavailable", fallback: "Subtitles Unavailable")
        default:
            return video.enReady ? L10n.string("ytvideo_player.the_english_subtitles_have_been_saved_and_the_translation_will_b", fallback: "The English subtitles have been saved and the translation will be tried again.") : L10n.string("ytvideo_player.automatically_obtain_subtitles_after_entering_the_play_page", fallback: "Automatically obtain subtitles after entering the play page")
        }
    }

    var paraformerUnavailableMessage: String {
        L10n.string("ytvideo_player.currently_not_able_to_re_transcribe_youtube_videos_ios_iframe_an", fallback: "Currently not able to re-transcribe YouTube videos: iOS IFrame and tvOS compatible playback paths do not reliably provide uploadable audio files. If there are existing English subtitles, we will continue to try to translate them; if they need to be re-translated, subsequent versions will support the import of local audio files.")
    }

    var subtitleStatusText: String {
        if video.bilingualSubtitlesCompleted { return L10n.string("common.bilingual_subtitles", fallback: "bilingual subtitles") }
        switch video.subtitleStatus {
        case "failed": return L10n.string("common.subtitles_failed", fallback: "Subtitles failed")
        case "partial": return L10n.string("ytvideo_player.retryable_subtitles", fallback: "Retryable subtitles")
        case "running": return L10n.string("ytvideo_player.get_subtitles", fallback: "Get subtitles")
        case "translating": return L10n.string("ytvideo_player.translate_subtitles", fallback: "Translate subtitles")
        default: return video.enReady ? L10n.string("common.english_subtitles", fallback: "English subtitles") : L10n.string("ytvideo_player.subtitle_status", fallback: "subtitle status")
        }
    }

    var subtitleStatusIcon: String {
        if video.bilingualSubtitlesCompleted { return "captions.bubble.fill" }
        if video.subtitleStatus == "failed" { return "exclamationmark.triangle" }
        if video.subtitleStatus == "partial" { return "arrow.clockwise" }
        if video.subtitleStatus == "running" || video.subtitleStatus == "translating" { return "clock" }
        return "captions.bubble"
    }

    func loadPersistedPlaybackState() {
        lastPersistedPlaybackTime = video.playbackPositionSeconds
        lastPersistedPlaybackAt = video.playbackUpdatedAt
        duration = video.playbackDurationSeconds ?? 0
    }

    func persistPlaybackProgress(_ value: TimeInterval, force: Bool = false, context: ModelContext) {
        let now = Date()
        guard let position = PlaybackProgressPolicy.positionToPersist(
            currentTime: value,
            lastPersistedTime: lastPersistedPlaybackTime,
            lastPersistedAt: lastPersistedPlaybackAt,
            now: now,
            force: force
        ) else { return }
        video.playbackPositionSeconds = position
        video.playbackUpdatedAt = now
        markCompletedIfThresholdReached(position: position, now: now)
        video.recordUpdatedAt = now
        do {
            try context.save()
            lastPersistedPlaybackTime = position
            lastPersistedPlaybackAt = now
            // Forward to iCloud sync; the coordinator derives the stable identity and
            // playable catalog snapshot from the domain record.
            CloudSyncCoordinator.shared.recordPlaybackProgress(
                video: video,
                positionSeconds: position,
                durationSeconds: video.playbackDurationSeconds,
                completedAt: video.playbackCompletedAt,
                modifiedAt: now
            )
        } catch {
            errorMessage = L10n.format("playback.error.save_position", fallback: "Failed to save playback position: %@", error.localizedDescription)
        }
    }

    func persistPlaybackDuration(_ value: TimeInterval, context: ModelContext) {
        guard value.isFinite, value > 0 else { return }
        if let savedDuration = video.playbackDurationSeconds,
           abs(savedDuration - value) < 0.5 {
            return
        }

        let now = Date()
        video.playbackDurationSeconds = value
        markCompletedIfThresholdReached(position: currentTime, now: now)
        video.recordUpdatedAt = now
        do {
            try context.save()
        } catch {
            errorMessage = L10n.format("playback.error.save_duration", fallback: "Failed to save playback duration: %@", error.localizedDescription)
        }
    }

    func updatePlaybackMetrics(height: Int?, codec: String?, context: ModelContext) {
        var changed = false
        if let height, height > 0, video.actualPlaybackHeight != height {
            video.actualPlaybackHeight = height
            changed = true
        }
        if let codec, !codec.isEmpty, video.actualPlaybackCodec != codec {
            video.actualPlaybackCodec = codec
            changed = true
        }
        guard changed else { return }
        video.recordUpdatedAt = Date()
        try? context.save()
    }

    func markPlaybackCompleted(context: ModelContext) {
        let now = Date()
        video.playbackCompletedAt = video.playbackCompletedAt ?? now
        if duration.isFinite, duration > 0 {
            video.playbackDurationSeconds = duration
            video.playbackPositionSeconds = max(currentTime, duration)
        } else if currentTime.isFinite,
                  currentTime >= PlaybackProgressPolicy.minimumRestorablePosition {
            video.playbackPositionSeconds = currentTime
        }
        video.playbackUpdatedAt = now
        video.recordUpdatedAt = now
        do {
            try context.save()
            lastPersistedPlaybackTime = video.playbackPositionSeconds
            lastPersistedPlaybackAt = now
        } catch {
            errorMessage = L10n.format("playback.error.save_completion", fallback: "Failed to save playback completion: %@", error.localizedDescription)
        }
    }

    private func markCompletedIfThresholdReached(position: TimeInterval, now: Date) {
        guard video.playbackCompletedAt == nil else { return }
        let category = PlaybackListPolicy.category(
            playbackPosition: position,
            duration: video.playbackDurationSeconds,
            completedAt: nil
        )
        if category == .played {
            video.playbackCompletedAt = now
        }
    }

    func retrySubtitles(settings: SettingsStore, context: ModelContext) async {
        guard !isRetryingSubtitles else { return }
        isRetryingSubtitles = true
        errorMessage = nil
        subtitleState.errorMessage = nil
        defer { isRetryingSubtitles = false }
        do {
            let segments = try await localService.retrySubtitles(
                video: video,
                configuration: settings.configuration,
                context: context,
                captionIngestionPolicy: IOSYouTubePlaybackMode.effective(
                    configured: settings.committedConfiguration.youTubePlaybackMode
                ).captionIngestionPolicy
            ) { partial in
                self.subtitleState.segments = partial
                self.subtitleState.errorMessage = nil
            }
            subtitleState.segments = segments
            subtitleState.errorMessage = nil
        } catch {
            guard AsyncOperationErrorPresentationPolicy.shouldPresent(error) else { return }
            errorMessage = L10n.format("subtitles.error.retry", fallback: "Subtitle retry failed: %@", error.localizedDescription)
        }
    }
}
