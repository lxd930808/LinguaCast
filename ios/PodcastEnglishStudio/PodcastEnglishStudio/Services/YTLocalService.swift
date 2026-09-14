import Foundation
import CryptoKit
import SwiftData
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

enum YTLocalServiceError: LocalizedError {
    case invalidChannelURL
    case unresolvedChannelID
    case missingYouTubeAPIKey
    case unsupportedChannelInput
    case channelNotPersisted

    var errorDescription: String? {
        switch self {
        case .invalidChannelURL:
            L10n.string("error.youtube_invalid_channel", fallback: "Enter a valid YouTube channel URL, RSS URL, channel ID, or @handle.")
        case .unresolvedChannelID:
            L10n.string("error.youtube_unresolved_channel", fallback: "A YouTube channel ID could not be resolved from this address.")
        case .missingYouTubeAPIKey:
            L10n.string("error.youtube_missing_api_key", fallback: "Add a YouTube Data API Key in Settings first.")
        case .unsupportedChannelInput:
            L10n.string("error.youtube_unsupported_channel_input", fallback: "This channel address is not supported by the YouTube Data API. Use an @handle or channel ID.")
        case .channelNotPersisted:
            L10n.string("error.youtube_channel_not_persisted", fallback: "The YouTube channel could not be saved. Please try again.")
        }
    }
}

struct CloudSubtitleLookupError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

final class YTLocalService {
    private static var subtitleTaskGenerations: [String: Int] = [:]
    private static let maxLoadAllPages = 200

    private let youtubeAPIClient: YouTubeDataAPIClient
    private let captionService: YTCaptionService
    private let fileStore: YTSubtitleFileStore
    private let subtitleSync: SubtitleArtifactSyncing

    @MainActor
    init(
        session: URLSession = .shared,
        captionService: YTCaptionService = YTCaptionService(),
        fileStore: YTSubtitleFileStore = YTSubtitleFileStore(),
        subtitleSync: SubtitleArtifactSyncing? = nil
    ) {
        self.youtubeAPIClient = YouTubeDataAPIClient(session: session)
        self.captionService = captionService
        self.fileStore = fileStore
        self.subtitleSync = subtitleSync ?? CloudSyncCoordinator.shared
    }

    @MainActor
    func addChannel(input: String, displayName: String?, configuration: AppConfiguration, context: ModelContext) async throws -> YTChannelRecord {
        let apiKey = try youtubeAPIKey(from: configuration)
        let resolved = try await youtubeAPIClient.resolveChannel(input: input, apiKey: apiKey)
        let now = Date()
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? resolved.channel.title

        if let existing = try fetchChannel(id: resolved.channel.id, context: context) {
            existing.url = resolved.url
            existing.displayName = name
            existing.uploadsPlaylistID = resolved.channel.uploadsPlaylistID
            existing.isEnabled = true
            existing.updatedAt = now
            existing.lastError = nil
            existing.videoCount = resolved.channel.videoCount ?? existing.videoCount
        } else {
            let channel = YTChannelRecord(
                id: resolved.channel.id,
                channelID: resolved.channel.id,
                url: resolved.url,
                displayName: name,
                createdAt: now
            )
            channel.uploadsPlaylistID = resolved.channel.uploadsPlaylistID
            channel.videoCount = resolved.channel.videoCount ?? 0
            context.insert(channel)
        }
        try context.save()
        guard let channel = try fetchChannel(id: resolved.channel.id, context: context) else {
            throw YTLocalServiceError.channelNotPersisted
        }
        CloudSyncCoordinator.shared.upsertYouTube(channel, modifiedAt: channel.updatedAt)
        return channel
    }

    @MainActor
    func deleteChannel(_ channel: YTChannelRecord, context: ModelContext) throws {
        CloudSyncCoordinator.shared.deleteYouTube(channel)
        let channelID = channel.id
        let descriptor = FetchDescriptor<YTVideoRecord>(
            predicate: #Predicate<YTVideoRecord> { $0.channelRecordID == channelID }
        )
        for video in try context.fetch(descriptor) {
            Self.cancelSubtitleTasks(videoID: video.id)
            try fileStore.deleteAllFiles(videoID: video.id)
            try TranslationVariantRepository.deleteAll(
                contentKind: .youtubeVideo,
                contentID: video.id,
                context: context
            )
            context.delete(video)
        }
        context.delete(channel)
        try context.save()
    }

    @MainActor
    func refreshChannel(_ channel: YTChannelRecord, configuration: AppConfiguration, context: ModelContext) async {
        do {
            let apiKey = try youtubeAPIKey(from: configuration)
            try await repairChannelIDIfNeeded(channel, apiKey: apiKey, context: context)
            let page = try await fetchInitialVideosPage(channel, apiKey: apiKey)
            try upsert(feed: page.feed, for: channel, context: context)
            updateContinuationState(for: channel, page: page)
            channel.lastCheckedAt = Date()
            channel.lastError = nil
            channel.updatedAt = Date()
            if !page.feed.channelTitle.isEmpty, channel.displayName == channel.channelID || channel.displayName == channel.url {
                channel.displayName = page.feed.channelTitle
            }
            try context.save()
            CloudSyncCoordinator.shared.upsertYouTube(channel, modifiedAt: channel.updatedAt)
        } catch {
            channel.lastCheckedAt = Date()
            channel.lastError = error.localizedDescription
            channel.updatedAt = Date()
            try? context.save()
        }
    }

    @MainActor
    func loadMoreVideos(_ channel: YTChannelRecord, configuration: AppConfiguration, context: ModelContext) async {
        guard let continuation = channel.nextVideosContinuation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !continuation.isEmpty
        else {
            channel.hasMoreVideos = false
            channel.nextVideosContinuation = nil
            channel.updatedAt = Date()
            try? context.save()
            return
        }

        do {
            let apiKey = try youtubeAPIKey(from: configuration)
            try await repairChannelIDIfNeeded(channel, apiKey: apiKey, context: context)
            let page = try await fetchVideosContinuation(
                channel,
                continuation: continuation,
                apiKey: apiKey
            )
            try upsert(feed: page.feed, for: channel, context: context, updateLastVideoID: false)
            updateContinuationState(for: channel, page: page)
            channel.lastError = nil
            channel.updatedAt = Date()
            try context.save()
        } catch {
            channel.lastError = error.localizedDescription
            channel.updatedAt = Date()
            try? context.save()
        }
    }

    @MainActor
    func loadAllVideos(_ channel: YTChannelRecord, configuration: AppConfiguration, context: ModelContext) async {
        guard channel.hasMoreVideos else { return }

        do {
            let apiKey = try youtubeAPIKey(from: configuration)
            try await repairChannelIDIfNeeded(channel, apiKey: apiKey, context: context)
            var loadedPages = 0
            while let continuation = channel.nextVideosContinuation?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !continuation.isEmpty,
                  loadedPages < Self.maxLoadAllPages {
                let page = try await fetchVideosContinuation(
                    channel,
                    continuation: continuation,
                    apiKey: apiKey
                )
                try upsert(feed: page.feed, for: channel, context: context, updateLastVideoID: false)
                updateContinuationState(for: channel, page: page)
                channel.lastError = nil
                channel.updatedAt = Date()
                try context.save()
                loadedPages += 1
                guard channel.hasMoreVideos else { return }
            }
            if loadedPages >= Self.maxLoadAllPages {
                channel.lastError = L10n.format(
                    "error.youtube_page_limit",
                    fallback: "The end was not reached after loading %@ pages. Try again later.",
                    String(Self.maxLoadAllPages)
                )
                channel.updatedAt = Date()
                try? context.save()
            }
        } catch {
            channel.lastError = error.localizedDescription
            channel.updatedAt = Date()
            try? context.save()
        }
    }

    @MainActor
    private func updateContinuationState(for channel: YTChannelRecord, page: YTChannelVideosPage) {
        let hasMore = YTChannelPaginationPolicy.hasMoreVideos(after: page)
        channel.hasMoreVideos = hasMore
        channel.nextVideosContinuation = hasMore ? page.continuationToken : nil
    }

