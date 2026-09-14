import Foundation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

enum AssistantPreparedPlayback: Equatable {
    case podcast(episodeID: String)
    case youtube(videoID: String)
}

enum AssistantPlaybackPrepareError: LocalizedError {
    case missingJob
    case unsupportedSource
    case missingFeedURL
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .missingJob:
            L10n.string(
                "assistant.playback.missing_job",
                fallback: "This source is not ready to play yet."
            )
        case .unsupportedSource:
            L10n.string(
                "assistant.playback.unsupported",
                fallback: "This source type cannot be opened in the player."
            )
        case .missingFeedURL:
            L10n.string(
                "assistant.playback.missing_feed",
                fallback: "This podcast episode is missing a feed URL."
            )
        case .notConfigured:
            L10n.string(
                "assistant.playback.not_configured",
                fallback: "The cloud transcription service is not configured."
            )
        }
    }
}

protocol AssistantCloudArtifactInstalling {
    func installPodcastArtifacts(
        episode: EpisodeRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws

    func installVideoArtifacts(
        video: YTVideoRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws
}

struct LiveAssistantCloudArtifactInstaller: AssistantCloudArtifactInstalling {
    let runner: PipelineRunner
    let youtube: YTLocalService

    func installPodcastArtifacts(
        episode: EpisodeRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws {
        try await runner.installReadyAssistantCloudJob(
            episode: episode,
            jobID: jobID,
            target: target,
            configuration: configuration,
            context: context
        )
    }

    func installVideoArtifacts(
        video: YTVideoRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws {
        try await youtube.installReadyAssistantCloudSubtitles(
            video: video,
            jobID: jobID,
            target: target,
            configuration: configuration,
            context: context
        )
    }
}

@MainActor
struct AssistantPlaybackPreparer {
    var installer: AssistantCloudArtifactInstalling

    init(installer: AssistantCloudArtifactInstalling) {
        self.installer = installer
    }

    init(runner: PipelineRunner, youtube: YTLocalService) {
        self.installer = LiveAssistantCloudArtifactInstaller(runner: runner, youtube: youtube)
    }

    func prepare(
        binding: AssistantContentBinding,
        source: AssistantSearchResult,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws -> AssistantPreparedPlayback {
        guard let jobID = binding.v10JobId, !jobID.isEmpty else {
            throw AssistantPlaybackPrepareError.missingJob
        }
        let target = TranslationTarget(rawValue: binding.targetLanguage)
            ?? configuration.translationTarget

        if isVideo(binding: binding, source: source) {
            let video = try materializeVideo(source: source, context: context)
            try await installer.installVideoArtifacts(
                video: video,
                jobID: jobID,
                target: target,
                configuration: configuration,
                context: context
            )
            return .youtube(videoID: video.id)
        }

        guard source.sourceType == .podcastEpisode || binding.contentType == .podcastEpisode else {
            throw AssistantPlaybackPrepareError.unsupportedSource
        }
        let episode = try materializePodcast(
            binding: binding,
            source: source,
            context: context
        )
        try await installer.installPodcastArtifacts(
            episode: episode,
            jobID: jobID,
            target: target,
            configuration: configuration,
            context: context
        )
        return .podcast(episodeID: episode.id)
    }

    func materializeVideo(
        source: AssistantSearchResult,
        context: ModelContext
    ) throws -> YTVideoRecord {
        let videoID = source.sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try fetchVideo(id: videoID, context: context)
        if let existing {
            if existing.title.isEmpty { existing.title = source.title }
            if existing.url.isEmpty { existing.url = source.canonicalURL }
            if existing.thumbnail == nil { existing.thumbnail = source.thumbnailURL }
            existing.recordUpdatedAt = Date()
            try context.save()
            return existing
        }
        let video = YTVideoRecord(
            id: videoID,
            channelRecordID: CatalogOrigin.assistantChannelRecordID,
            channelID: CatalogOrigin.assistantChannelRecordID,
            title: source.title,
            publishedAt: source.publishedAt,
            url: source.canonicalURL,
            thumbnail: source.thumbnailURL,
            originRaw: CatalogOrigin.assistant.rawValue
        )
        context.insert(video)
        try context.save()
        return video
    }

    func materializePodcast(
        binding: AssistantContentBinding,
        source: AssistantSearchResult,
        context: ModelContext
    ) throws -> EpisodeRecord {
        let guid = (source.guid ?? source.sourceId).trimmingCharacters(in: .whitespacesAndNewlines)
        let feedURL = source.feedURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try fetchAssistantEpisode(guid: guid, feedURL: feedURL, context: context) {
            existing.episodeTitle = source.title
            existing.showTitle = source.publisher ?? existing.showTitle
            existing.enclosureURL = source.playbackAudioURL
            existing.episodeWebsiteURL = source.canonicalURL
            existing.artworkURL = source.thumbnailURL ?? existing.artworkURL
            existing.assistantFeedURL = feedURL ?? existing.assistantFeedURL
            existing.updatedAt = Date()
            try context.save()
            return existing
        }
        guard feedURL != nil || !binding.contentKey.isEmpty else {
            throw AssistantPlaybackPrepareError.missingFeedURL
        }
        let episode = EpisodeRecord(
            id: "asst-\(binding.contentKey)",
            showTitle: source.publisher ?? source.title,
            showArtist: source.publisher ?? "",
            episodeTitle: source.title,
            episodeGUID: guid,
            publishedAt: source.publishedAt,
            enclosureURL: source.playbackAudioURL,
            artworkURL: source.thumbnailURL,
            mediaDurationSeconds: source.durationSeconds.map(Double.init),
            episodeWebsiteURL: source.canonicalURL,
            status: "queued",
            pipelineStep: "package",
            isNew: false,
            originRaw: CatalogOrigin.assistant.rawValue,
            assistantFeedURL: feedURL
        )
        context.insert(episode)
        try context.save()
        return episode
    }

    private func isVideo(binding: AssistantContentBinding, source: AssistantSearchResult) -> Bool {
        source.sourceType == .video || binding.contentType == .video
    }

    #if os(iOS)
    // MARK: - V15 research assistant (AssistantV2)
    //
    // V2's transcript job already carries the same V10 `v10JobId` V1's binding does, so the
    // install step below is identical to the V1 path above. Only "turn this source into a local
    // EpisodeRecord/YTVideoRecord" differs, because `AssistantV2DisplayedSource` (built from a
    // leaner V2 search-hit payload) carries less metadata than V1's `AssistantSearchResult`
    // (no thumbnail, publisher, duration, or feed URL today).

    /// Mirrors `prepare(binding:source:...)` for a V2 research's transcript job.
    func prepare(
        job: AssistantV2TranscriptJob,
        source: AssistantV2DisplayedSource,
        targetLanguage: String,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws -> AssistantPreparedPlayback {
        guard let jobID = job.v10JobId, !jobID.isEmpty else {
            throw AssistantPlaybackPrepareError.missingJob
        }
        let target = TranslationTarget(rawValue: targetLanguage) ?? configuration.translationTarget

        if source.platform.lowercased() == "youtube" {
            let video = try materializeVideoV2(source: source, context: context)
            try await installer.installVideoArtifacts(
                video: video,
                jobID: jobID,
                target: target,
                configuration: configuration,
                context: context
            )
            return .youtube(videoID: video.id)
        }

        guard source.platform.lowercased() == "podcast" else {
            throw AssistantPlaybackPrepareError.unsupportedSource
        }
        let episode = try materializePodcastV2(source: source, contentKey: job.contentKey, context: context)
        try await installer.installPodcastArtifacts(
            episode: episode,
            jobID: jobID,
            target: target,
            configuration: configuration,
            context: context
        )
        return .podcast(episodeID: episode.id)
    }

    private func materializeVideoV2(source: AssistantV2DisplayedSource, context: ModelContext) throws -> YTVideoRecord {
        let videoID = (source.nativeSourceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !videoID.isEmpty else { throw AssistantPlaybackPrepareError.unsupportedSource }
        if let existing = try fetchVideo(id: videoID, context: context) {
            if existing.title.isEmpty { existing.title = source.title }
            if existing.url.isEmpty, let url = source.canonicalURL { existing.url = url }
            existing.recordUpdatedAt = Date()
            try context.save()
            return existing
        }
        let video = YTVideoRecord(
            id: videoID,
            channelRecordID: CatalogOrigin.assistantChannelRecordID,
            channelID: CatalogOrigin.assistantChannelRecordID,
            title: source.title,
            publishedAt: nil,
            url: source.canonicalURL ?? "",
            thumbnail: nil,
            originRaw: CatalogOrigin.assistant.rawValue
        )
        context.insert(video)
        try context.save()
        return video
    }

    private func materializePodcastV2(
        source: AssistantV2DisplayedSource,
        contentKey: String,
        context: ModelContext
    ) throws -> EpisodeRecord {
        let guid = (source.nativeSourceId ?? contentKey).trimmingCharacters(in: .whitespacesAndNewlines)
        // V2 search hits don't carry a feed URL today (see AssistantV2SearchHit), so dedup falls
        // back to matching on guid alone; contentKey (always non-empty — the server derives it
        // from the feed URL) stands in for "this source is eligible" in the guard below.
        if let existing = try fetchAssistantEpisode(guid: guid, feedURL: nil, context: context) {
            existing.episodeTitle = source.title
            existing.enclosureURL = source.enclosureUrl ?? existing.enclosureURL
            existing.episodeWebsiteURL = source.canonicalURL ?? existing.episodeWebsiteURL
            existing.updatedAt = Date()
            try context.save()
            return existing
        }
        guard !contentKey.isEmpty else { throw AssistantPlaybackPrepareError.missingFeedURL }
        let episode = EpisodeRecord(
            id: "asst-\(contentKey)",
            showTitle: source.title,
            showArtist: "",
            episodeTitle: source.title,
            episodeGUID: guid,
            publishedAt: nil,
            enclosureURL: source.enclosureUrl ?? "",
            artworkURL: nil,
            mediaDurationSeconds: nil,
            episodeWebsiteURL: source.canonicalURL,
            status: "queued",
            pipelineStep: "package",
            isNew: false,
            originRaw: CatalogOrigin.assistant.rawValue,
            assistantFeedURL: nil
        )
        context.insert(episode)
        try context.save()
        return episode
    }

    #endif

    private func fetchVideo(id: String, context: ModelContext) throws -> YTVideoRecord? {
        try context.fetch(FetchDescriptor<YTVideoRecord>()).first { $0.id == id }
    }

    private func fetchAssistantEpisode(
        guid: String,
        feedURL: String?,
        context: ModelContext
    ) throws -> EpisodeRecord? {
        let episodes = try context.fetch(FetchDescriptor<EpisodeRecord>())
        return episodes.first { episode in
            guard episode.catalogOrigin == .assistant else { return false }
            guard episode.episodeGUID == guid else { return false }
            if let feedURL, let stored = episode.assistantFeedURL {
                return stored == feedURL
            }
            return true
        }
    }
}