    /// Installs a completed V10 video job into an assistant-origin (or reused) record.
    @MainActor
    func installReadyAssistantCloudSubtitles(
        video: YTVideoRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws {
        guard let client = CloudContentGatewayFactory.makeClientIfCredentialsPresent(configuration: configuration) else {
            throw CloudSubtitleLookupError(
                message: "Cloud generation is enabled but the content service is not configured. [CLOUD_NOT_CONFIGURED]"
            )
        }
        let taskGeneration = Self.beginSubtitleTask(videoID: video.id)
        video.activeSubtitleTargetLanguage = target.rawValue
        let variant = try TranslationVariantRepository.getOrCreate(
            contentKind: .youtubeVideo,
            contentID: video.id,
            target: target,
            context: context
        )
        let job = try await client.getJob(jobID: jobID)
        guard job.status == .ready || job.stage == .completed else {
            throw CloudSubtitleLookupError(
                message: "Cloud job \(jobID) is not ready (status=\(job.status.rawValue))."
            )
        }
        let contentKey = CloudContentKeyPolicy.videoContentKey(platform: "youtube", videoID: video.id)
        _ = try await downloadAndStoreCloudArtifacts(
            job,
            client: client,
            video: video,
            target: target,
            variant: variant,
            taskGeneration: taskGeneration,
            expectedContentKey: contentKey,
            context: context,
            onProgress: nil
        )
    }

    @MainActor
    func ensureSubtitles(
        video: YTVideoRecord,
        configuration: AppConfiguration,
        context: ModelContext,
        bypassCloudCheck: Bool = false,
        resumeCloudJob: Bool = false,
        captionIngestionPolicy: YTCaptionIngestionPolicy = .strict,
        onProgress: (@MainActor ([LearningSegment]) -> Void)? = nil
    ) async throws -> [LearningSegment] {
        let taskGeneration = Self.beginSubtitleTask(videoID: video.id)
        let target = configuration.translationTarget
        video.activeSubtitleTargetLanguage = target.rawValue
        let files = try fileStore.files(videoID: video.id)
        let translationFiles = try fileStore.translationFiles(videoID: video.id, target: target)
        let variant = try TranslationVariantRepository.getOrCreate(
            contentKind: .youtubeVideo,
            contentID: video.id,
            target: target,
            context: context
        )
        if target == .simplifiedChinese,
           try fileStore.migrateLegacySimplifiedChineseIfNeeded(videoID: video.id, to: translationFiles) {
            variant.segmentsPath = translationFiles.segments.fileSystemPath
            if fileStore.readVTTIfExists(at: translationFiles.targetVTT) != nil {
                variant.targetVTTPath = translationFiles.targetVTT.fileSystemPath
            }
        }
        let artifactIdentity = SubtitleArtifactIdentity.youtube(videoID: video.id, target: target)
        var savedSourceSegments: [LearningSegment] = []
        print("YTLocalService: subtitle files ready at \(files.directory.fileSystemPath)")
        let localManifest = fileStore.readManifestIfExists(at: translationFiles.manifest)
        let localPipelineCurrent = SubtitlePipelineVersion.isCurrent(localManifest?.pipelineVersion)
        // Phase 5 freshness: a complete legacy build stays playable (playableLegacy) and only
        // surfaces a manual "upgrade subtitle quality" entry — it is NOT auto-rebuilt on open.
        // An incomplete/corrupt stale cache is still discarded so it can regenerate.
        if !localPipelineCurrent {
            let legacyPlayable = SubtitlePipelineVersion.isPlayableLegacy(localManifest?.pipelineVersion)
                && existingSourceSegments(for: video, files: files) != nil
                && savedSegments(variant: variant, files: translationFiles) != nil
            if legacyPlayable, let source = existingSourceSegments(for: video, files: files) {
                savedSourceSegments = source
                let enCues = YTVTTParser.sourceCues(from: source)
                if video.enVTTPath != files.englishVTT.fileSystemPath {
                    video.enVTTPath = files.englishVTT.fileSystemPath
                    try? context.save()
                }
                if let readySegments = savedSegments(variant: variant, files: translationFiles),
                   translationIsComplete(
                    variant: variant,
                    files: translationFiles,
                    englishCues: enCues,
                    translatedCues: YTVTTParser.translatedCues(from: readySegments)
                   ) {
                    // Keep the legacy artifact playable as-is; leave its stamped pipelineVersion
                    // untouched so the UI can offer a manual upgrade. No auto-rebuild, no re-publish.
                    variant.variantStatus = .ready
                    variant.translatedCount = readySegments.count
                    variant.totalCount = readySegments.count
                    variant.targetVTTPath = translationFiles.targetVTT.fileSystemPath
                    variant.errorCode = nil
                    variant.technicalDetails = nil
                    applyVariant(variant, to: video)
                    try? context.save()
                    return readySegments
                }
            }
            print("YTLocalService: stale pipeline cache for \(video.id); rebuilding")
            video.enVTTPath = nil
            variant.segmentsPath = nil
            variant.targetVTTPath = nil
            variant.variantStatus = .notRequested
            variant.translatedCount = nil
            variant.totalCount = nil
            try? context.save()
        } else if let source = existingSourceSegments(for: video, files: files),
                  acceptsReusedSourceSegments(
                    source,
                    policy: captionIngestionPolicy,
                    configuration: configuration
                  ) {
            savedSourceSegments = source
            let enCues = YTVTTParser.sourceCues(from: source)
            print("YTLocalService: found existing English subtitles for \(video.id), segments=\(source.count)")
            if video.enVTTPath != files.englishVTT.fileSystemPath {
                video.enVTTPath = files.englishVTT.fileSystemPath
                try? context.save()
            }
            if let readySegments = savedSegments(variant: variant, files: translationFiles),
               translationIsComplete(
                variant: variant,
                files: translationFiles,
                englishCues: enCues,
                translatedCues: YTVTTParser.translatedCues(from: readySegments)
               ) {
                variant.variantStatus = .ready
                variant.translatedCount = readySegments.count
                variant.totalCount = readySegments.count
                variant.targetVTTPath = translationFiles.targetVTT.fileSystemPath
                variant.errorCode = nil
                variant.technicalDetails = nil
                applyVariant(variant, to: video)
                try persistManifest(for: video, target: target, variant: variant, files: translationFiles)
                try? context.save()
                try? await subtitleSync.publishReady(
                    identity: artifactIdentity,
                    segments: readySegments,
                    generatedAt: variant.updatedAt
                )
                if !bypassCloudCheck,
                   case .ready(let envelope) = await subtitleSync.lookup(identity: artifactIdentity) {
                    return try restoreReadyArtifact(
                        envelope,
                        video: video,
                        target: target,
                        variant: variant,
                        files: files,
                        translationFiles: translationFiles,
                        context: context
                    )
                }
                return readySegments
            }
        } else {
            video.enVTTPath = nil
            try? context.save()
        }

        if !bypassCloudCheck && !(resumeCloudJob && CloudVideoGenerationRouting.shouldUseCloudBackend(generationBackend: configuration.generationBackend)) {
            switch await subtitleSync.lookup(identity: artifactIdentity) {
            case .ready(let envelope):
                return try restoreReadyArtifact(
                    envelope,
                    video: video,
                    target: target,
                    variant: variant,
                    files: files,
                    translationFiles: translationFiles,
                    context: context
                )
            case .sourceOnly(let envelope):
                let restored = try restoreSourceArtifact(
                    envelope,
                    video: video,
                    files: files,
                    context: context
                )
                // Strict modes re-validate cloud source artifacts so a low-quality track
                // accepted under the lenient iframe policy is never reused.
                if acceptsReusedSourceSegments(
                    restored,
                    policy: captionIngestionPolicy,
                    configuration: configuration
                ) {
                    savedSourceSegments = restored
                } else {
                    savedSourceSegments = []
                    video.enVTTPath = nil
                    try? context.save()
                }
            case .notFound:
                break
            case .unavailable(let message):
                variant.variantStatus = .failed
                variant.errorCode = "cloud_check_required"
                variant.technicalDetails = message
                applyVariant(variant, to: video)
                try? context.save()
                throw CloudSubtitleLookupError(message: message)
            }
        }

        // V10/WP13: when the committed backend is cloud, new generation goes to
        // the content service as a contentType=video job. Platform-caption
        // fetching and the on-device audio ASR pipeline stay out of this path;
        // they remain available as diagnostics/manual fallback only.
        if CloudVideoGenerationRouting.shouldUseCloudBackend(
            generationBackend: configuration.generationBackend
        ) {
            return try await ensureSubtitlesFromCloud(
                video: video,
                target: target,
                variant: variant,
                taskGeneration: taskGeneration,
                resumeCloudJob: resumeCloudJob,
                configuration: configuration,
                context: context,
                onProgress: onProgress
            )
        }

        // Non-Chinese targets still require an LLM key. Simplified Chinese may
        // continue because an author track or `tlang=zh-Hans` can complete it.
        if !configuration.hasTranslationKey,
           !YTSubtitleCachePolicy.canGenerateLocallyWithoutTranslationKey(target: target) {
            let message = L10n.string(
                "subtitles.waiting_for_iphone",
                fallback: "Subtitles will appear after they are generated on iPhone."
            )
            variant.variantStatus = .failed
            variant.errorCode = "cloud_check_required"
            variant.technicalDetails = message
            applyVariant(variant, to: video)
            try? context.save()
            throw CloudSubtitleLookupError(message: message)
        }

        if !savedSourceSegments.isEmpty {
            return try await translateSavedEnglishIfNeeded(
                video: video,
                sourceSegments: savedSourceSegments,
                target: target,
                taskGeneration: taskGeneration,
                variant: variant,
                configuration: configuration,
                context: context,
                resumeSavedTranslations: YTSubtitleCachePolicy.shouldReuseSavedTranslations(
                    localPipelineVersion: localManifest?.pipelineVersion
                ),
                onProgress: onProgress
            )
        }

        variant.variantStatus = .running
        variant.errorCode = nil
        variant.technicalDetails = nil
        variant.translatedCount = nil
        variant.totalCount = nil
        applyVariant(variant, to: video)
        try? context.save()

        do {
            print("YTLocalService: fetching English captions for \(video.id) policy=\(captionIngestionPolicy.rawValue)")
            let package = try await captionService.fetchEnglishCaptionPackage(
                videoID: video.id,
                configuration: configuration,
                ingestionPolicy: captionIngestionPolicy
            )
            try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
            print("YTLocalService: fetched English captions for \(video.id), segments=\(package.segments.count)")
            let files = try fileStore.files(videoID: video.id)
            try fileStore.writeVTT(package.englishVTT, to: files.englishVTT)
            try fileStore.writeSegments(package.segments, to: files.baseSegments)

            video.enVTTPath = files.englishVTT.fileSystemPath
            video.sourceTranscriptMethod = "youtubeCaption"
            variant.variantStatus = .running
            variant.translatedCount = 0
            variant.totalCount = package.segments.count
            applyVariant(variant, to: video)
            try context.save()
            onProgress?(package.segments)

            return try await translateSavedEnglishIfNeeded(
                video: video,
                sourceSegments: package.segments,
                target: target,
                taskGeneration: taskGeneration,
                variant: variant,
                configuration: configuration,
                context: context,
                resumeSavedTranslations: YTSubtitleCachePolicy.shouldReuseSavedTranslations(
                    localPipelineVersion: localManifest?.pipelineVersion
                ),
                onProgress: onProgress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as YTCaptionError {
            print("YTLocalService: subtitle fetch failed for \(video.id): \(error.localizedUserMessage)")
            variant.variantStatus = .failed
            variant.errorCode = error.stableErrorCode
            variant.technicalDetails = error.localizedUserMessage
            applyVariant(variant, to: video)
            try? context.save()
            throw error
        } catch {
            print("YTLocalService: subtitle fetch failed for \(video.id): \(error.localizedDescription)")
            variant.variantStatus = .failed
            variant.errorCode = "source_caption_failed"
            variant.technicalDetails = error.localizedDescription
            applyVariant(variant, to: video)
            try? context.save()
            throw error
        }
    }

    /// V10/WP13 cloud generation: submit (or idempotently reuse) a
    /// contentType=video job, project server stages onto the video display
    /// fields, then download the packaged artifacts into YTSubtitleFileStore.
    /// Never touches YTCaptionService platform captions or LocalAudioASRPipeline.
    @MainActor
    private func ensureSubtitlesFromCloud(
        video: YTVideoRecord,
        target: TranslationTarget,
        variant: TranslationVariantRecord,
        taskGeneration: Int,
        resumeCloudJob: Bool,
        configuration: AppConfiguration,
        context: ModelContext,
        onProgress: (@MainActor ([LearningSegment]) -> Void)?
    ) async throws -> [LearningSegment] {
        guard let client = CloudContentGatewayFactory.makeClient(configuration: configuration) else {
            let message = "Cloud generation is enabled but the content service is not configured. [CLOUD_NOT_CONFIGURED]"
            variant.variantStatus = .failed
            variant.errorCode = "CLOUD_NOT_CONFIGURED"
            variant.technicalDetails = message
            applyVariant(variant, to: video)
            try? context.save()
            throw CloudSubtitleLookupError(message: message)
        }

        let contentKey = CloudContentKeyPolicy.videoContentKey(platform: "youtube", videoID: video.id)
        let request = CloudContentJobCreateRequest(
            contentType: .video,
            contentKey: contentKey,
            source: CloudContentSource(
                platform: "youtube",
                sourceId: video.id,
                url: video.url,
                title: video.title
            ),
            sourceLanguage: "en",
            targetLanguage: target.rawValue,
            translationQuality: configuration.translationQuality == .fast ? .fast : .quality
        )
        let jobStore = YTRemoteContentJobStore(context: context, serviceURL: configuration.normalizedContentServiceBaseURL)
        let coordinator = CloudContentJobCoordinator(client: client, store: jobStore)

        variant.variantStatus = .running
        variant.errorCode = nil
        variant.technicalDetails = nil
        video.sourceTranscriptMethod = "cloudASR"
        video.sourceGenerationStep = "queued"
        video.sourceGenerationProgress = 0
        try? context.save()

        do {
            let submitted: CloudContentJobResponse
            if resumeCloudJob {
                let savedID = try await jobStore.latestJobID(for: request)
                submitted = try await coordinator.resumeOrSubmit(request, savedJobID: savedID)
            } else {
                submitted = try await coordinator.submit(request)
            }
            try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
            let stableKey = submitted.stableKey
            print("YTLocalService: cloud job \(submitted.jobId) for \(video.id) reused=\(submitted.reused ?? false)")

            // Subscribe before the fresh fetch so a terminal transition between
            // submit and subscribe can never be missed.
            let updates = await coordinator.updates(for: stableKey)
            var job = try await client.getJob(jobID: submitted.jobId)
            try applyCloudJobProjection(
                job,
                expectedContentKey: contentKey,
                expectedStableKey: stableKey,
                video: video,
                context: context
            )
            while !job.status.isTerminal {
                var terminal: CloudContentJobResponse?
                for await update in updates {
                    guard CloudVideoJobUpdateGuard.shouldApply(
                        expectedContentKey: contentKey,
                        expectedStableKey: stableKey,
                        incomingContentKey: update.contentKey,
                        incomingStableKey: update.stableKey
                    ) else { continue }
                    try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
                    try applyCloudJobProjection(
                        update,
                        expectedContentKey: contentKey,
                        expectedStableKey: stableKey,
                        video: video,
                        context: context
                    )
                    if update.status.isTerminal {
                        terminal = update
                        break
                    }
                }
                guard let reached = terminal else { throw CancellationError() }
                job = reached
            }

            switch job.status {
            case .ready:
                return try await downloadAndStoreCloudArtifacts(
                    job,
                    client: client,
                    video: video,
                    target: target,
                    variant: variant,
                    taskGeneration: taskGeneration,
                    expectedContentKey: contentKey,
                    context: context,
                    onProgress: onProgress
                )
            case .failed:
                throw markCloudJobFailed(
                    job.error,
                    variant: variant,
                    video: video,
                    context: context
                )
            case .expired:
                throw markCloudJobFailed(
                    nil,
                    fallbackCode: "JOB_EXPIRED",
                    variant: variant,
                    video: video,
                    context: context
                )
            case .cancelled:
                video.subtitleStatus = "not_requested"
                video.sourceGenerationStep = nil
                video.sourceGenerationProgress = nil
                variant.variantStatus = .notRequested
                try? context.save()
                throw CancellationError()
            case .queued, .running, .unknown:
                throw CloudSubtitleLookupError(
                    message: "Cloud subtitle generation ended in an unexpected state. [INTERNAL_ERROR]"
                )
            }

        } catch is CancellationError {
            // Keep the variant in .running so the next ensureSubtitles call can
            // idempotently re-attach to the same server job.
            video.sourceGenerationStep = nil
            video.sourceGenerationProgress = nil
            try? context.save()
            throw CancellationError()
        } catch let error as CloudSubtitleLookupError {
            if variant.variantStatus != .failed {
                variant.variantStatus = .failed
                variant.errorCode = variant.errorCode ?? "cloud_generation_failed"
                variant.technicalDetails = error.message
                applyVariant(variant, to: video)
                video.sourceGenerationStep = nil
                video.sourceGenerationProgress = nil
                try? context.save()
            }
            throw error
        } catch let error as CloudContentError {
            let code: String
            let retryAfter = error.retryAfterSeconds
            if case .http(_, let server) = error, let server {
                code = server.code
            } else {
                code = "CLOUD_TRANSPORT_ERROR"
            }
            let message = Self.cloudFailureMessage(
                code: code,
                retryAfterSeconds: retryAfter
            )
            variant.variantStatus = .failed
            variant.errorCode = code
            variant.technicalDetails = message
            applyVariant(variant, to: video)
            video.sourceGenerationStep = nil
            video.sourceGenerationProgress = nil
            try? context.save()
            throw CloudSubtitleLookupError(message: message)
        } catch {
            variant.variantStatus = .failed
            variant.errorCode = "cloud_generation_failed"
            variant.technicalDetails = error.localizedDescription
            applyVariant(variant, to: video)
            video.sourceGenerationStep = nil
            video.sourceGenerationProgress = nil
            try? context.save()
            throw error
        }
    }

    /// Projects a cloud job update onto the video display fields. The stable
    /// key + content key captured at submit time must still match, so results
    /// from a previous video's job can never write into the current one.
    @MainActor
    private func applyCloudJobProjection(
        _ job: CloudContentJobResponse,
        expectedContentKey: String,
        expectedStableKey: String,
        video: YTVideoRecord,
        context: ModelContext
    ) throws {
        guard CloudVideoJobUpdateGuard.shouldApply(
            expectedContentKey: expectedContentKey,
            expectedStableKey: expectedStableKey,
            incomingContentKey: job.contentKey,
            incomingStableKey: job.stableKey
        ) else { throw CancellationError() }
        let projection = CloudYTProjectionPolicy.project(job)
        video.subtitleStatus = projection.subtitleStatus
        video.sourceGenerationStep = projection.sourceGenerationStep
        video.sourceGenerationProgress = projection.sourceGenerationProgress
        video.recordUpdatedAt = Date()
        try? context.save()
    }

    /// Marks the variant failed from a terminal cloud job, surfacing stable
    /// server codes (SOURCE_RESTRICTED, SOURCE_RATE_LIMITED,
    /// AUDIO_DOWNLOAD_FAILED, ...). Returns the error to throw.
    @MainActor
    private func markCloudJobFailed(
        _ error: CloudJobError?,
        fallbackCode: String? = nil,
        variant: TranslationVariantRecord,
        video: YTVideoRecord,
        context: ModelContext
    ) -> CloudSubtitleLookupError {
        let code = error?.code ?? fallbackCode ?? "INTERNAL_ERROR"
        let message = Self.cloudFailureMessage(
            code: code,
            retryAfterSeconds: error?.retryAfterSeconds
        )
        variant.variantStatus = .failed
        variant.errorCode = code
        variant.technicalDetails = message
        applyVariant(variant, to: video)
        video.sourceGenerationStep = nil
        video.sourceGenerationProgress = nil
        try? context.save()
        return CloudSubtitleLookupError(message: message)
    }

    /// Downloads the ready job's packaged artifacts (segments.json,
    /// source.vtt, target.vtt), verifies integrity against the manifest, and
    /// stores them via the existing YTSubtitleFileStore layout.
    @MainActor
    private func downloadAndStoreCloudArtifacts(
        _ job: CloudContentJobResponse,
        client: CloudContentJobClient,
        video: YTVideoRecord,
        target: TranslationTarget,
        variant: TranslationVariantRecord,
        taskGeneration: Int,
        expectedContentKey: String,
        context: ModelContext,
        onProgress: (@MainActor ([LearningSegment]) -> Void)?
    ) async throws -> [LearningSegment] {
        guard let manifest = job.artifacts, manifest.isCompatibleWithClient else {
            throw markCloudJobFailed(
                nil,
                fallbackCode: "PIPELINE_VERSION_UNSUPPORTED",
                variant: variant,
                video: video,
                context: context
            )
        }
        var refs: [String: CloudArtifactFileRef] = [:]
        for ref in manifest.files { refs[ref.name] = ref }

        let segmentsDownload = try await Self.fetchVerifiedCloudArtifact(
            client: client, jobID: job.jobId, name: "segments.json", ref: refs["segments.json"]
        )
        let sourceDownload = try await Self.fetchVerifiedCloudArtifact(
            client: client, jobID: job.jobId, name: "source.vtt", ref: refs["source.vtt"]
        )
        let targetDownload = try await Self.fetchVerifiedCloudArtifact(
            client: client, jobID: job.jobId, name: "target.vtt", ref: refs["target.vtt"]
        )
        let envelope: CloudSegmentsArtifactEnvelope
        do {
            envelope = try CloudSegmentsArtifactEnvelope.decode(from: segmentsDownload.data)
        } catch CloudSegmentsArtifactError.unsupportedSchemaVersion {
            throw markCloudJobFailed(
                nil,
                fallbackCode: "PIPELINE_VERSION_UNSUPPORTED",
                variant: variant,
                video: video,
                context: context
            )
        } catch {
            throw markCloudJobFailed(
                nil,
                fallbackCode: "ARTIFACT_PUBLISH_FAILED",
                variant: variant,
                video: video,
                context: context
            )
        }
        let sourceVTT = String(decoding: sourceDownload.data, as: UTF8.self)
        let targetVTT = String(decoding: targetDownload.data, as: UTF8.self)

        // Final write-time race guard: the generation pass and the job identity
        // must both still be the ones this call started with.
        try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
        guard CloudVideoJobUpdateGuard.shouldApply(
            expectedContentKey: expectedContentKey,
            expectedStableKey: job.stableKey,
            incomingContentKey: job.contentKey,
            incomingStableKey: job.stableKey
        ) else { throw CancellationError() }

        let files = try fileStore.files(videoID: video.id)
        let translationFiles = try fileStore.translationFiles(videoID: video.id, target: target)
        let segments = envelope.segments
        try fileStore.writeVTT(sourceVTT, to: files.englishVTT)
        try fileStore.writeSegments(sourceSegments(from: segments), to: files.baseSegments)
        try fileStore.writeSegments(segments, to: translationFiles.segments)
        try fileStore.writeVTT(targetVTT, to: translationFiles.targetVTT)

        video.enVTTPath = files.englishVTT.fileSystemPath
        video.sourceTranscriptMethod = "cloudASR"
        video.sourceGenerationStep = nil
        video.sourceGenerationProgress = nil
        variant.segmentsPath = translationFiles.segments.fileSystemPath
        variant.targetVTTPath = translationFiles.targetVTT.fileSystemPath
        variant.variantStatus = .ready
        variant.errorCode = nil
        variant.technicalDetails = nil
        updateSubtitleProgress(variant, translatedCount: segments.count, totalCount: segments.count)
        applyVariant(variant, to: video)
        try persistManifest(for: video, target: target, variant: variant, files: translationFiles)
        try context.save()
        try? await subtitleSync.publishReady(
            identity: .youtube(videoID: video.id, target: target),
            segments: segments,
            generatedAt: variant.updatedAt
        )
        onProgress?(segments)
        return segments
    }

    /// Fetches one artifact and verifies its SHA-256 against the manifest ref
    /// when present; a mismatch is surfaced as a publish-integrity failure.
    private static func fetchVerifiedCloudArtifact(
        client: CloudContentJobClient,
        jobID: String,
        name: String,
        ref: CloudArtifactFileRef?
    ) async throws -> CloudContentArtifactDownload {
        let download = try await client.fetchArtifact(jobID: jobID, fileName: name)
        if let ref, !download.data.isEmpty {
            let hexDigits = Array("0123456789abcdef")
            var digestHex = ""
            for byte in SHA256.hash(data: download.data) {
                digestHex.append(hexDigits[Int(byte >> 4)])
                digestHex.append(hexDigits[Int(byte & 0x0f)])
            }
            guard digestHex == ref.sha256 else {
                throw CloudSubtitleLookupError(
                    message: "Downloaded artifact failed integrity verification. [ARTIFACT_PUBLISH_FAILED]"
                )
            }
        }
        return download
    }

    /// User-facing message for a cloud failure. The stable server code is
    /// always appended in brackets so diagnostics show SOURCE_RESTRICTED /
    /// SOURCE_RATE_LIMITED / AUDIO_DOWNLOAD_FAILED style identifiers.
    static func cloudFailureMessage(
        code: String,
        retryAfterSeconds: Int?
    ) -> String {
        let base: String
        switch CloudErrorPresentationPolicy.category(forCode: code) {
        case .sourceRestricted:
            base = "The source platform restricts this video (region, age, or login)."
        case .rateLimited:
            if let retryAfterSeconds, retryAfterSeconds > 0 {
                base = "The source platform is rate limiting requests. Try again in \(retryAfterSeconds)s."
            } else {
                base = "The source platform is rate limiting requests. Try again later."
            }
        case .sourceGone:
            base = "This video is no longer available on the source platform."
        case .capacity:
            base = "The content service is at capacity. Try again later."
        case .retryableFailure:
            base = "Cloud subtitle generation failed; a retry may succeed."
        case .needsUpgrade:
            base = "Update the app to keep using the cloud content service."
        case .fatalFailure:
            base = "Cloud subtitle generation cannot process this video."
        case .unknown:
            base = "Cloud subtitle generation failed."
        }
        return "\(base) [\(code)]"
    }

    /// Whether caption failure is eligible for the iPhone audio-ASR fallback CTA.
    static func canGenerateFromAudio(after error: Error) -> Bool {
        #if os(iOS)
        guard let error = error as? YTCaptionError else { return false }
        switch error {
        case .missingEnglishTrack, .emptyCaptionFile, .emptyCaptionResponse,
             .captionQualityRejected, .rateLimited:
            return true
        default:
            return false
        }
        #else
        return false
        #endif
    }

    /// Download audio-only stream → DashScope ASR → base_segments → existing translate path.
    @MainActor
    func generateSubtitlesFromAudio(
        video: YTVideoRecord,
        configuration: AppConfiguration,
        context: ModelContext,
        streamResolver: YTYouTubeKitMediaStreamResolver = .shared,
        localMediaConfig: YTLocalMediaServiceConfig? = .fromProcessEnvironment(),
        onDownloadProgress: (@MainActor (Double?, Double?) -> Void)? = nil,
        onProgress: (@MainActor ([LearningSegment]) -> Void)? = nil
    ) async throws -> [LearningSegment] {
        #if os(tvOS)
        throw CloudSubtitleLookupError(
            message: L10n.string(
                "ytvideo_player.audio_asr_iphone_only",
                fallback: "Audio subtitle generation is only available on iPhone."
            )
        )
        #else
        let taskGeneration = Self.beginSubtitleTask(videoID: video.id)
        let target = configuration.translationTarget
        video.activeSubtitleTargetLanguage = target.rawValue
        let files = try fileStore.files(videoID: video.id)
        let variant = try TranslationVariantRepository.getOrCreate(
            contentKind: .youtubeVideo,
            contentID: video.id,
            target: target,
            context: context
        )
        video.sourceGenerationStep = nil
        video.sourceGenerationProgress = nil
        onDownloadProgress?(nil, nil)

        if let existing = existingSourceSegments(for: video, files: files), !existing.isEmpty {
            return try await translateSavedEnglishIfNeeded(
                video: video,
                sourceSegments: existing,
                target: target,
                taskGeneration: taskGeneration,
                variant: variant,
                configuration: configuration,
                context: context,
                resumeSavedTranslations: true,
                onProgress: onProgress
            )
        }

        guard configuration.hasDashScopeASRKey else {
            let message = L10n.string(
                "error.missing_asr_configuration",
                fallback: "Add a DashScope ASR API key in Settings first."
            )
            variant.variantStatus = .failed
            variant.errorCode = "missing_asr_configuration"
            variant.technicalDetails = message
            applyVariant(variant, to: video)
            try? context.save()
            throw CloudSubtitleLookupError(message: message)
        }
        guard configuration.hasTranslationKey
                || YTSubtitleCachePolicy.canGenerateLocallyWithoutTranslationKey(target: target)
        else {
            let message = L10n.string(
                "subtitles.waiting_for_iphone",
                fallback: "Subtitles will appear after they are generated on iPhone."
            )
            variant.variantStatus = .failed
            variant.errorCode = "missing_translation_configuration"
            variant.technicalDetails = message
            applyVariant(variant, to: video)
            try? context.save()
            throw CloudSubtitleLookupError(message: message)
        }

        variant.variantStatus = .running
        variant.errorCode = nil
        variant.technicalDetails = nil
        video.sourceTranscriptMethod = "audioASR"
        video.sourceGenerationStep = "resolving"
        video.sourceGenerationProgress = 0.05
        applyVariant(variant, to: video)
        try? context.save()

        do {
            try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
            let audioURL = try await resolveAndDownloadAudio(
                video: video,
                files: files,
                streamResolver: streamResolver,
                localMediaConfig: localMediaConfig,
                context: context,
                onDownloadProgress: onDownloadProgress
            )
            try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)

            video.sourceGenerationStep = "uploading"
            video.sourceGenerationProgress = 0.35
            try? context.save()

            let pipeline = LocalAudioASRPipeline()
            let segments = try await pipeline.transcribeAndSegment(
                audioURL: audioURL,
                apiKey: configuration.dashscopeAPIKey,
                checkpointURL: files.asrCheckpoint,
                downloadedResultURL: files.asrDownloadedResult
            ) { stage in
                switch stage {
                case .preparingUpload, .uploadingAudio:
                    video.sourceGenerationStep = "uploading"
                    video.sourceGenerationProgress = 0.4
                case .submitting, .polling:
                    video.sourceGenerationStep = "transcribing"
                    video.sourceGenerationProgress = 0.55
                case .downloadingResult, .parsingResult:
                    video.sourceGenerationStep = "segmenting"
                    video.sourceGenerationProgress = 0.65
                }
                try? context.save()
            }
            try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)

            video.sourceGenerationStep = "segmenting"
            video.sourceGenerationProgress = 0.7
            let englishVTT = YTVTTParser.makeVTT(from: YTVTTParser.sourceCues(from: segments))
            try fileStore.writeVTT(englishVTT, to: files.englishVTT)
            try fileStore.writeSegments(segments, to: files.baseSegments)
            video.enVTTPath = files.englishVTT.fileSystemPath
            video.sourceTranscriptMethod = "audioASR"
            // Delete source audio only after base segments are persisted.
            if let path = video.localAudioPath {
                try? FileManager.default.removeItem(at: URL.storedFileURL(from: path))
            }
            try? FileManager.default.removeItem(at: audioURL)
            video.localAudioPath = nil
            applyVariant(variant, to: video)
            try context.save()
            onProgress?(segments)

            video.sourceGenerationStep = "translating"
            video.sourceGenerationProgress = 0.75
            try? context.save()

            let translated = try await translateSavedEnglishIfNeeded(
                video: video,
                sourceSegments: segments,
                target: target,
                taskGeneration: taskGeneration,
                variant: variant,
                configuration: configuration,
                context: context,
                resumeSavedTranslations: false,
                onProgress: onProgress
            )
            video.sourceGenerationStep = nil
            video.sourceGenerationProgress = 1
            try? context.save()
            return translated
        } catch is CancellationError {
            video.sourceGenerationStep = nil
            video.sourceGenerationProgress = nil
            onDownloadProgress?(nil, nil)
            try? context.save()
            throw CancellationError()
        } catch {
            variant.variantStatus = .failed
            variant.errorCode = "audio_asr_failed"
            variant.technicalDetails = error.localizedDescription
            applyVariant(variant, to: video)
            video.sourceGenerationStep = nil
            video.sourceGenerationProgress = nil
            onDownloadProgress?(nil, nil)
            try? context.save()
            throw error
        }
        #endif
    }

    #if os(iOS)
    @MainActor
    private func resolveAndDownloadAudio(
        video: YTVideoRecord,
        files: YTSubtitleFiles,
        streamResolver: YTYouTubeKitMediaStreamResolver,
        localMediaConfig: YTLocalMediaServiceConfig?,
        context: ModelContext,
        onDownloadProgress: (@MainActor (Double?, Double?) -> Void)?
    ) async throws -> URL {
        if let path = video.localAudioPath {
            let existing = URL.storedFileURL(from: path)
            if FileManager.default.fileExists(atPath: existing.fileSystemPath) {
                return existing
            }
        }

        video.sourceGenerationStep = "resolving"
        video.sourceGenerationProgress = 0.1
        try? context.save()

        if let localMediaConfig {
            do {
                let client = YTLocalMediaServiceClient(config: localMediaConfig)
                let remoteURL = try await client.reusableAudioURL(
                    videoID: video.id,
                    mode: .mp4,
                    preferredHeight: localMediaConfig.preferredHeight
                )
                try Task.checkCancellation()
                let fileExtension = remoteURL.pathExtension.isEmpty
                    ? "m4a"
                    : remoteURL.pathExtension
                let destination = try await downloadAudioSource(
                    from: remoteURL,
                    fileExtension: fileExtension,
                    video: video,
                    files: files,
                    context: context,
                    onDownloadProgress: onDownloadProgress
                )
#if DEBUG
                print(
                    "YTLocalService: using local media service audio for \(video.id): \(remoteURL.absoluteString)"
                )
#endif
                return destination
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
#if DEBUG
                print(
                    "YTLocalService: local media audio unavailable for \(video.id), falling back to YouTubeKit: \(error.localizedDescription)"
                )
#endif
            }
        }

        var streams = try await streamResolver.resolve(videoID: video.id)
        if streams.isExpired {
            await streamResolver.invalidate(videoID: video.id)
            streams = try await streamResolver.resolve(videoID: video.id)
        }
        let audioCandidates = streams.audioOnly.filter {
            $0.container.lowercased() == "m4a" && $0.isNativelyPlayable
        }
        guard let audio = audioCandidates.max(by: {
            ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0)
        }) else {
            throw YTMediaStreamResolverError.noPlayableStream
        }

        return try await downloadAudioSource(
            from: audio.url,
            fileExtension: audio.container,
            video: video,
            files: files,
            context: context,
            onDownloadProgress: onDownloadProgress
        )
    }

    @MainActor
    private func downloadAudioSource(
        from remoteURL: URL,
        fileExtension: String,
        video: YTVideoRecord,
        files: YTSubtitleFiles,
        context: ModelContext,
        onDownloadProgress: (@MainActor (Double?, Double?) -> Void)?
    ) async throws -> URL {
        video.sourceGenerationStep = "downloading"
        video.sourceGenerationProgress = 0.2
        onDownloadProgress?(0, nil)
        try? context.save()

        let destination = files.sourceAudio(fileExtension: fileExtension)
        try await downloadRemoteFile(
            from: remoteURL,
            to: destination,
            onProgress: { completedBytes, expectedBytes, bytesPerSecond in
                let fraction = DownloadProgressMetrics.fraction(
                    completedBytes: completedBytes,
                    expectedBytes: expectedBytes
                )
                onDownloadProgress?(fraction, bytesPerSecond)
                if let fraction {
                    video.sourceGenerationProgress = 0.2 + fraction * 0.15
                }
            }
        )
        onDownloadProgress?(1, nil)
        video.localAudioPath = destination.fileSystemPath
        try? context.save()
        return destination
    }

    @MainActor
    private func downloadRemoteFile(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @MainActor (Int64, Int64, Double?) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.fileSystemPath) {
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 900
        let tempURL = destination
            .deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).session.\(UUID().uuidString)")
        let progressReporter = YTAudioDownloadProgressReporter(onProgress: onProgress)
        let downloader = AudioDownloadTask(tempURL: tempURL) { completedBytes, expectedBytes in
            Task { @MainActor in
                progressReporter.update(
                    completedBytes: completedBytes,
                    expectedBytes: expectedBytes
                )
            }
        }
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: tempURL)
        }
        let (downloadedURL, response) = try await downloader.download(request: request, session: session)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YTMediaStreamResolverError.extractionFailed("Audio download failed (HTTP \(http.statusCode)).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedURL, to: destination)
    }
    #endif

    @MainActor
    func retrySubtitles(
        video: YTVideoRecord,
        configuration: AppConfiguration,
        context: ModelContext,
        bypassCloudCheck: Bool = false,
        captionIngestionPolicy: YTCaptionIngestionPolicy = .strict,
        onProgress: (@MainActor ([LearningSegment]) -> Void)? = nil
    ) async throws -> [LearningSegment] {
        return try await ensureSubtitles(
            video: video,
            configuration: configuration,
            context: context,
            bypassCloudCheck: bypassCloudCheck,
            resumeCloudJob: true,
            captionIngestionPolicy: captionIngestionPolicy,
            onProgress: onProgress
        )
    }

    private func existingEnglishVTT(for video: YTVideoRecord, files: YTSubtitleFiles) -> String? {
        if let path = video.enVTTPath,
           let vtt = fileStore.readVTTIfExists(at: path),
           !YTVTTParser.parse(vtt).isEmpty {
            return vtt
        }
        if let vtt = fileStore.readVTTIfExists(at: files.englishVTT),
           !YTVTTParser.parse(vtt).isEmpty {
            return vtt
        }
        return nil
    }

    private func existingTranslatedVTT(
        variant: TranslationVariantRecord,
        files: TranslationVariantFiles
    ) -> String? {
        if let path = variant.targetVTTPath,
           let vtt = fileStore.readVTTIfExists(at: path),
           !YTVTTParser.parse(vtt).isEmpty {
            return vtt
        }
        if let vtt = fileStore.readVTTIfExists(at: files.targetVTT),
           !YTVTTParser.parse(vtt).isEmpty {
            return vtt
        }
        return nil
    }

    @MainActor
    private func translateSavedEnglishIfNeeded(
        video: YTVideoRecord,
        sourceSegments: [LearningSegment],
        target: TranslationTarget,
        taskGeneration: Int,
        variant: TranslationVariantRecord,
        configuration: AppConfiguration,
        context: ModelContext,
        resumeSavedTranslations: Bool,
        onProgress: (@MainActor ([LearningSegment]) -> Void)? = nil
    ) async throws -> [LearningSegment] {
        try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
        guard !sourceSegments.isEmpty else { throw YTCaptionError.emptyCaptionFile }
        let files = try fileStore.translationFiles(videoID: video.id, target: target)
        let cleanSourceSegments = sourceSegments.map { source -> LearningSegment in
            var copy = source
            copy.translation = ""
            return copy
        }
        var segments = resumableSegments(
            from: cleanSourceSegments,
            saved: resumeSavedTranslations ? savedSegments(variant: variant, files: files) : nil
        )
        if !resumeSavedTranslations {
            // Overwrite the old target artifact before generation. Otherwise a
            // failed v3 rebuild could leave a poisoned v2 VTT discoverable.
            try fileStore.writeVTT(YTVTTParser.makeVTT(from: []), to: files.targetVTT)
            variant.targetVTTPath = nil
        }
        try fileStore.writeSegments(segments, to: files.segments)
        variant.segmentsPath = files.segments.fileSystemPath
        updateSubtitleProgress(variant, segments: segments)
        applyVariant(variant, to: video)
        try? context.save()

        variant.variantStatus = .running
        applyVariant(variant, to: video)
        try? context.save()
        onProgress?(segments)

        if target == .simplifiedChinese { do {
            let youtubeChinese = try await captionService.fetchNativeChineseVTT(videoID: video.id)
            try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
            let youtubeZhCues = YTVTTParser.parse(youtubeChinese)
            if !youtubeZhCues.isEmpty {
                let alignment = YTVTTParser.alignNativeTranslations(from: youtubeZhCues, to: segments)
                if alignment.isAccepted {
                    print(
                        "YTLocalService: accepting native Chinese track for \(video.id), score=\(String(format: "%.2f", alignment.score))"
                    )
                    segments = alignment.segments
                    try fileStore.writeSegments(segments, to: files.segments)
                    // Persist a single-timeline translation VTT derived from English segment times.
                    try fileStore.writeVTT(
                        YTVTTParser.makeVTT(from: YTVTTParser.translatedCues(from: segments)),
                        to: files.targetVTT
                    )
                    updateSubtitleProgress(variant, segments: segments)
                    if YTSubtitleCachePolicy.savedTranslationsComplete(
                        segments,
                        expectedCueCount: segments.count
                    ) {
                        try await persistReadyTranslation(
                            segments,
                            video: video,
                            target: target,
                            variant: variant,
                            files: files,
                            configuration: configuration,
                            context: context,
                            onProgress: onProgress
                        )
                        return segments
                    }
                    // Gaps remain — fall through to LLM to fill missing translations.
                    onProgress?(segments)
                } else {
                    print(
                        "YTLocalService: rejecting native Chinese track for \(video.id), score=\(String(format: "%.2f", alignment.score)); using LLM"
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("YTLocalService: no native Chinese subtitles for \(video.id), falling back to LLM: \(error.localizedDescription)")
        } }

        do {
            _ = try await captionService.translateVTTIncrementally(
                from: segments,
                target: target,
                configuration: configuration
            ) { partialSegments, partialVTT in
                try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
                segments = partialSegments
                try fileStore.writeSegments(partialSegments, to: files.segments)
                try fileStore.writeVTT(partialVTT, to: files.targetVTT)
                variant.targetVTTPath = files.targetVTT.fileSystemPath
                variant.variantStatus = .running
                variant.errorCode = nil
                variant.technicalDetails = nil
                updateSubtitleProgress(variant, segments: partialSegments)
                applyVariant(variant, to: video)
                try persistManifest(for: video, target: target, variant: variant, files: files)
                try context.save()
                onProgress?(partialSegments)
            }
            try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
            guard YTSubtitleCachePolicy.savedTranslationsComplete(
                segments,
                expectedSequences: Set(sourceSegments.map(\.sequence))
            ) else {
                throw PipelineError.badResponse("Translation response did not cover every frozen subtitle sequence.")
            }
            try await persistReadyTranslation(
                segments,
                video: video,
                target: target,
                variant: variant,
                files: files,
                configuration: configuration,
                context: context,
                onProgress: onProgress
            )
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("YTLocalService: translation failed for \(video.id): \(error.localizedDescription)")
            if target == .simplifiedChinese {
                do {
                    let youtubeChinese = try await captionService.fetchAutoTranslatedChineseVTT(videoID: video.id)
                    try Self.checkSubtitleTask(videoID: video.id, generation: taskGeneration)
                    let alignment = YTVTTParser.alignNativeTranslations(
                        from: YTVTTParser.parse(youtubeChinese),
                        to: segments
                    )
                    if alignment.isAccepted,
                       YTSubtitleCachePolicy.savedTranslationsComplete(
                        alignment.segments,
                        expectedSequences: Set(sourceSegments.map(\.sequence))
                       ) {
                        print(
                            "YTLocalService: accepting YouTube auto-translation fallback for \(video.id), "
                                + "score=\(String(format: "%.2f", alignment.score))"
                        )
                        segments = alignment.segments
                        try await persistReadyTranslation(
                            segments,
                            video: video,
                            target: target,
                            variant: variant,
                            files: files,
                            configuration: configuration,
                            context: context,
                            onProgress: onProgress
                        )
                        return segments
                    }
                    print(
                        "YTLocalService: rejecting YouTube auto-translation fallback for \(video.id), "
                            + "score=\(String(format: "%.2f", alignment.score))"
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    print(
                        "YTLocalService: YouTube auto-translation fallback failed for \(video.id): "
                            + error.localizedDescription
                    )
                }
            }
            variant.variantStatus = (variant.translatedCount ?? 0) > 0 ? .partial : .failed
            variant.targetVTTPath = FileManager.default.fileExists(atPath: files.targetVTT.fileSystemPath)
                ? files.targetVTT.fileSystemPath
                : nil
            variant.errorCode = "translation_failed"
            variant.technicalDetails = error.localizedDescription
            applyVariant(variant, to: video)
            try? persistManifest(for: video, target: target, variant: variant, files: files)
            try? context.save()
            return segments
        }
    }

    @MainActor
    private func persistReadyTranslation(
        _ segments: [LearningSegment],
        video: YTVideoRecord,
        target: TranslationTarget,
        variant: TranslationVariantRecord,
        files: TranslationVariantFiles,
        configuration: AppConfiguration,
        context: ModelContext,
        onProgress: (@MainActor ([LearningSegment]) -> Void)?
    ) async throws {
        guard YTSubtitleCachePolicy.savedTranslationsComplete(
            segments,
            expectedCueCount: segments.count
        ) else {
            throw PipelineError.badResponse("Cannot publish incomplete subtitle translations.")
        }
        let sourceQuality = YTCaptionSegmentationQualityPolicy.report(
            for: sourceSegments(from: segments),
            outlierTolerancePercent: configuration.captionQualityOutlierTolerancePercent
        )
        guard sourceQuality.isAcceptable else {
            print(
                "YTLocalService: refusing to publish ready translation for \(video.id), "
                    + "tolerance=\(String(format: "%g", configuration.captionQualityOutlierTolerancePercent))%, "
                    + "reasons=\(sourceQuality.rejectionReasons.joined(separator: ","))"
            )
            throw PipelineError.badResponse("Cannot publish a fragmented or overlapping subtitle timeline.")
        }
        try fileStore.writeSegments(segments, to: files.segments)
        try fileStore.writeVTT(
            YTVTTParser.makeVTT(from: YTVTTParser.translatedCues(from: segments)),
            to: files.targetVTT
        )
        variant.targetVTTPath = files.targetVTT.fileSystemPath
        variant.variantStatus = .ready
        variant.errorCode = nil
        variant.technicalDetails = nil
        updateSubtitleProgress(variant, segments: segments)
        applyVariant(variant, to: video)
        try persistManifest(for: video, target: target, variant: variant, files: files)
        try context.save()
        try? await subtitleSync.publishReady(
            identity: .youtube(videoID: video.id, target: target),
            segments: segments,
            generatedAt: variant.updatedAt
        )
        onProgress?(segments)
    }

    @MainActor
    private func restoreReadyArtifact(
        _ envelope: SubtitleArtifactEnvelope,
        video: YTVideoRecord,
        target: TranslationTarget,
        variant: TranslationVariantRecord,
        files: YTSubtitleFiles,
        translationFiles: TranslationVariantFiles,
        context: ModelContext
    ) throws -> [LearningSegment] {
        let source = sourceSegments(from: envelope.segments)
        let englishCues = YTVTTParser.sourceCues(from: source)
        let translatedCues = YTVTTParser.translatedCues(from: envelope.segments)
        try fileStore.writeSegments(source, to: files.baseSegments)
        try fileStore.writeVTT(YTVTTParser.makeVTT(from: englishCues), to: files.englishVTT)
        try fileStore.writeSegments(envelope.segments, to: translationFiles.segments)
        try fileStore.writeVTT(YTVTTParser.makeVTT(from: translatedCues), to: translationFiles.targetVTT)

        video.enVTTPath = files.englishVTT.fileSystemPath
        variant.segmentsPath = translationFiles.segments.fileSystemPath
        variant.targetVTTPath = translationFiles.targetVTT.fileSystemPath
        variant.variantStatus = .ready
        variant.translatedCount = envelope.segments.count
        variant.totalCount = envelope.segments.count
        variant.errorCode = nil
        variant.technicalDetails = nil
        variant.updatedAt = envelope.generatedAt
        applyVariant(variant, to: video)
        try persistManifest(for: video, target: target, variant: variant, files: translationFiles)
        try context.save()
        return envelope.segments
    }

    @MainActor
    private func restoreSourceArtifact(
        _ envelope: SubtitleArtifactEnvelope,
        video: YTVideoRecord,
        files: YTSubtitleFiles,
        context: ModelContext
    ) throws -> [LearningSegment] {
        let source = sourceSegments(from: envelope.segments)
        let cues = YTVTTParser.sourceCues(from: source)
        try fileStore.writeSegments(source, to: files.baseSegments)
        try fileStore.writeVTT(YTVTTParser.makeVTT(from: cues), to: files.englishVTT)
        video.enVTTPath = files.englishVTT.fileSystemPath
        try context.save()
        return source
    }

    private func existingSourceSegments(for video: YTVideoRecord, files: YTSubtitleFiles) -> [LearningSegment]? {
        if let base = baseSourceSegments(videoID: video.id), !base.isEmpty {
            return base
        }
        guard let enVTT = existingEnglishVTT(for: video, files: files) else { return nil }
        let cues = YTVTTParser.parse(enVTT)
        guard !cues.isEmpty else { return nil }
        return YTVTTParser.learningSegments(from: cues)
    }

    /// Reuse gate for saved local/cloud English sources. Strict modes re-validate the
    /// timeline so a low-quality track accepted under the lenient iframe policy is never
    /// reused; the lenient policy keeps its "non-empty parseable" acceptance.
    private func acceptsReusedSourceSegments(
        _ segments: [LearningSegment],
        policy: YTCaptionIngestionPolicy,
        configuration: AppConfiguration
    ) -> Bool {
        guard policy == .strict else { return true }
        let quality = YTCaptionSegmentationQualityPolicy.report(
            for: segments,
            outlierTolerancePercent: configuration.captionQualityOutlierTolerancePercent
        )
        if !quality.isAcceptable {
            print(
                "YTLocalService: discarding low-quality reused source, "
                    + "reasons=\(quality.rejectionReasons.joined(separator: ","))"
            )
        }
        return quality.isAcceptable
    }

    private func sourceSegments(from segments: [LearningSegment]) -> [LearningSegment] {
        segments.map { segment in
            var source = segment
            source.translation = ""
            return source
        }
    }

    private func persistManifest(
        for video: YTVideoRecord,
        target: TranslationTarget,
        variant: TranslationVariantRecord,
        files: TranslationVariantFiles
    ) throws {
        var artifacts = ["segments": files.segments.fileSystemPath]
        if FileManager.default.fileExists(atPath: files.targetVTT.fileSystemPath) {
            artifacts["target_vtt"] = files.targetVTT.fileSystemPath
        }
        let segments = savedSegments(variant: variant, files: files) ?? []
        try fileStore.writeManifest(
            TranslationArtifactManifest(
                contentKind: TranslationContentKind.youtubeVideo.rawValue,
                contentID: video.id,
                targetLanguage: target.rawValue,
                status: variant.variantStatus.rawValue,
                updatedAt: variant.updatedAt,
                artifacts: artifacts,
                sourceFingerprint: segments.isEmpty
                    ? nil
                    : TranscriptionFingerprint.make(segments: segments),
                pipelineVersion: SubtitlePipelineVersion.current
            ),
            to: files.manifest
        )
    }

    private static func beginSubtitleTask(videoID: String) -> Int {
        let generation = (subtitleTaskGenerations[videoID] ?? 0) + 1
        subtitleTaskGenerations[videoID] = generation
        return generation
    }

    private static func cancelSubtitleTasks(videoID: String) {
        subtitleTaskGenerations[videoID] = (subtitleTaskGenerations[videoID] ?? 0) + 1
    }

    private static func checkSubtitleTask(videoID: String, generation: Int) throws {
        guard subtitleTaskGenerations[videoID] == generation else { throw CancellationError() }
    }

    private func updateSubtitleProgress(_ variant: TranslationVariantRecord, segments: [LearningSegment]) {
        let progress = YTSubtitleTranslationProgress(segments: segments)
        updateSubtitleProgress(
            variant,
            translatedCount: progress.translatedCount,
            totalCount: progress.totalCount
        )
    }

    private func updateSubtitleProgress(_ variant: TranslationVariantRecord, translatedCount: Int, totalCount: Int) {
        variant.translatedCount = translatedCount
        variant.totalCount = totalCount
        variant.updatedAt = Date()
    }

    private func savedSegments(variant: TranslationVariantRecord, files: TranslationVariantFiles) -> [LearningSegment]? {
        if let segmentsPath = variant.segmentsPath,
           let savedSegments = try? fileStore.readSegments(at: segmentsPath),
           !savedSegments.isEmpty {
            return savedSegments
        }
        if let savedSegments = fileStore.readSegmentsIfExists(at: files.segments),
           !savedSegments.isEmpty {
            return savedSegments
        }
        return nil
    }

    private func resumableSegments(
        from source: [LearningSegment],
        saved: [LearningSegment]?
    ) -> [LearningSegment] {
        guard let saved, !saved.isEmpty else { return source }
        return TranslationResultMerger.mergeSavedTranslations(saved: saved, onto: source)
    }

    private func baseSourceSegments(videoID: String) -> [LearningSegment]? {
        guard let files = try? fileStore.files(videoID: videoID),
              let segments = fileStore.readSegmentsIfExists(at: files.baseSegments),
              !segments.isEmpty
        else { return nil }
        return segments
    }

    private func translationIsComplete(
        variant: TranslationVariantRecord,
        files: TranslationVariantFiles,
        englishCues: [YTCue],
        translatedCues: [YTCue]
    ) -> Bool {
        YTSubtitleCachePolicy.hasPlayableDualSubtitles(
            englishCues: englishCues,
            chineseCues: translatedCues,
            savedSegments: savedSegments(variant: variant, files: files)
        )
    }

    private func applyVariant(_ variant: TranslationVariantRecord, to video: YTVideoRecord) {
        guard video.activeSubtitleTargetLanguage == variant.targetLanguage else { return }
        switch variant.variantStatus {
        case .notRequested: video.subtitleStatus = "not_requested"
        case .running: video.subtitleStatus = "translating"
        case .partial: video.subtitleStatus = "partial"
        case .ready: video.subtitleStatus = "ready"
        case .failed: video.subtitleStatus = "failed"
        }
        video.subtitleTranslatedCount = variant.translatedCount
        video.subtitleTotalCount = variant.totalCount
        video.segmentsPath = variant.segmentsPath
        video.zhVTTPath = variant.targetVTTPath
        video.lastError = variant.technicalDetails
        video.recordUpdatedAt = variant.updatedAt
    }

    @MainActor
    private func rekeyChannel(
        _ channel: YTChannelRecord,
        oldID: String,
        resolved: YouTubeDataAPIResolvedChannel,
        context: ModelContext
    ) throws {
        channel.id = resolved.channel.id
        channel.channelID = resolved.channel.id
        channel.url = resolved.url
        channel.uploadsPlaylistID = resolved.channel.uploadsPlaylistID
        if channel.displayName == oldID || channel.displayName.isEmpty {
            channel.displayName = resolved.channel.title
        }
        channel.videoCount = resolved.channel.videoCount ?? channel.videoCount
        channel.lastError = nil
        channel.updatedAt = Date()

        let descriptor = FetchDescriptor<YTVideoRecord>(
            predicate: #Predicate<YTVideoRecord> { $0.channelRecordID == oldID }
        )
        for video in try context.fetch(descriptor) {
            video.channelRecordID = resolved.channel.id
            video.channelID = resolved.channel.id
        }
        try context.save()
        CloudSyncCoordinator.shared.deleteYouTube(channelID: oldID, modifiedAt: channel.updatedAt)
        CloudSyncCoordinator.shared.upsertYouTube(channel, modifiedAt: channel.updatedAt)
    }

    private func repairCandidates(for channel: YTChannelRecord) -> [String] {
        var values: [String] = []
        for value in [channel.url, channel.channelID, channel.displayName] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            values.append(trimmed)
            if !trimmed.hasPrefix("@"),
               !trimmed.contains("/"),
               !trimmed.contains("."),
               trimmed.range(of: #"\s"#, options: .regularExpression) == nil {
                values.append("@\(trimmed)")
            }
        }
        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    func youtubeAPIKey(from configuration: AppConfiguration) throws -> String {
        let key = configuration.youtubeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw YTLocalServiceError.missingYouTubeAPIKey }
        return key
    }

    /// Fetches trimmed video details by ID for CloudSyncKit targeted recovery.
    /// Channel-ownership validation is the caller's responsibility.
    func fetchVideoDetailsByIDs(
        _ videoIDs: Set<String>,
        configuration: AppConfiguration
    ) async throws -> [String: YouTubeVideoDetails] {
        let apiKey = try youtubeAPIKey(from: configuration)
        let feedVideos = try await youtubeAPIClient.fetchVideoDetailsByIDs(Array(videoIDs), apiKey: apiKey)
        var result: [String: YouTubeVideoDetails] = [:]
        for video in feedVideos {
            guard let channelID = video.channelID, !channelID.isEmpty else { continue }
            result[video.id] = YouTubeVideoDetails(
                videoID: video.id,
                channelID: channelID,
                title: video.title,
                playbackURL: video.url,
                thumbnailURL: video.thumbnail,
                publishedAt: video.publishedAt
            )
        }
        return result
    }

    @MainActor
    private func repairChannelIDIfNeeded(_ channel: YTChannelRecord, apiKey: String, context: ModelContext) async throws {
        if YTChannelResolver.isValidChannelID(channel.channelID),
           channel.uploadsPlaylistID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return
        }
        let oldID = channel.id
        let candidates = repairCandidates(for: channel)

        for candidate in candidates {
            do {
                let resolved = try await youtubeAPIClient.resolveChannel(input: candidate, apiKey: apiKey)
                try rekeyChannel(channel, oldID: oldID, resolved: resolved, context: context)
                return
            } catch {
                continue
            }
        }

        if YTChannelResolver.isValidChannelID(channel.channelID) {
            let resolved = try await youtubeAPIClient.resolveChannel(input: channel.channelID, apiKey: apiKey)
            try rekeyChannel(channel, oldID: oldID, resolved: resolved, context: context)
            return
        }
        throw YTLocalServiceError.unresolvedChannelID
    }

    private func fetchInitialVideosPage(_ channel: YTChannelRecord, apiKey: String) async throws -> YTChannelVideosPage {
        guard let uploadsPlaylistID = channel.uploadsPlaylistID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uploadsPlaylistID.isEmpty
        else {
            throw YTLocalServiceError.unresolvedChannelID
        }
        return try await youtubeAPIClient.fetchUploadsPage(
            uploadsPlaylistID: uploadsPlaylistID,
            channelID: channel.channelID,
            channelTitle: channel.displayName,
            pageToken: nil,
            apiKey: apiKey
        )
    }

    private func fetchVideosContinuation(
        _ channel: YTChannelRecord,
        continuation: String,
        apiKey: String
    ) async throws -> YTChannelVideosPage {
        guard let uploadsPlaylistID = channel.uploadsPlaylistID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uploadsPlaylistID.isEmpty
        else {
            throw YTLocalServiceError.unresolvedChannelID
        }
        return try await youtubeAPIClient.fetchUploadsPage(
            uploadsPlaylistID: uploadsPlaylistID,
            channelID: channel.channelID,
            channelTitle: channel.displayName,
            pageToken: continuation,
            apiKey: apiKey
        )
    }

    private func upsert(
        feed: YTFeed,
        for channel: YTChannelRecord,
        context: ModelContext,
        updateLastVideoID: Bool = true
    ) throws {
        for item in feed.videos {
            let videoID = item.id
            if let existing = try fetchVideo(id: videoID, context: context) {
                existing.channelRecordID = channel.id
                existing.channelID = item.channelID ?? channel.channelID
                existing.title = item.title
                existing.publishedAt = item.publishedAt
                existing.updatedAt = item.updatedAt
                existing.url = item.url
                existing.thumbnail = item.thumbnail
                existing.recordUpdatedAt = Date()
            } else {
                context.insert(
                    YTVideoRecord(
                        id: item.id,
                        channelRecordID: channel.id,
                        channelID: item.channelID ?? channel.channelID,
                        title: item.title,
                        publishedAt: item.publishedAt,
                        updatedAt: item.updatedAt,
                        url: item.url,
                        thumbnail: item.thumbnail
                    )
                )
            }
        }
        channel.videoCount = max(feed.videos.count, try countVideos(channelID: channel.id, context: context))
        if updateLastVideoID {
            channel.lastVideoID = feed.videos.first?.id
        }
    }

    private func fetchChannel(id: String, context: ModelContext) throws -> YTChannelRecord? {
        var descriptor = FetchDescriptor<YTChannelRecord>(
            predicate: #Predicate<YTChannelRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchVideo(id: String, context: ModelContext) throws -> YTVideoRecord? {
        var descriptor = FetchDescriptor<YTVideoRecord>(
            predicate: #Predicate<YTVideoRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func countVideos(channelID: String, context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<YTVideoRecord>(
            predicate: #Predicate<YTVideoRecord> { $0.channelRecordID == channelID }
        )
        return try context.fetchCount(descriptor)
    }
}

#if os(iOS)
@MainActor
private final class YTAudioDownloadProgressReporter: @unchecked Sendable {
    private let onProgress: @MainActor (Int64, Int64, Double?) -> Void
    private var previousBytes: Int64 = 0
    private var previousDate = Date()
    private var smoothedBytesPerSecond: Double?

    init(onProgress: @escaping @MainActor (Int64, Int64, Double?) -> Void) {
        self.onProgress = onProgress
    }

    func update(completedBytes: Int64, expectedBytes: Int64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(previousDate)
        let bytesDelta = completedBytes - previousBytes

        if elapsed >= 0.2,
           let sample = DownloadProgressMetrics.bytesPerSecond(
               bytesDelta: bytesDelta,
               elapsedSeconds: elapsed
           ) {
            smoothedBytesPerSecond = DownloadProgressMetrics.smoothedBytesPerSecond(
                previous: smoothedBytesPerSecond,
                sample: sample
            )
            previousBytes = completedBytes
            previousDate = now
        }

        onProgress(completedBytes, expectedBytes, smoothedBytesPerSecond)
    }
}
#endif

private struct YouTubeDataAPIResolvedChannel {
    var channel: YouTubeDataAPIChannel
    var url: String
}

private final class YouTubeDataAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolveChannel(input: String, apiKey: String) async throws -> YouTubeDataAPIResolvedChannel {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw YTLocalServiceError.invalidChannelURL }

        if let id = YTChannelResolver.channelID(from: trimmed) {
            let channel = try await fetchChannel(filter: .id(id), apiKey: apiKey)
            return YouTubeDataAPIResolvedChannel(channel: channel, url: YTChannelResolver.normalizedChannelURL(channelID: channel.id))
        }
        if trimmed.hasPrefix("@") {
            let channel = try await fetchChannel(filter: .handle(trimmed), apiKey: apiKey)
            return YouTubeDataAPIResolvedChannel(channel: channel, url: YTChannelResolver.normalizedChannelURL(channelID: channel.id))
        }
        if let url = YTChannelResolver.normalizedInputURL(trimmed) {
            if let id = YTChannelResolver.channelID(fromRSSURL: url) {
                let channel = try await fetchChannel(filter: .id(id), apiKey: apiKey)
                return YouTubeDataAPIResolvedChannel(channel: channel, url: YTChannelResolver.normalizedChannelURL(channelID: channel.id))
            }
            let pathParts = url.pathComponents.filter { $0 != "/" }
            if let channelIndex = pathParts.firstIndex(of: "channel"),
               pathParts.indices.contains(channelIndex + 1),
               YTChannelResolver.isValidChannelID(pathParts[channelIndex + 1]) {
                let channel = try await fetchChannel(filter: .id(pathParts[channelIndex + 1]), apiKey: apiKey)
                return YouTubeDataAPIResolvedChannel(channel: channel, url: YTChannelResolver.normalizedChannelURL(channelID: channel.id))
            }
            if let handle = pathParts.first(where: { $0.hasPrefix("@") }) {
                let channel = try await fetchChannel(filter: .handle(handle), apiKey: apiKey)
                return YouTubeDataAPIResolvedChannel(channel: channel, url: YTChannelResolver.normalizedChannelURL(channelID: channel.id))
            }
            if let userIndex = pathParts.firstIndex(of: "user"),
               pathParts.indices.contains(userIndex + 1),
               !pathParts[userIndex + 1].isEmpty {
                let channel = try await fetchChannel(filter: .username(pathParts[userIndex + 1]), apiKey: apiKey)
                return YouTubeDataAPIResolvedChannel(channel: channel, url: YTChannelResolver.normalizedChannelURL(channelID: channel.id))
            }
            throw YTLocalServiceError.unsupportedChannelInput
        }

        let channel = try await fetchChannel(filter: .handle(trimmed), apiKey: apiKey)
        return YouTubeDataAPIResolvedChannel(channel: channel, url: YTChannelResolver.normalizedChannelURL(channelID: channel.id))
    }

    func fetchUploadsPage(
        uploadsPlaylistID: String,
        channelID: String,
        channelTitle: String,
        pageToken: String?,
        apiKey: String
    ) async throws -> YTChannelVideosPage {
        let data = try await get(
            endpoint: "playlistItems",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet,contentDetails,status"),
                URLQueryItem(name: "playlistId", value: uploadsPlaylistID),
                URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "pageToken", value: pageToken)
            ],
            apiKey: apiKey,
            operation: "YouTube uploads playlist"
        )
        let page = try YouTubeDataAPIParser.parsePlaylistItemsPage(
            data: data,
            fallbackChannelID: channelID,
            channelTitle: channelTitle
        )
        guard !page.feed.videos.isEmpty else { return page }
        return try await pageWithVideoDetails(page, apiKey: apiKey)
    }

    private func pageWithVideoDetails(_ page: YTChannelVideosPage, apiKey: String) async throws -> YTChannelVideosPage {
        let ids = page.feed.videos.map(\.id).joined(separator: ",")
        let data = try await get(
            endpoint: "videos",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "id", value: ids)
            ],
            apiKey: apiKey,
            operation: "YouTube video metadata"
        )
        return try YouTubeDataAPIParser.mergingVideoDetails(page: page, data: data)
    }

    /// Fetches video details by ID in a single `videos.list` request.
    /// Used only for continue-playing catalog recovery: no channel refresh, no uploads scan.
    func fetchVideoDetailsByIDs(_ videoIDs: [String], apiKey: String) async throws -> [YTFeedVideo] {
        let ids = videoIDs.joined(separator: ",")
        let data = try await get(
            endpoint: "videos",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "id", value: ids),
                URLQueryItem(name: "maxResults", value: "50")
            ],
            apiKey: apiKey,
            operation: "YouTube video details"
        )
        return try YouTubeDataAPIParser.parseVideoDetailsList(data: data)
    }

    private func fetchChannel(filter: ChannelFilter, apiKey: String) async throws -> YouTubeDataAPIChannel {
        var items = [
            URLQueryItem(name: "part", value: "snippet,contentDetails,statistics")
        ]
        items.append(filter.queryItem)
        let data = try await get(
            endpoint: "channels",
            queryItems: items,
            apiKey: apiKey,
            operation: "YouTube channel resolution"
        )
        guard let channel = try YouTubeDataAPIParser.parseChannelList(data: data) else {
            throw YouTubeDataAPIError(code: 404, reason: "channelNotFound", message: "Channel not found.")
        }
        return channel
    }

    private func get(endpoint: String, queryItems: [URLQueryItem], apiKey: String, operation: String) async throws -> Data {
        guard var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(endpoint)") else {
            throw YTLocalServiceError.invalidChannelURL
        }
        components.queryItems = queryItems.filter { item in
            item.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } + [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw YTLocalServiceError.invalidChannelURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        YouTubeDataAPIRequestPolicy.applyIOSRestrictionHeaders(
            to: &request,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        let (data, response) = try await withNetworkRetries(operation: operation) {
            try await self.session.data(for: request)
        }
        try validateYouTubeDataHTTP(response, data: data, context: operation)
        return data
    }

    private enum ChannelFilter {
        case id(String)
        case handle(String)
        case username(String)

        var queryItem: URLQueryItem {
            switch self {
            case .id(let value):
                URLQueryItem(name: "id", value: value)
            case .handle(let value):
                URLQueryItem(name: "forHandle", value: value)
            case .username(let value):
                URLQueryItem(name: "forUsername", value: value)
            }
        }
    }
}

private func validateYouTubeDataHTTP(_ response: URLResponse, data: Data, context: String) throws {
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
        if let apiError = YouTubeDataAPIParser.apiError(from: data) {
            throw apiError
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw PipelineError.badResponse("\(context) failed (HTTP \(status)): \(String((detail ?? "").prefix(240)))")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Cloud job persistence (V10 / WP13)

/// CloudContentJobPersisting backed by SwiftData RemoteContentJobRecord. A
/// fresh ModelContext is created per call so the coordinator can upsert from
/// any executor. Until the app schema registers RemoteContentJobRecord
/// (WP11/WP14 wiring), the store degrades to in-memory tracking so cloud
/// generation keeps working; the job itself is still recoverable because the
/// server-side create is idempotent.
actor YTRemoteContentJobStore: CloudContentJobPersisting {
    private static let terminalStatuses: Set<String> = ["ready", "failed", "cancelled", "expired"]

    private let serviceURL: String
    private let container: ModelContainer?
    private var memory: [String: RemoteContentJobSnapshot] = [:]

    init(context: ModelContext, serviceURL: String) {
        self.serviceURL = serviceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let container = context.container
        if container.schema.entities.contains(where: { $0.name == "RemoteContentJobRecord" }) {
            self.container = container
        } else {
            self.container = nil
        }
    }

    func upsert(_ job: CloudContentJobResponse) async throws {
        guard let container else {
            memory[job.stableKey] = RemoteContentJobSnapshot(
                stableKey: job.stableKey,
                jobID: job.jobId,
                statusRaw: job.status.rawValue,
                isTerminal: job.status.isTerminal
            )
            return
        }
        let context = ModelContext(container)
        let key = serviceURL + "|" + job.sourceLanguage + "|" + job.stableKey
        var descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate { $0.stableKey == key }
        )
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.apply(job)
        } else {
            let record = RemoteContentJobRecord(
                stableKey: key,
                contentKind: job.contentType.rawValue,
                contentKey: job.contentKey,
                jobID: job.jobId,
                statusRaw: job.status.rawValue,
                targetLanguage: job.targetLanguage,
                translationQuality: job.translationQuality.rawValue,
                pipelineVersion: job.pipelineVersion
            )
            record.apply(job)
            context.insert(record)
        }
        try context.save()
    }

    func latestJobID(for request: CloudContentJobCreateRequest) async throws -> String? {
        guard let container else { return nil }
        let context = ModelContext(container)
        let prefix = serviceURL + "|" + request.sourceLanguage + "|"
        return try context.fetch(FetchDescriptor<RemoteContentJobRecord>())
            .filter { $0.stableKey.hasPrefix(prefix) && $0.contentKind == request.contentType.rawValue
                && $0.contentKey == request.contentKey && $0.targetLanguage == request.targetLanguage
                && $0.translationQuality == request.translationQuality.rawValue }
            .max { $0.updatedAt < $1.updatedAt }?.jobID
    }

    func snapshot(forStableKey key: String) async throws -> RemoteContentJobSnapshot? {
        guard let container else { return memory[key] }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate { $0.stableKey == key }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return Self.snapshot(of: record)
    }

    func nonTerminalSnapshots() async throws -> [RemoteContentJobSnapshot] {
        guard let container else {
            return memory.values.filter { !$0.isTerminal }
        }
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<RemoteContentJobRecord>())
            .filter { !Self.terminalStatuses.contains($0.statusRaw) }
            .map(Self.snapshot(of:))
    }

    private static func snapshot(of record: RemoteContentJobRecord) -> RemoteContentJobSnapshot {
        RemoteContentJobSnapshot(
            stableKey: record.stableKey,
            jobID: record.jobID,
            statusRaw: record.statusRaw,
            isTerminal: terminalStatuses.contains(record.statusRaw)
        )
    }
}
