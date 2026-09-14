import Foundation
import Observation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

struct PipelineManifest: Codable {
    var episodeID: String
    var status: String
    var currentStep: String
    var updatedAt: Date
    var error: String?
    var artifacts: [String: String]
}

struct TranslationArtifactManifest: Codable {
    var schemaVersion: Int = 1
    var contentKind: String
    var contentID: String
    var targetLanguage: String
    var status: String
    var updatedAt: Date
    var artifacts: [String: String]
    /// Fingerprint of the English transcription these translations were generated against.
    var sourceFingerprint: String? = nil
    /// Local subtitle pipeline version; mismatch means open-to-rebuild.
    var pipelineVersion: Int? = nil
    /// Background display sub-clause refinement. Absent on older ready manifests → completed.
    var displayRefinementStatus: String? = nil
    var displayRefinementCompletedCount: Int? = nil
    var displayRefinementTotalCount: Int? = nil
}

@MainActor
@Observable
final class PipelineRunner {
    var isRunning = false
    var lastMessage = ""

    @ObservationIgnored private let feedService = PodcastFeedService()
    @ObservationIgnored private let fileStore = LocalFileStore()
    @ObservationIgnored private let ossClient = AliyunOSSClient()
    @ObservationIgnored private let transcriptionClient = DashScopeTranscriptionClient()
    @ObservationIgnored private let translationClient = TranslationClient()
    @ObservationIgnored private let displayRefiner: SubtitleDisplayRefiner
    @ObservationIgnored private let subtitleSync: SubtitleArtifactSyncing
    @ObservationIgnored private let completionReconciler: PodcastCompletionReconciler
    /// Cloud content job client factory (V10 / WP11); injectable for tests.
    @ObservationIgnored private let cloudClientProvider: (AppConfiguration) -> CloudContentJobClient?
    /// Remote job record store factory; injectable so tests stay in-memory.
    @ObservationIgnored private let remoteJobStoreProvider: () throws -> RemoteContentJobStore
    @ObservationIgnored private let audioFileLock = NSLock()
    @ObservationIgnored private var runningTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var taskGenerations: [String: Int] = [:]
    @ObservationIgnored private var runningVariantIDs: Set<String> = []
    @ObservationIgnored private var refreshingSubscriptionIDs: Set<String> = []

    init(
        subtitleSync: SubtitleArtifactSyncing? = nil,
        completionReconciler: PodcastCompletionReconciler? = nil,
        cloudClientProvider: ((AppConfiguration) -> CloudContentJobClient?)? = nil,
        remoteJobStoreProvider: (() throws -> RemoteContentJobStore)? = nil
    ) {
        let sync = subtitleSync ?? CloudSyncCoordinator.shared
        self.subtitleSync = sync
        self.completionReconciler = completionReconciler ?? PodcastCompletionReconciler()
        self.displayRefiner = SubtitleDisplayRefiner(subtitleSync: sync)
        self.cloudClientProvider = cloudClientProvider ?? {
            CloudContentGatewayFactory.makeClient(configuration: $0)
        }
        self.remoteJobStoreProvider = remoteJobStoreProvider ?? { try RemoteContentJobStore() }
    }

    /// Repairs episodes stuck in a persisted `running` state whose translation already
    /// finished on disk. Runs at launch and on foreground re-entry; read-only apart
    /// from promoting genuinely complete episodes (never re-invokes translation).
    @discardableResult
    func reconcileCompletions(context: ModelContext) -> Int {
        completionReconciler.reconcileRunningEpisodes(context: context)
    }

    /// Re-schedules persisted `running` episodes that have no in-memory pipeline task
    /// (orphans left by force-quit / crash mid-download or ASR). Call after
    /// `reconcileCompletions` so fully-translated orphans are promoted first.
    @discardableResult
    func resumeOrphanedPipelines(
        context: ModelContext,
        configuration: AppConfiguration
    ) -> Int {
        let running = (try? context.fetch(FetchDescriptor<EpisodeRecord>(
            predicate: #Predicate { $0.status == "running" }
        ))) ?? []
        var resumed = 0
        let target = configuration.translationTarget
        for episode in running {
            let taskID = episodeTaskID(episodeID: episode.id, target: target)
            let hasTask = runningTasks[taskID] != nil
            guard PodcastOrphanedPipelinePolicy.shouldResume(
                status: episode.status,
                hasInMemoryTask: hasTask
            ) else { continue }
            if configuration.generationBackendMode == .local,
               episode.pipelineStep == "transcribe",
               let files = try? fileStore.episodeFiles(episodeID: episode.id),
               !FileManager.default.fileExists(atPath: files.rawTranscription.fileSystemPath),
               !FileManager.default.fileExists(atPath: files.asrCheckpoint.fileSystemPath) {
                fail(
                    episode,
                    target: target,
                    context: context,
                    message: L10n.string(
                        "error.asr_resume_data_missing",
                        fallback: "The previous transcription cannot be resumed because its task information was not saved. Tap Retry to start it again."
                    )
                )
                continue
            }
            schedule(
                episode: episode,
                context: context,
                configuration: configuration,
                bypassCloudCheck: shouldBypassCloudCheckWhenResuming(
                    episodeID: episode.id,
                    target: target
                )
            )
            resumed += 1
        }
        // Cloud mode: resume/adopt remote jobs persisted before the last quit and
        // reconcile any non-terminal records whose episodes are not `running`
        // (e.g. quit right after submit, while the job was still queued).
        if configuration.generationBackendMode == .cloud {
            Task { [weak self] in
                await self?.reconcileRemoteJobs(context: context, configuration: configuration)
            }
        }
        return resumed
    }

    private func shouldBypassCloudCheckWhenResuming(
        episodeID: String,
        target: TranslationTarget
    ) -> Bool {
        guard let episodeFiles = try? fileStore.episodeFiles(episodeID: episodeID),
              let rawSegments = try? fileStore.readJSON(
                [LearningSegment].self,
                from: episodeFiles.rawTranscription
              ),
              !rawSegments.isEmpty
        else { return false }

        let translatedSegments: [LearningSegment]
        if let translationFiles = try? fileStore.translationFiles(
            episodeID: episodeID,
            target: target
        ) {
            translatedSegments = (try? fileStore.readJSON(
                [LearningSegment].self,
                from: translationFiles.segments
            )) ?? []
        } else {
            translatedSegments = []
        }
        let translatedCount = translatedSegments.filter {
            !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return PodcastTranslationAutoResumePolicy.shouldBypassCloudCheck(
            hasLocalSource: true,
            translatedCount: translatedCount,
            totalCount: rawSegments.count
        )
    }

    /// Clears transcription/translation artifacts (keeps `source.mp3` and the catalog row),
    /// resets status to `queued`, then immediately re-schedules the pipeline.
    func clearAndRegenerate(
        episode: EpisodeRecord,
        context: ModelContext,
        configuration: AppConfiguration
    ) async {
        await cancelAndWait(episodeID: episode.id)
        let episodeID = episode.id
        // Cloud mode: cancel the remote jobs WITHOUT purging shared source
        // artifacts, then drop the local records so the re-schedule below
        // submits fresh (a new pipeline version server-side).
        if configuration.generationBackendMode == .cloud,
           let client = cloudClientProvider(configuration),
           let store = try? remoteJobStoreProvider() {
            let subscription = fetchSubscription(for: episode, context: context)
            let contentKey = cloudContentKey(episode: episode, subscription: subscription)
            for record in store.records(contentKey: contentKey) {
                _ = try? await client.cancelJob(jobID: record.jobID, purgeArtifacts: false)
            }
            store.deleteRecords(contentKey: contentKey)
        }
        try? TranslationVariantRepository.deleteAll(
            contentKind: .podcastEpisode,
            contentID: episodeID,
            context: context
        )
        let segmentDescriptor = FetchDescriptor<SegmentRecord>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        for item in (try? context.fetch(segmentDescriptor)) ?? [] {
            context.delete(item)
        }
        try? fileStore.clearGenerationArtifacts(episodeID: episodeID)
        episode.status = "queued"
        episode.pipelineStep = "queued"
        episode.pipelineProgress = nil
        episode.pipelineMessage = nil
        episode.errorMessage = nil
        episode.activeTranslationTargetLanguage = nil
        episode.updatedAt = Date()
        if let files = try? fileStore.episodeFiles(episodeID: episodeID) {
            try? fileStore.writeJSON(
                PipelineManifest(
                    episodeID: episodeID,
                    status: "queued",
                    currentStep: "queued",
                    updatedAt: Date(),
                    error: nil,
                    artifacts: {
                        if FileManager.default.fileExists(atPath: files.sourceAudio.fileSystemPath) {
                            return ["source_audio": files.sourceAudio.fileSystemPath]
                        }
                        return [:]
                    }()
                ),
                to: files.manifest
            )
        }
        try? context.save()
        schedule(
            episode: episode,
            context: context,
            configuration: configuration,
            bypassCloudCheck: false
        )
    }

    /// Resumes pending/running display refinement for completed podcast translations.
    /// Dedupes via the same `episode:id:target` task IDs used by the main pipeline.
    func resumePendingDisplayRefinements(
        context: ModelContext,
        configuration: AppConfiguration
    ) {
        let episodes = (try? context.fetch(FetchDescriptor<EpisodeRecord>(
            predicate: #Predicate { $0.status == "completed" }
        ))) ?? []
        for episode in episodes {
            guard let raw = episode.activeTranslationTargetLanguage,
                  let target = TranslationTarget(rawValue: raw),
                  let files = try? fileStore.translationFiles(episodeID: episode.id, target: target),
                  let manifest = try? fileStore.readJSON(TranslationArtifactManifest.self, from: files.manifest)
            else { continue }
            let status = DisplayRefinementManifestPolicy.effectiveStatus(
                from: manifest.displayRefinementStatus
            )
            guard DisplayRefinementManifestPolicy.needsResume(status),
                  let fingerprint = manifest.sourceFingerprint,
                  !fingerprint.isEmpty
            else { continue }
            scheduleDisplayRefinement(
                episode: episode,
                target: target,
                configuration: configuration,
                sourceFingerprint: fingerprint,
                context: context
            )
        }
    }

    func refresh(
        subscription: PodcastSubscription,
        context: ModelContext,
        mode: PodcastCatalogFetchMode = .recent(limit: 50)
    ) async {
        guard refreshingSubscriptionIDs.insert(subscription.id).inserted else { return }
        defer { refreshingSubscriptionIDs.remove(subscription.id) }
        await refreshPodcastMetadata(subscription: subscription, context: context, mode: mode)
    }

    func start(episode: EpisodeRecord, context: ModelContext, configuration: AppConfiguration) {
        guard episode.status != "running", episode.status != "completed" else { return }
        schedule(episode: episode, context: context, configuration: configuration, bypassCloudCheck: false)
    }

    func retry(episode: EpisodeRecord, context: ModelContext, configuration: AppConfiguration) {
        schedule(episode: episode, context: context, configuration: configuration, bypassCloudCheck: false)
    }

    func generateWithoutCloudCheck(
        episode: EpisodeRecord,
        context: ModelContext,
        configuration: AppConfiguration
    ) {
        schedule(episode: episode, context: context, configuration: configuration, bypassCloudCheck: true)
    }

    /// Downloads a completed V10 job into an already-materialized assistant episode.
    func installReadyAssistantCloudJob(
        episode: EpisodeRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws {
        let client = cloudClientProvider(configuration)
            ?? CloudContentGatewayFactory.makeClientIfCredentialsPresent(configuration: configuration)
        guard let client else {
            throw PipelineError.missingConfiguration("content service")
        }
        let job = try await client.getJob(jobID: jobID)
        guard job.status == .ready || job.stage == .completed else {
            throw PipelineError.badResponse("Cloud job \(jobID) is not ready (status=\(job.status.rawValue)).")
        }
        if let store = try? remoteJobStoreProvider() {
            try await store.upsert(job)
        }
        try await finishCloudJob(
            job,
            episode: episode,
            target: target,
            client: client,
            context: context
        )
    }

    private func schedule(
        episode: EpisodeRecord,
        context: ModelContext,
        configuration: AppConfiguration,
        bypassCloudCheck: Bool
    ) {
        // V10 / WP11 dispatch: the cloud backend submits/resumes a remote content
        // job; the local backend keeps the legacy on-device pipeline as the
        // rollback path. Legacy locally-completed content keeps playing from the
        // local cache and is never auto-submitted to the cloud.
        if configuration.generationBackendMode == .cloud,
           !hasCompleteLocalTranslation(
               episodeID: episode.id,
               target: configuration.translationTarget
           ) {
            scheduleCloud(episode: episode, context: context, configuration: configuration)
            return
        }
        let taskID = episodeTaskID(episodeID: episode.id, target: configuration.translationTarget)
        guard runningTasks[taskID] == nil else { return }
        let generation = (taskGenerations[taskID] ?? 0) + 1
        taskGenerations[taskID] = generation
        isRunning = true
        runningTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.taskGenerations[taskID] == generation {
                    self.runningTasks[taskID] = nil
                }
                self.isRunning = !self.runningTasks.isEmpty
            }
            await self.runEpisodePipeline(
                episode: episode,
                context: context,
                configuration: configuration,
                bypassCloudCheck: bypassCloudCheck
            )
        }
    }

    func cancel(episodeID: String) {
        let prefix = "episode:\(episodeID):"
        for key in runningTasks.keys.filter({ $0.hasPrefix(prefix) }) {
            taskGenerations[key] = (taskGenerations[key] ?? 0) + 1
            runningTasks[key]?.cancel()
            runningTasks[key] = nil
        }
    }

    /// Cancels in-flight episode tasks and waits for their cleanup so a subsequent
    /// `schedule` cannot race with a cancelled task's `fail(.cancelled)` / defer.
    private func cancelAndWait(episodeID: String) async {
        let prefix = "episode:\(episodeID):"
        let tasks = runningTasks.filter { $0.key.hasPrefix(prefix) }
        for (key, task) in tasks {
            taskGenerations[key] = (taskGenerations[key] ?? 0) + 1
            task.cancel()
            runningTasks[key] = nil
            await task.value
        }
    }

    private func episodeTaskID(episodeID: String, target: TranslationTarget) -> String {
        "episode:\(episodeID):\(target.rawValue)"
    }

    private func refreshPodcastMetadata(
        subscription: PodcastSubscription,
        context: ModelContext,
        mode: PodcastCatalogFetchMode
    ) async {
        do {
            lastMessage = "Refreshing \(subscription.displayName)"
            let subscriptionID = subscription.id
            let descriptor = FetchDescriptor<EpisodeRecord>(
                predicate: #Predicate { $0.subscriptionID == subscriptionID }
            )
            let existingEpisodes = try context.fetch(descriptor)
            let previousFeedURL = subscription.feedURL
            let refreshResult = try await feedService.resolveFeed(
                from: subscription.showURL,
                knownFeedURL: subscription.feedURL,
                mode: mode,
                validators: subscription.rssValidators,
                hasLocalCatalogBaseline: !existingEpisodes.isEmpty
            )

            switch refreshResult {
            case .notModified(let validators):
                let refreshedAt = Date()
                subscription.applyRSSValidators(validators)
                subscription.lastCheckedAt = refreshedAt
                subscription.updatedAt = refreshedAt
                subscription.lastError = nil
                try context.save()
                CloudSyncCoordinator.shared.upsertPodcast(subscription, modifiedAt: subscription.updatedAt)
                lastMessage = "Feed unchanged for \(subscription.displayName)"
                return

            case .modified(let resolved, let validators):
                var existingByGUID: [String: EpisodeRecord] = [:]
                for episode in existingEpisodes where existingByGUID[episode.episodeGUID] == nil {
                    existingByGUID[episode.episodeGUID] = episode
                }

                let refreshPlan = PodcastEpisodeRefreshPolicy.plan(
                    existingGUIDs: Set(existingByGUID.keys),
                    incoming: resolved.episodes
                )
                let refreshedAt = Date()
                let resolvedAuthor = resolved.show.author.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveAuthor = resolvedAuthor.isEmpty
                    ? (subscription.authorName ?? "")
                    : resolvedAuthor
                let feedURLChanged = previousFeedURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                    != resolved.feedURL.absoluteString
                try context.transaction {
                    for metadata in refreshPlan.updates {
                        guard let episode = existingByGUID[metadata.guid] else { continue }
                        episode.showTitle = resolved.show.title
                        if !effectiveAuthor.isEmpty {
                            episode.showArtist = effectiveAuthor
                        }
                        episode.episodeTitle = metadata.title
                        episode.enclosureURL = metadata.enclosureURL.absoluteString
                        if let publishedAt = metadata.publishedAt {
                            episode.publishedAt = publishedAt
                        }
                        if let artworkURL = metadata.artworkURL?.absoluteString {
                            episode.artworkURL = artworkURL
                        }
                        if let summary = metadata.summary,
                           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            episode.summaryText = summary
                        }
                        if let duration = metadata.durationSeconds {
                            episode.mediaDurationSeconds = duration
                        }
                        if let season = metadata.seasonNumber {
                            episode.seasonNumber = season
                        }
                        if let number = metadata.episodeNumber {
                            episode.episodeNumber = number
                        }
                        if let websiteURL = metadata.link?.absoluteString {
                            episode.episodeWebsiteURL = websiteURL
                        }
                        episode.updatedAt = refreshedAt
                    }
                    for metadata in refreshPlan.insertions {
                        context.insert(EpisodeRecord(
                            subscriptionID: subscription.id,
                            showTitle: resolved.show.title,
                            showArtist: effectiveAuthor,
                            episodeTitle: metadata.title,
                            episodeGUID: metadata.guid,
                            publishedAt: metadata.publishedAt,
                            enclosureURL: metadata.enclosureURL.absoluteString,
                            artworkURL: metadata.artworkURL?.absoluteString,
                            summaryText: metadata.summary,
                            mediaDurationSeconds: metadata.durationSeconds,
                            seasonNumber: metadata.seasonNumber,
                            episodeNumber: metadata.episodeNumber,
                            episodeWebsiteURL: metadata.link?.absoluteString
                        ))
                    }

                    subscription.displayName = PodcastDisplayNamePolicy.refreshedName(
                        current: subscription.displayName,
                        sourceURL: subscription.showURL,
                        feedTitle: resolved.show.title
                    )
                    subscription.feedURL = resolved.feedURL.absoluteString
                    if !resolvedAuthor.isEmpty {
                        subscription.authorName = resolvedAuthor
                    }
                    if let summary = resolved.show.summary {
                        subscription.summaryText = summary
                    }
                    if let artworkURL = resolved.show.artworkURL?.absoluteString {
                        subscription.artworkURL = artworkURL
                        subscription.artworkSource = resolved.show.artworkSource?.rawValue
                    }
                    if let websiteURL = resolved.show.websiteURL?.absoluteString {
                        subscription.websiteURL = websiteURL
                    }
                    if let appleURL = resolved.show.applePodcastsURL?.absoluteString {
                        subscription.applePodcastsURL = appleURL
                    }
                    let availableAfterRefresh = Set(existingByGUID.keys)
                        .union(refreshPlan.insertions.map(\.guid))
                    subscription.hasMoreEpisodes = !resolved.allEpisodeGUIDs.isSubset(of: availableAfterRefresh)
                    if feedURLChanged {
                        subscription.clearRSSValidators()
                    }
                    subscription.applyRSSValidators(validators)
                    subscription.lastCheckedAt = refreshedAt
                    subscription.updatedAt = refreshedAt
                    subscription.lastError = nil
                    subscription.lastEpisodeGUID = resolved.episodes.first?.guid
                    try context.save()
                }
                CloudSyncCoordinator.shared.upsertPodcast(subscription, modifiedAt: subscription.updatedAt)
                lastMessage = "Refreshed \(resolved.episodes.count) episodes for \(subscription.displayName)"
            }
        } catch {
            let message = error.localizedDescription
            subscription.lastCheckedAt = Date()
            subscription.updatedAt = Date()
            subscription.lastError = message
            // Keep existing RSS validators on network failure for the next attempt.
            try? context.save()
            CloudSyncCoordinator.shared.upsertPodcast(subscription, modifiedAt: subscription.updatedAt)
            lastMessage = message
        }
    }

    private func runEpisodePipeline(
        episode: EpisodeRecord,
        context: ModelContext,
        configuration: AppConfiguration,
        bypassCloudCheck: Bool
    ) async {
        let target = configuration.translationTarget
        episode.activeTranslationTargetLanguage = target.rawValue
        normalizeLegacyStatus(episode)
        let variantID = TranslationVariantIdentity.make(
            contentKind: .podcastEpisode,
            contentID: episode.id,
            target: target
        )
        guard runningVariantIDs.insert(variantID).inserted else { return }
        defer { runningVariantIDs.remove(variantID) }
        var retainedPlayableSource = false

        do {
            let files = try fileStore.episodeFiles(episodeID: episode.id)
            let translationFiles = try fileStore.translationFiles(episodeID: episode.id, target: target)
            let variant = try TranslationVariantRepository.getOrCreate(
                contentKind: .podcastEpisode,
                contentID: episode.id,
                target: target,
                context: context
            )
            if target == .simplifiedChinese,
               try fileStore.migrateLegacySimplifiedChineseIfNeeded(episodeID: episode.id, to: translationFiles) {
                variant.segmentsPath = translationFiles.segments.fileSystemPath
            }
            try fileStore.migrateLegacyEnglishBaseIfNeeded(episodeID: episode.id)
            let episodeID = episode.id
            let legacyRecords = try context.fetch(FetchDescriptor<SegmentRecord>(
                predicate: #Predicate { $0.episodeID == episodeID }
            ))
            if try fileStore.migrateLegacySegmentRecordsIfNeeded(
                legacyRecords,
                episodeID: episode.id,
                target: target,
                destination: translationFiles
            ) {
                variant.segmentsPath = translationFiles.segments.fileSystemPath
            }

            let artifactIdentity = podcastArtifactIdentity(
                episode: episode,
                target: target,
                context: context
            )
            var rawSegments = (try? fileStore.readJSON([LearningSegment].self, from: files.rawTranscription)) ?? []
            if !rawSegments.isEmpty {
                try? DashScopeCheckpointStore(fileURL: files.asrCheckpoint).remove()
                try? FileManager.default.removeItem(at: files.asrDownloadedResult)
            }
            if let existing = try? fileStore.readJSON([LearningSegment].self, from: translationFiles.segments),
               !existing.isEmpty,
               existing.allSatisfy({ !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                var selectedSegments = existing
                var selectedUpdatedAt = variant.updatedAt
                if let artifactIdentity {
                    try? await subtitleSync.publishReady(
                        identity: artifactIdentity,
                        segments: existing,
                        generatedAt: variant.updatedAt
                    )
                    if !bypassCloudCheck,
                       case .ready(let envelope) = await subtitleSync.lookup(identity: artifactIdentity) {
                        selectedSegments = envelope.segments
                        selectedUpdatedAt = envelope.generatedAt
                    }
                }
                if rawSegments.isEmpty || selectedSegments != existing {
                    rawSegments = sourceSegments(from: selectedSegments)
                    try fileStore.writeJSON(rawSegments, to: files.rawTranscription)
                }
                let existingManifest = try? fileStore.readJSON(
                    TranslationArtifactManifest.self,
                    from: translationFiles.manifest
                )
                let existingRefinement = DisplayRefinementManifestPolicy.effectiveStatus(
                    from: existingManifest?.displayRefinementStatus
                )
                // Old ready manifests without the field are treated as already refined.
                let shouldRefine = DisplayRefinementManifestPolicy.needsResume(existingRefinement)
                let candidateTotal = DisplayRefinementPlanner.candidateIndices(in: selectedSegments).count
                try finishSuccessfully(
                    episode: episode,
                    variant: variant,
                    target: target,
                    segments: selectedSegments,
                    files: translationFiles,
                    artifactIdentity: artifactIdentity,
                    context: context,
                    updatedAt: selectedUpdatedAt,
                    displayRefinementStatus: shouldRefine ? existingRefinement : .completed,
                    displayRefinementCompletedCount: shouldRefine ? 0 : candidateTotal,
                    displayRefinementTotalCount: candidateTotal,
                    publishCloud: !shouldRefine,
                    sourceFingerprint: existingManifest?.sourceFingerprint
                )
                if shouldRefine {
                    await runDisplayRefinement(
                        episode: episode,
                        target: target,
                        configuration: configuration,
                        sourceFingerprint: existingManifest?.sourceFingerprint
                            ?? TranscriptionFingerprint.make(segments: selectedSegments),
                        artifactIdentity: artifactIdentity,
                        context: context
                    )
                }
                return
            }

            if !bypassCloudCheck, artifactIdentity == nil {
                pauseForCloudCheck(
                    episode,
                    target: target,
                    context: context,
                    message: L10n.string("cloud.status.failed", fallback: "iCloud Sync Failed")
                )
                return
            }

            if !bypassCloudCheck, let artifactIdentity {
                try await update(
                    episode,
                    target: target,
                    context: context,
                    status: "running",
                    step: "cloud_check",
                    message: "cloud_check",
                    files: files
                )
                switch await subtitleSync.lookup(identity: artifactIdentity) {
                case .ready(let envelope):
                    rawSegments = sourceSegments(from: envelope.segments)
                    try fileStore.writeJSON(rawSegments, to: files.rawTranscription)
                    try finishSuccessfully(
                        episode: episode,
                        variant: variant,
                        target: target,
                        segments: envelope.segments,
                        files: translationFiles,
                        artifactIdentity: artifactIdentity,
                        context: context,
                        updatedAt: envelope.generatedAt
                    )
                    return
                case .sourceOnly(let envelope):
                    rawSegments = sourceSegments(from: envelope.segments)
                    try fileStore.writeJSON(rawSegments, to: files.rawTranscription)
                case .notFound:
                    break
                case .unavailable(let message):
                    pauseForCloudCheck(
                        episode,
                        target: target,
                        context: context,
                        message: message
                    )
                    return
                }
            }

            retainedPlayableSource = !rawSegments.isEmpty
            if rawSegments.isEmpty {
                guard configuration.hasDashScopeASRKey, configuration.hasTranslationKey else {
                    let code = configuration.hasDashScopeASRKey
                        ? "missing_translation_configuration"
                        : "missing_asr_configuration"
                    fail(episode, target: target, context: context, message: code)
                    return
                }
                try Task.checkCancellation()
                try await update(episode, target: target, context: context, status: "running", step: "download", message: "download", files: files)
                let source = try await downloadAudio(from: episode.enclosureURL, to: files.sourceAudio, episode: episode, target: target, context: context)
                episode.localAudioPath = source.fileSystemPath

                try Task.checkCancellation()
                try await update(episode, target: target, context: context, status: "running", step: "oss_upload", message: "upload", files: files)

                try Task.checkCancellation()
                let asrPipeline = LocalAudioASRPipeline(transcriptionClient: transcriptionClient)
                rawSegments = try await asrPipeline.transcribeAndSegment(
                    audioURL: source,
                    apiKey: configuration.dashscopeAPIKey,
                    checkpointURL: files.asrCheckpoint,
                    downloadedResultURL: files.asrDownloadedResult
                ) { stage in
                    await self.updateASRProgress(
                        stage,
                        episode: episode,
                        target: target,
                        context: context,
                        files: files
                    )
                }
                // Local acoustic–semantic segmentation already applied inside LocalAudioASRPipeline.
                try Task.checkCancellation()
                if retainedPlayableSource,
                   episode.activeTranslationTargetLanguage == target.rawValue {
                    episode.pipelineStep = "segment_source"
                    episode.pipelineProgress = 0.69
                    episode.pipelineMessage = "segment_source"
                    episode.errorMessage = nil
                    episode.updatedAt = Date()
                    try context.save()
                } else {
                    try await update(
                        episode,
                        target: target,
                        context: context,
                        status: "running",
                        step: "segment_source",
                        message: "segment_source",
                        files: files,
                        progressOverride: 0.69
                    )
                }
                try fileStore.writeJSON(rawSegments, to: files.rawTranscription)
                retainedPlayableSource = !rawSegments.isEmpty
            }

            guard configuration.hasTranslationKey else {
                fail(episode, target: target, context: context, message: "missing_translation_configuration")
                return
            }

            if let existing = try? fileStore.readJSON([LearningSegment].self, from: translationFiles.segments),
               !existing.isEmpty {
                let savedFingerprint = (try? fileStore.readJSON(TranslationArtifactManifest.self, from: translationFiles.manifest))?.sourceFingerprint
                rawSegments = TranslationResultMerger.mergeSavedTranslations(
                    saved: existing,
                    onto: rawSegments,
                    savedFingerprint: savedFingerprint
                )
                if !rawSegments.isEmpty && rawSegments.allSatisfy({ !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    try finishSuccessfully(
                        episode: episode,
                        variant: variant,
                        target: target,
                        segments: rawSegments,
                        files: translationFiles,
                        artifactIdentity: artifactIdentity,
                        context: context
                    )
                    return
                }
            }

            try Task.checkCancellation()
            if retainedPlayableSource,
               episode.activeTranslationTargetLanguage == target.rawValue {
                episode.pipelineStep = "translate"
                episode.pipelineMessage = "translate"
                episode.errorMessage = nil
                episode.updatedAt = Date()
            } else {
                try await update(episode, target: target, context: context, status: "running", step: "translate", message: "translate", files: files)
            }
            variant.variantStatus = .running
            variant.totalCount = rawSegments.count
            variant.errorCode = nil
            variant.technicalDetails = nil
            let translatedSegments = try await translationClient.translateIncrementally(
                rawSegments,
                target: target,
                configuration: configuration
            ) { partialSegments in
                try self.fileStore.writeJSON(partialSegments, to: translationFiles.segments)
                variant.segmentsPath = translationFiles.segments.fileSystemPath
                variant.translatedCount = partialSegments.filter {
                    !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count
                variant.updatedAt = Date()
                try self.writeTranslationManifest(
                    episodeID: episode.id,
                    target: target,
                    variant: variant,
                    files: translationFiles
                )
                try context.save()
            }

            try Task.checkCancellation()
            // Translation is fully playable here. Commit completed/100% before any
            // display sub-clause refinement so long-sentence LLM work cannot stall the
            // player at `running / build_learning_pack / 90%`.
            let completedSegments = LearningPackBuilder.buildPack(segments: translatedSegments).segments
            let needsRefinement = DisplayRefinementPlanner.needsRefinement(completedSegments)
            let refinementStatus: DisplayRefinementStatus = needsRefinement ? .pending : .completed
            let refinementTotal = DisplayRefinementPlanner.candidateIndices(in: completedSegments).count
            try finishSuccessfully(
                episode: episode,
                variant: variant,
                target: target,
                segments: completedSegments,
                files: translationFiles,
                artifactIdentity: artifactIdentity,
                context: context,
                displayRefinementStatus: refinementStatus,
                displayRefinementCompletedCount: needsRefinement ? 0 : refinementTotal,
                displayRefinementTotalCount: refinementTotal,
                publishCloud: !needsRefinement
            )
            if needsRefinement {
                await runDisplayRefinement(
                    episode: episode,
                    target: target,
                    configuration: configuration,
                    sourceFingerprint: TranscriptionFingerprint.make(segments: completedSegments),
                    artifactIdentity: artifactIdentity,
                    context: context
                )
            }
        } catch is CancellationError {
            // Never roll a completed episode back to failed/running because refinement
            // was cancelled; leave displayRefinementStatus pending for the next resume.
            if episode.status == "completed" {
                return
            }
            if !retainedPlayableSource {
                fail(episode, target: target, context: context, message: "cancelled")
            }
        } catch {
            if episode.status == "completed" {
                return
            }
            if let variant = try? TranslationVariantRepository.find(
                contentKind: .podcastEpisode,
                contentID: episode.id,
                target: target,
                context: context
            ) {
                variant.variantStatus = (variant.translatedCount ?? 0) > 0 ? .partial : .failed
                variant.errorCode = "translation_failed"
                variant.technicalDetails = error.localizedDescription
                variant.updatedAt = Date()
                if let translationFiles = try? fileStore.translationFiles(episodeID: episode.id, target: target) {
                    try? writeTranslationManifest(
                        episodeID: episode.id,
                        target: target,
                        variant: variant,
                        files: translationFiles
                    )
                }
            }
            try? context.save()
            if retainedPlayableSource,
               episode.activeTranslationTargetLanguage == target.rawValue {
                episode.status = "completed"
                episode.pipelineStep = "translate"
                episode.pipelineMessage = "translation_failed"
                episode.errorMessage = error.localizedDescription
                episode.updatedAt = Date()
                try? context.save()
            } else {
                fail(episode, target: target, context: context, message: error.localizedDescription)
            }
        }
    }

    private func update(
        _ episode: EpisodeRecord,
        target: TranslationTarget,
        context: ModelContext,
        status: String,
        step: String,
        message: String,
        files: EpisodeFiles,
        progressOverride: Double? = nil
    ) async throws {
        guard episode.activeTranslationTargetLanguage == target.rawValue else { return }
        episode.status = status
        episode.pipelineStep = step
        episode.pipelineProgress = progressOverride ?? progress(for: step)
        episode.pipelineMessage = message
        episode.updatedAt = Date()
        episode.errorMessage = nil
        lastMessage = "\(episode.episodeTitle): \(message)"
        try fileStore.writeJSON(
            PipelineManifest(
                episodeID: episode.id,
                status: status,
                currentStep: step,
                updatedAt: Date(),
                error: nil,
                artifacts: ["source_audio": files.sourceAudio.fileSystemPath]
            ),
            to: files.manifest
        )
        try context.save()
    }

    private func updateASRProgress(
        _ stage: DashScopeTranscriptionStage,
        episode: EpisodeRecord,
        target: TranslationTarget,
        context: ModelContext,
        files: EpisodeFiles
    ) async {
        let presentation: (step: String, message: String, progress: Double)
        switch stage {
        case .preparingUpload:
            presentation = ("oss_upload", "asr_preparing_upload", 0.28)
        case .uploadingAudio:
            presentation = ("oss_upload", "asr_uploading_audio", 0.34)
        case .submitting:
            presentation = ("transcribe", "asr_submitting", 0.44)
        case .polling:
            presentation = ("transcribe", "asr_polling", 0.48)
        case .downloadingResult:
            presentation = ("transcribe", "asr_downloading_result", 0.62)
        case .parsingResult:
            presentation = ("transcribe", "asr_parsing_result", 0.67)
        }
        try? await update(
            episode,
            target: target,
            context: context,
            status: "running",
            step: presentation.step,
            message: presentation.message,
            files: files,
            progressOverride: presentation.progress
        )
    }

    private func fail(_ episode: EpisodeRecord, target: TranslationTarget, context: ModelContext, message: String) {
        guard episode.activeTranslationTargetLanguage == target.rawValue else { return }
        episode.status = "failed"
        episode.errorMessage = message
        episode.pipelineMessage = "failed"
        episode.updatedAt = Date()
        try? context.save()
        lastMessage = message
    }

    private func progress(for step: String) -> Double {
        switch step {
        case "cloud_check": 0.02
        case "download": 0.12
        case "oss_upload": 0.28
        case "transcribe": 0.48
        case "segment_source": 0.69
        case "translate": 0.72
        case "build_learning_pack": 0.9
        case "completed": 1.0
        default: 0.05
        }
    }

    private func downloadAudio(from value: String, to destination: URL, episode: EpisodeRecord, target: TranslationTarget, context: ModelContext) async throws -> URL {
        guard let url = URL(string: value) else { throw PodcastFeedError.invalidURL }
        if FileManager.default.fileExists(atPath: destination.fileSystemPath) {
            if episode.activeTranslationTargetLanguage == target.rawValue {
                episode.pipelineProgress = 0.26
                episode.pipelineMessage = "download"
                try? context.save()
            }
            return destination
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 900
        let tempURL = destination
            .deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).session.\(UUID().uuidString)")
        let progressReporter = DownloadProgressReporter(runner: self, episode: episode, target: target, context: context)
        let downloader = AudioDownloadTask(tempURL: tempURL) { completed, expected in
            Task { @MainActor in
                progressReporter.update(completedBytes: completed, expectedBytes: expected)
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
        let (downloadedTempURL, response) = try await withNetworkRetries(operation: "audio download") {
            try await downloader.download(request: request, session: session)
        }
        try validateDownload(response)
        try installDownloadedAudio(from: downloadedTempURL, to: destination)
        if episode.activeTranslationTargetLanguage == target.rawValue {
            episode.pipelineProgress = 0.26
            episode.pipelineMessage = "download"
            try? context.save()
        }
        return destination
    }

    fileprivate func updateDownloadProgress(episode: EpisodeRecord, target: TranslationTarget, context: ModelContext, completedBytes: Int64, expectedBytes: Int64) {
        guard episode.activeTranslationTargetLanguage == target.rawValue,
              episode.status == "running",
              episode.pipelineStep == "download"
        else { return }
        if expectedBytes > 0 {
            let fraction = min(max(Double(completedBytes) / Double(expectedBytes), 0), 1)
            episode.pipelineProgress = 0.12 + fraction * 0.14
            episode.pipelineMessage = L10n.format(
                "pipeline.download.progress_known",
                fallback: "Downloading source audio %@/%@",
                formatBytes(completedBytes),
                formatBytes(expectedBytes)
            )
        } else {
            episode.pipelineProgress = max(episode.pipelineProgress ?? 0.12, 0.14)
            episode.pipelineMessage = L10n.format(
                "pipeline.download.progress_unknown",
                fallback: "Downloading source audio %@",
                formatBytes(completedBytes)
            )
        }
        episode.updatedAt = Date()
        try? context.save()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func installDownloadedAudio(from temp: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appending(path: "\(destination.lastPathComponent).download.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temp) }
        defer { try? fileManager.removeItem(at: staging) }

        audioFileLock.lock()
        defer { audioFileLock.unlock() }

        if hasUsableFile(at: destination) {
            return
        }

        try removeStaleAudioDownloads(in: directory, destination: destination)
        if fileManager.fileExists(atPath: staging.fileSystemPath) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.moveItem(at: temp, to: staging)

        if hasUsableFile(at: destination) {
            return
        }

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if hasUsableFile(at: destination) {
                return
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    private func hasUsableFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.fileSystemPath),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular
        else { return false }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0
    }

    private func removeStaleAudioDownloads(in directory: URL, destination: URL) throws {
        let fileManager = FileManager.default
        let prefix = "\(destination.lastPathComponent).download."
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func writeTranslationManifest(
        episodeID: String,
        target: TranslationTarget,
        variant: TranslationVariantRecord,
        files: TranslationVariantFiles,
        segments: [LearningSegment]? = nil,
        sourceFingerprint: String? = nil,
        displayRefinementStatus: DisplayRefinementStatus? = nil,
        displayRefinementCompletedCount: Int? = nil,
        displayRefinementTotalCount: Int? = nil
    ) throws {
        let resolvedSegments = segments
            ?? (try? fileStore.readJSON([LearningSegment].self, from: files.segments))
            ?? []
        let existing = try? fileStore.readJSON(TranslationArtifactManifest.self, from: files.manifest)
        // Prefer an explicit fingerprint (pre-split English source). After display
        // refinement, segment texts change and must not rewrite the source identity.
        let fingerprint = sourceFingerprint
            ?? existing?.sourceFingerprint
            ?? (resolvedSegments.isEmpty ? nil : TranscriptionFingerprint.make(segments: resolvedSegments))
        let refinementStatus = displayRefinementStatus?.rawValue
            ?? existing?.displayRefinementStatus
        let refinementCompleted = displayRefinementCompletedCount
            ?? existing?.displayRefinementCompletedCount
        let refinementTotal = displayRefinementTotalCount
            ?? existing?.displayRefinementTotalCount
        try fileStore.writeJSON(
            TranslationArtifactManifest(
                contentKind: TranslationContentKind.podcastEpisode.rawValue,
                contentID: episodeID,
                targetLanguage: target.rawValue,
                status: variant.variantStatus.rawValue,
                updatedAt: variant.updatedAt,
                artifacts: ["segments": files.segments.fileSystemPath],
                sourceFingerprint: fingerprint,
                pipelineVersion: SubtitlePipelineVersion.current,
                displayRefinementStatus: refinementStatus,
                displayRefinementCompletedCount: refinementCompleted,
                displayRefinementTotalCount: refinementTotal
            ),
            to: files.manifest
        )
    }

    /// Finishes a successfully translated variant: writes segments, flips the variant ready,
    /// writes the manifest, marks the episode completed, and saves once. Optional cloud
    /// publication is deferred when display refinement is still pending so only the final
    /// refined artifact is published.
    private func finishSuccessfully(
        episode: EpisodeRecord,
        variant: TranslationVariantRecord,
        target: TranslationTarget,
        segments: [LearningSegment],
        files: TranslationVariantFiles,
        artifactIdentity: SubtitleArtifactIdentity?,
        context: ModelContext,
        updatedAt: Date = Date(),
        displayRefinementStatus: DisplayRefinementStatus = .completed,
        displayRefinementCompletedCount: Int? = nil,
        displayRefinementTotalCount: Int? = nil,
        publishCloud: Bool = true,
        sourceFingerprint: String? = nil
    ) throws {
        try fileStore.writeJSON(segments, to: files.segments)
        variant.segmentsPath = files.segments.fileSystemPath
        variant.variantStatus = .ready
        variant.translatedCount = segments.count
        variant.totalCount = segments.count
        variant.errorCode = nil
        variant.technicalDetails = nil
        variant.updatedAt = updatedAt
        let fingerprint = sourceFingerprint ?? (
            segments.isEmpty ? nil : TranscriptionFingerprint.make(segments: segments)
        )
        let total = displayRefinementTotalCount
            ?? (displayRefinementStatus == .completed ? 0 : DisplayRefinementPlanner.candidateIndices(in: segments).count)
        let completed = displayRefinementCompletedCount
            ?? (displayRefinementStatus == .completed ? total : 0)
        try writeTranslationManifest(
            episodeID: episode.id,
            target: target,
            variant: variant,
            files: files,
            segments: segments,
            sourceFingerprint: fingerprint,
            displayRefinementStatus: displayRefinementStatus,
            displayRefinementCompletedCount: completed,
            displayRefinementTotalCount: total
        )

        if episode.activeTranslationTargetLanguage == target.rawValue {
            episode.status = "completed"
            episode.pipelineStep = "completed"
            episode.pipelineProgress = 1.0
            episode.pipelineMessage = "completed"
            episode.errorMessage = nil
            episode.updatedAt = Date()
            if let episodeFiles = try? fileStore.episodeFiles(episodeID: episode.id) {
                try? fileStore.writeJSON(
                    PipelineManifest(
                        episodeID: episode.id,
                        status: "completed",
                        currentStep: "completed",
                        updatedAt: Date(),
                        error: nil,
                        artifacts: ["source_audio": episodeFiles.sourceAudio.fileSystemPath]
                    ),
                    to: episodeFiles.manifest
                )
            }
        }

        try context.save()
        lastMessage = episode.episodeTitle

        // Non-blocking, failable cloud publication: a failure here must not undo the
        // completed local state, and it runs after the save so it cannot delay the
        // play page from observing `completed`. Deferred while refinement is pending.
        if publishCloud, let artifactIdentity {
            Task { [subtitleSync] in
                try? await subtitleSync.publishReady(
                    identity: artifactIdentity,
                    segments: segments,
                    generatedAt: updatedAt
                )
            }
        }
    }

    private func scheduleDisplayRefinement(
        episode: EpisodeRecord,
        target: TranslationTarget,
        configuration: AppConfiguration,
        sourceFingerprint: String,
        context: ModelContext
    ) {
        let taskID = episodeTaskID(episodeID: episode.id, target: target)
        guard runningTasks[taskID] == nil else { return }
        let generation = (taskGenerations[taskID] ?? 0) + 1
        taskGenerations[taskID] = generation
        isRunning = true
        let artifactIdentity = podcastArtifactIdentity(episode: episode, target: target, context: context)
        runningTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.taskGenerations[taskID] == generation {
                    self.runningTasks[taskID] = nil
                }
                self.isRunning = !self.runningTasks.isEmpty
            }
            await self.runDisplayRefinement(
                episode: episode,
                target: target,
                configuration: configuration,
                sourceFingerprint: sourceFingerprint,
                artifactIdentity: artifactIdentity,
                context: context
            )
        }
    }

    private func runDisplayRefinement(
        episode: EpisodeRecord,
        target: TranslationTarget,
        configuration: AppConfiguration,
        sourceFingerprint: String,
        artifactIdentity: SubtitleArtifactIdentity?,
        context: ModelContext
    ) async {
        do {
            try await displayRefiner.refine(
                episodeID: episode.id,
                target: target,
                configuration: configuration,
                sourceFingerprint: sourceFingerprint,
                artifactIdentity: artifactIdentity
            ) { status, completed, total in
                guard let variant = try? TranslationVariantRepository.find(
                    contentKind: .podcastEpisode,
                    contentID: episode.id,
                    target: target,
                    context: context
                ), let files = try? self.fileStore.translationFiles(episodeID: episode.id, target: target)
                else { return }
                variant.updatedAt = Date()
                try self.writeTranslationManifest(
                    episodeID: episode.id,
                    target: target,
                    variant: variant,
                    files: files,
                    sourceFingerprint: sourceFingerprint,
                    displayRefinementStatus: status,
                    displayRefinementCompletedCount: completed,
                    displayRefinementTotalCount: total
                )
                try context.save()
            }
        } catch is CancellationError {
            // Keep pending/running checkpoint for the next launch; never touch episode status.
            return
        } catch {
            // File-level errors leave the checkpoint for retry; episode stays completed.
            return
        }
    }

    private func podcastArtifactIdentity(
        episode: EpisodeRecord,
        target: TranslationTarget,
        context: ModelContext
    ) -> SubtitleArtifactIdentity? {
        guard let subscriptionID = episode.subscriptionID,
              let subscriptions = try? context.fetch(FetchDescriptor<PodcastSubscription>()),
              let subscription = subscriptions.first(where: { $0.id == subscriptionID })
        else { return nil }
        return .podcast(
            sourceURL: subscription.showURL,
            episodeGUID: episode.episodeGUID,
            target: target
        )
    }

    private func sourceSegments(from segments: [LearningSegment]) -> [LearningSegment] {
        segments.map { segment in
            var source = segment
            source.translation = ""
            return source
        }
    }

    private func pauseForCloudCheck(
        _ episode: EpisodeRecord,
        target: TranslationTarget,
        context: ModelContext,
        message: String
    ) {
        guard episode.activeTranslationTargetLanguage == target.rawValue else { return }
        episode.status = "failed"
        episode.pipelineStep = "cloud_check"
        episode.pipelineProgress = 0.02
        episode.pipelineMessage = "cloud_check_required"
        episode.errorMessage = message
        episode.updatedAt = Date()
        try? context.save()
        lastMessage = message
    }

    private func normalizeLegacyStatus(_ episode: EpisodeRecord) {
        episode.pipelineStep = LegacyPipelineStatusPolicy.normalizedCode(
            step: episode.pipelineStep,
            message: episode.pipelineMessage
        )
        if let code = LegacyPipelineStatusPolicy.code(forLegacyMessage: episode.pipelineMessage) {
            episode.pipelineMessage = code
        }
    }

    // MARK: - Cloud orchestration (V10 / WP11)

    /// Cloud-backend pipeline entry. Submits or resumes a remote content job and
    /// never touches the local download / DashScope / TranslationClient / OSS path.
    private func scheduleCloud(
        episode: EpisodeRecord,
        context: ModelContext,
        configuration: AppConfiguration
    ) {
        let taskID = episodeTaskID(episodeID: episode.id, target: configuration.translationTarget)
        guard runningTasks[taskID] == nil else { return }
        let generation = (taskGenerations[taskID] ?? 0) + 1
        taskGenerations[taskID] = generation
        isRunning = true
        runningTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.taskGenerations[taskID] == generation {
                    self.runningTasks[taskID] = nil
                }
                self.isRunning = !self.runningTasks.isEmpty
            }
            await self.runCloudEpisodePipeline(
                episode: episode,
                context: context,
                configuration: configuration
            )
        }
    }

    /// True when the on-disk translation for (episode, target) is already complete.
    /// Legacy locally-completed content short-circuits to the local pipeline and is
    /// never auto-submitted to the cloud.
    private func hasCompleteLocalTranslation(episodeID: String, target: TranslationTarget) -> Bool {
        guard let files = try? fileStore.translationFiles(episodeID: episodeID, target: target),
              let segments = try? fileStore.readJSON([LearningSegment].self, from: files.segments),
              !segments.isEmpty
        else { return false }
        return segments.allSatisfy {
            !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Reconciles remote content jobs at launch / foreground re-entry: one
    /// coordinator pass over non-terminal records, then re-schedules episodes whose
    /// remote job still has work in flight. Reached through the existing RootView
    /// hooks via `resumeOrphanedPipelines`; WP14 owns explicit scene-phase wiring.
    func reconcileRemoteJobs(context: ModelContext, configuration: AppConfiguration) async {
        guard configuration.generationBackendMode == .cloud,
              configuration.isCloudGenerationUsable,
              let client = cloudClientProvider(configuration),
              let store = try? remoteJobStoreProvider()
        else { return }
        let coordinator = CloudContentJobCoordinator(client: client, store: store)
        await coordinator.reconcileAll()
        guard let snapshots = try? await store.nonTerminalSnapshots(), !snapshots.isEmpty else { return }
        let target = configuration.translationTarget
        let episodes = (try? context.fetch(FetchDescriptor<EpisodeRecord>())) ?? []
        let subscriptions = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        for snapshot in snapshots {
            // stableKey: contentKind|contentKey|targetLanguage|quality|pipelineVersion
            let parts = snapshot.stableKey.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 5,
                  parts[0] == Substring(CloudContentType.podcastEpisode.rawValue),
                  parts[2] == Substring(target.rawValue)
            else { continue }
            let contentKey = String(parts[1])
            for episode in episodes where episode.status != "completed" {
                guard let subscriptionID = episode.subscriptionID,
                      let subscription = subscriptions.first(where: { $0.id == subscriptionID }),
                      cloudContentKey(episode: episode, subscription: subscription) == contentKey
                else { continue }
                scheduleCloud(episode: episode, context: context, configuration: configuration)
                break
            }
        }
    }

    /// Cloud pipeline for one episode: resume from the persisted remote record,
    /// adopt a server-side job via lookup (restart / cross-device handoff), or
    /// submit a new one. The job ID is persisted before any UI observes it, so a
    /// quit right after submit cannot orphan the remote task.
    private func runCloudEpisodePipeline(
        episode: EpisodeRecord,
        context: ModelContext,
        configuration: AppConfiguration
    ) async {
        let target = configuration.translationTarget
        episode.activeTranslationTargetLanguage = target.rawValue
        guard let client = cloudClientProvider(configuration) else {
            fail(episode, target: target, context: context, message: "cloud_service_not_configured")
            return
        }
        let store: RemoteContentJobStore
        do {
            store = try remoteJobStoreProvider()
        } catch {
            fail(episode, target: target, context: context, message: error.localizedDescription)
            return
        }
        let subscription = fetchSubscription(for: episode, context: context)
        let contentKey = cloudContentKey(episode: episode, subscription: subscription)
        let quality = CloudTranslationQuality(rawValue: configuration.translationQuality.rawValue) ?? .quality
        let coordinator = CloudContentJobCoordinator(client: client, store: store)
        defer { Task { await coordinator.setForeground(false) } }

        do {
            var job: CloudContentJobResponse?
            if let record = store.latestRecord(
                contentKey: contentKey,
                targetLanguage: target.rawValue,
                quality: quality.rawValue
            ) {
                switch record.statusRaw {
                case "failed":
                    // Re-sync before retrying: the local "failed" record may be
                    // stale (another device or an operator already retried), and
                    // a blind retry dead-ends on 409 INVALID_JOB_STATE even when
                    // the content is already ready. A vanished job (nil) falls
                    // through to lookup/submit.
                    job = try await client.retryJobAfterResync(jobID: record.jobID)
                case "cancelled", "expired":
                    job = nil
                default:
                    do {
                        job = try await client.getJob(jobID: record.jobID)
                    } catch let error as CloudContentError {
                        // A vanished remote job falls through to lookup/submit.
                        if case .http(let status, _) = error, status == 404 {
                            job = nil
                        } else {
                            throw error
                        }
                    }
                }
                if let job {
                    try await store.upsert(job)
                }
            }
            if job == nil,
               let found = try await client.lookupJob(
                   contentType: .podcastEpisode,
                   contentKey: contentKey,
                   targetLanguage: target.rawValue,
                   translationQuality: quality
               ) {
                switch found.status {
                case .failed:
                    try await store.upsert(found)
                    // Same stale-state hazard as the persisted-record branch above.
                    job = try await client.retryJobAfterResync(jobID: found.jobId)
                case .cancelled, .expired:
                    job = nil
                default:
                    job = found
                }
                if let job {
                    try await store.upsert(job)
                }
            }
            if job == nil {
                let request = CloudContentJobCreateRequest(
                    contentType: .podcastEpisode,
                    contentKey: contentKey,
                    source: CloudContentSource(
                        platform: "rss",
                        sourceId: episode.episodeGUID,
                        url: episode.enclosureURL,
                        feedUrl: subscription?.feedURL ?? subscription?.showURL,
                        title: episode.episodeTitle
                    ),
                    sourceLanguage: "en",
                    targetLanguage: target.rawValue,
                    translationQuality: quality,
                    clientArtifactSchemaVersion: CloudArtifactManifestRef.supportedSchemaVersion
                )
                job = try await coordinator.submit(
                    request,
                    idempotencyKey: "podcast:\(episode.id):\(target.rawValue)"
                )
            }
            guard let initial = job else { return }
            let stream = await coordinator.updates(for: initial.stableKey)
            await coordinator.track(stableKey: initial.stableKey, jobID: initial.jobId)
            try await applyCloudJob(initial, episode: episode, target: target, client: client, context: context)
            guard !initial.status.isTerminal else { return }
            for await update in stream {
                try Task.checkCancellation()
                try await applyCloudJob(update, episode: episode, target: target, client: client, context: context)
                if update.status.isTerminal { break }
            }
        } catch is CancellationError {
            // The remote record persists; the next launch/foreground reconcile resumes it.
        } catch let error as CloudContentError {
            fail(episode, target: target, context: context, message: cloudErrorMessage(error))
        } catch let error as CloudArtifactCacheError {
            fail(episode, target: target, context: context, message: cloudCacheErrorMessage(error))
        } catch {
            fail(episode, target: target, context: context, message: error.localizedDescription)
        }
    }

    /// Projects one server snapshot onto the episode's display fields. `audioReady`
    /// and `subtitlesReady` advance independently on the persisted remote record
    /// (upserted before this runs), so audio can become playable before subtitles
    /// land; remote playback itself is WP12's lane.
    private func applyCloudJob(
        _ job: CloudContentJobResponse,
        episode: EpisodeRecord,
        target: TranslationTarget,
        client: CloudContentJobClient,
        context: ModelContext
    ) async throws {
        guard episode.activeTranslationTargetLanguage == target.rawValue else { return }
        if job.status == .ready {
            try await finishCloudJob(job, episode: episode, target: target, client: client, context: context)
            return
        }
        let projection = CloudPodcastProjectionPolicy.project(job)
        episode.status = projection.status
        episode.pipelineStep = projection.pipelineStep
        episode.pipelineProgress = CloudProgressMergePolicy.merged(
            existing: episode.pipelineProgress ?? 0,
            incoming: projection.progress
        )
        episode.pipelineMessage = projection.pipelineStep
        episode.errorMessage = projection.errorMessage
        episode.updatedAt = Date()
        lastMessage = "\(episode.episodeTitle): \(projection.pipelineStep)"
        if let files = try? fileStore.episodeFiles(episodeID: episode.id) {
            try? fileStore.writeJSON(
                PipelineManifest(
                    episodeID: episode.id,
                    status: projection.status,
                    currentStep: projection.pipelineStep,
                    updatedAt: Date(),
                    error: projection.errorMessage,
                    artifacts: [:]
                ),
                to: files.manifest
            )
        }
        try context.save()
    }

    /// Handles a ready job: validates the artifact manifest, installs artifacts
    /// atomically, then commits the episode as completed through the same write
    /// path as the local pipeline so rendering and reconciliation do not regress.
    private func finishCloudJob(
        _ job: CloudContentJobResponse,
        episode: EpisodeRecord,
        target: TranslationTarget,
        client: CloudContentJobClient,
        context: ModelContext
    ) async throws {
        guard let manifest = job.artifacts else {
            throw CloudArtifactCacheError.missingManifest
        }
        guard manifest.isCompatibleWithClient else {
            throw CloudArtifactCacheError.incompatibleSchema(manifest.schemaVersion)
        }
        if !hasCompleteLocalTranslation(episodeID: episode.id, target: target) {
            episode.status = "running"
            episode.pipelineStep = "package"
            episode.pipelineProgress = 0.95
            episode.pipelineMessage = "package"
            episode.errorMessage = nil
            episode.updatedAt = Date()
            try context.save()
            try await installCloudArtifacts(
                jobID: job.jobId,
                manifest: manifest,
                episode: episode,
                target: target,
                client: client
            )
        }
        let translationFiles = try fileStore.translationFiles(episodeID: episode.id, target: target)
        let segments = try fileStore.readJSON([LearningSegment].self, from: translationFiles.segments)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw CloudArtifactCacheError.incompleteSegments
        }
        let files = try fileStore.episodeFiles(episodeID: episode.id)
        if !FileManager.default.fileExists(atPath: files.rawTranscription.fileSystemPath) {
            try fileStore.writeJSON(sourceSegments(from: segments), to: files.rawTranscription)
        }
        let variant = try TranslationVariantRepository.getOrCreate(
            contentKind: .podcastEpisode,
            contentID: episode.id,
            target: target,
            context: context
        )
        // The server already ran display refinement (`refining_subtitles` stage),
        // so the installed artifact is final.
        try finishSuccessfully(
            episode: episode,
            variant: variant,
            target: target,
            segments: segments,
            files: translationFiles,
            artifactIdentity: podcastArtifactIdentity(episode: episode, target: target, context: context),
            context: context,
            updatedAt: job.updatedAt,
            displayRefinementStatus: .completed,
            sourceFingerprint: manifest.sourceFingerprint
        )
    }

    /// Downloads every ready manifest file into LocalFileStore-compatible
    /// locations with ETag/304 reuse and per-file SHA-256 verification, replacing
    /// the local cache atomically. The ETag sidecar is written only after the
    /// whole batch succeeds, so an interrupted download never clobbers the
    /// previous cache. Shared source artifacts (audio) are never downloaded or
    /// deleted here.
    private func installCloudArtifacts(
        jobID: String,
        manifest: CloudArtifactManifestRef,
        episode: EpisodeRecord,
        target: TranslationTarget,
        client: CloudContentJobClient
    ) async throws {
        let knownRoles: Set<String> = ["segments", "sourceVtt", "targetVtt"]
        for ref in manifest.files where ref.required {
            guard knownRoles.contains(ref.role) else {
                throw CloudArtifactCacheError.unsupportedRequiredRole(ref.role)
            }
            guard ref.status == "ready" else {
                throw CloudArtifactCacheError.missingRequiredArtifact(ref.name)
            }
        }

        let episodeID = episode.id
        let translationFiles = try fileStore.translationFiles(episodeID: episodeID, target: target)
        var etags = fileStore.cloudArtifactETags(episodeID: episodeID)
        var installedSegments = false

        for ref in manifest.files where ref.status == "ready" && knownRoles.contains(ref.role) {
            let key = "\(target.rawValue)|\(ref.name)"
            let cachedETag = etags[key]
            var download = try await client.fetchArtifact(
                jobID: jobID,
                fileName: ref.name,
                ifNoneMatch: cachedETag
            )
            if download.notModified {
                if let destination = cloudArtifactDestination(for: ref.role, translationFiles: translationFiles),
                   FileManager.default.fileExists(atPath: destination.fileSystemPath) {
                    // Unchanged artifact with a live cache entry: nothing to do.
                    etags[key] = download.etag ?? ref.etag ?? cachedETag
                    if ref.role == "segments" { installedSegments = true }
                    continue
                }
                // The local copy vanished; refetch without the validator.
                download = try await client.fetchArtifact(jobID: jobID, fileName: ref.name)
            }
            switch ref.role {
            case "segments":
                try fileStore.verifyArtifact(download.data, sha256: ref.sha256)
                let envelope = try cloudSegmentsDecoder.decode(CloudSegmentsEnvelope.self, from: download.data)
                guard envelope.schemaVersion <= CloudArtifactManifestRef.supportedSchemaVersion else {
                    throw CloudArtifactCacheError.incompatibleSchema(envelope.schemaVersion)
                }
                guard !envelope.segments.isEmpty else {
                    throw CloudArtifactCacheError.incompleteSegments
                }
                // The server artifact is an envelope; local storage and the player
                // consume the bare segment array.
                try fileStore.writeJSON(envelope.segments, to: translationFiles.segments)
                installedSegments = true
            case "sourceVtt":
                try fileStore.installVerifiedArtifact(
                    download.data,
                    sha256: ref.sha256,
                    to: translationFiles.sourceVTT
                )
            case "targetVtt":
                try fileStore.installVerifiedArtifact(
                    download.data,
                    sha256: ref.sha256,
                    to: translationFiles.targetVTT
                )
            default:
                continue
            }
            etags[key] = download.etag ?? ref.etag
        }
        guard installedSegments else {
            throw CloudArtifactCacheError.missingRequiredArtifact("segments.json")
        }
        try fileStore.writeCloudArtifactETags(etags, episodeID: episodeID)
    }

    private func cloudArtifactDestination(
        for role: String,
        translationFiles: TranslationVariantFiles
    ) -> URL? {
        switch role {
        case "segments": return translationFiles.segments
        case "sourceVtt": return translationFiles.sourceVTT
        case "targetVtt": return translationFiles.targetVTT
        default: return nil
        }
    }

    /// Content key per docs/contracts/content-keys-v1 §1.1: normalized feed URL +
    /// episode GUID, with the enclosure host+path fallback when no feed identity
    /// exists. Used identically at submit and reconcile time.
    private func cloudContentKey(episode: EpisodeRecord, subscription: PodcastSubscription?) -> String {
        CloudContentKeyPolicy.podcastContentKey(
            feedURL: cloudFeedIdentity(episode: episode, subscription: subscription),
            episodeGUID: episode.episodeGUID
        )
    }

    private func cloudFeedIdentity(episode: EpisodeRecord, subscription: PodcastSubscription?) -> String {
        CloudContentKeyPolicy.podcastFeedIdentity(
            subscriptionFeedURL: subscription?.feedURL ?? subscription?.showURL,
            assistantFeedURL: episode.assistantFeedURL,
            enclosureURL: episode.enclosureURL
        )
    }

    private func fetchSubscription(for episode: EpisodeRecord, context: ModelContext) -> PodcastSubscription? {
        guard let subscriptionID = episode.subscriptionID,
              let subscriptions = try? context.fetch(FetchDescriptor<PodcastSubscription>())
        else { return nil }
        return subscriptions.first { $0.id == subscriptionID }
    }

    private func cloudErrorMessage(_ error: CloudContentError) -> String {
        switch error {
        case .configuration:
            return "cloud_service_not_configured"
        case .transport:
            return "cloud_service_unreachable"
        case .decoding:
            return "cloud_invalid_response"
        case .http(let status, let server):
            if let server {
                return "\(server.code): \(server.message)"
            }
            if status == 401 || status == 403 {
                return "cloud_unauthorized"
            }
            return "cloud_http_\(status)"
        }
    }

    private func cloudCacheErrorMessage(_ error: CloudArtifactCacheError) -> String {
        switch error {
        case .checksumMismatch:
            return "cloud_artifact_checksum_mismatch"
        case .unsupportedRequiredRole(let role):
            return "cloud_artifact_unsupported_role:\(role)"
        case .missingRequiredArtifact(let name):
            return "cloud_artifact_missing:\(name)"
        case .incompleteSegments:
            return "cloud_artifact_incomplete_segments"
        case .missingManifest:
            return "cloud_artifact_manifest_missing"
        case .incompatibleSchema(let version):
            return "PIPELINE_VERSION_UNSUPPORTED: artifact schema v\(version)"
        }
    }
}

private func validateDownload(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
        throw PipelineError.badResponse("Audio download failed.")
    }
}

@MainActor
private final class DownloadProgressReporter: @unchecked Sendable {
    private weak var runner: PipelineRunner?
    private let episode: EpisodeRecord
    private let target: TranslationTarget
    private let context: ModelContext

    init(runner: PipelineRunner, episode: EpisodeRecord, target: TranslationTarget, context: ModelContext) {
        self.runner = runner
        self.episode = episode
        self.target = target
        self.context = context
    }

    func update(completedBytes: Int64, expectedBytes: Int64) {
        runner?.updateDownloadProgress(
            episode: episode,
            target: target,
            context: context,
            completedBytes: completedBytes,
            expectedBytes: expectedBytes
        )
    }
}

final class AudioDownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let tempURL: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var downloadedURL: URL?
    private var response: URLResponse?
    private var lastProgressAt = Date()
    private var monitorTask: Task<Void, Never>?

    init(tempURL: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.tempURL = tempURL
        self.onProgress = onProgress
    }

    func download(request: URLRequest, session: URLSession) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                withLock {
                    self.continuation = continuation
                    self.lastProgressAt = Date()
                }

                let task = session.downloadTask(with: request)
                withLock {
                    self.task = task
                }
                startProgressMonitor()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        withLock {
            lastProgressAt = Date()
        }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: tempURL)
            withLock {
                downloadedURL = tempURL
                response = downloadTask.response
            }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        let completionState = downloadedResult()
        let url = completionState.0
        let response = completionState.1

        guard let url, let response else {
            finish(.failure(PipelineError.badResponse("The audio download completed but its temporary file is unavailable.")))
            return
        }
        finish(.success((url, response)))
    }

    private func startProgressMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                let (stalled, currentTask) = progressMonitorState()
                if stalled {
                    finish(.failure(PipelineError.badResponse("The audio download made no progress for 90 seconds.")))
                    currentTask?.cancel()
                    return
                }
            }
        }
    }

    private func cancel() {
        let currentTask = withLock { task }
        currentTask?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        let finishState = takeFinishState()
        let continuation = finishState.0
        let monitorTask = finishState.1

        monitorTask?.cancel()
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func progressMonitorState() -> (stalled: Bool, task: URLSessionDownloadTask?) {
        withLock {
            (Date().timeIntervalSince(lastProgressAt) > 90, task)
        }
    }

    private func downloadedResult() -> (URL?, URLResponse?) {
        withLock {
            (downloadedURL, response)
        }
    }

    private func takeFinishState() -> (CheckedContinuation<(URL, URLResponse), Error>?, Task<Void, Never>?) {
        withLock {
            let currentContinuation = continuation
            self.continuation = nil
            let currentMonitorTask = monitorTask
            self.monitorTask = nil
            return (currentContinuation, currentMonitorTask)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Remote content job persistence (V10 / WP11)

/// SwiftData-backed `CloudContentJobPersisting` for the V10 content service.
/// Uses its own container so the main app schema stays untouched; the job ID is
/// persisted before observers see anything, so a crash after submit cannot
/// orphan the remote task. Signed playback URLs are never stored here.
@MainActor
final class RemoteContentJobStore: CloudContentJobPersisting {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let schema = Schema([RemoteContentJobRecord.self])
        let configuration = ModelConfiguration(
            "RemoteContentJobs-v1",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    func upsert(_ job: CloudContentJobResponse) async throws {
        let key = job.stableKey
        let descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate { $0.stableKey == key }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.apply(job)
        } else {
            let record = RemoteContentJobRecord(
                stableKey: key,
                contentKind: job.contentType.rawValue,
                contentKey: job.contentKey,
                jobID: job.jobId,
                statusRaw: job.status.rawValue,
                targetLanguage: job.targetLanguage,
                translationQuality: job.translationQuality.rawValue,
                pipelineVersion: job.pipelineVersion,
                createdAt: job.createdAt
            )
            context.insert(record)
            record.apply(job)
        }
        try context.save()
    }

    func snapshot(forStableKey key: String) async throws -> RemoteContentJobSnapshot? {
        let descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate { $0.stableKey == key }
        )
        return try context.fetch(descriptor).first.map(Self.makeSnapshot)
    }

    func nonTerminalSnapshots() async throws -> [RemoteContentJobSnapshot] {
        try context.fetch(FetchDescriptor<RemoteContentJobRecord>())
            .filter { !Self.isTerminal($0.statusRaw) }
            .map(Self.makeSnapshot)
    }

    /// Latest record for a podcast generation variant across pipeline versions.
    func latestRecord(contentKey: String, targetLanguage: String, quality: String) -> RemoteContentJobRecord? {
        let kind = CloudContentType.podcastEpisode.rawValue
        let descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate {
                $0.contentKind == kind
                    && $0.contentKey == contentKey
                    && $0.targetLanguage == targetLanguage
                    && $0.translationQuality == quality
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try? context.fetch(descriptor).first
    }

    /// All records for a piece of podcast content, across targets and versions.
    func records(contentKey: String) -> [RemoteContentJobRecord] {
        let kind = CloudContentType.podcastEpisode.rawValue
        let descriptor = FetchDescriptor<RemoteContentJobRecord>(
            predicate: #Predicate { $0.contentKind == kind && $0.contentKey == contentKey }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteRecords(contentKey: String) {
        for record in records(contentKey: contentKey) {
            context.delete(record)
        }
        try? context.save()
    }

    private static func makeSnapshot(_ record: RemoteContentJobRecord) -> RemoteContentJobSnapshot {
        RemoteContentJobSnapshot(
            stableKey: record.stableKey,
            jobID: record.jobID,
            statusRaw: record.statusRaw,
            isTerminal: isTerminal(record.statusRaw)
        )
    }

    /// Mirrors CloudJobStatus.isTerminal without decoding the tolerant enum.
    private static func isTerminal(_ raw: String) -> Bool {
        ["ready", "failed", "cancelled", "expired"].contains(raw)
    }
}

/// Server `segments.json` artifact payload (services/content-pipeline packaging):
/// an envelope around the bare [LearningSegment] array local storage consumes.
private struct CloudSegmentsEnvelope: Decodable {
    var schemaVersion: Int
    var segments: [LearningSegment]
}

private let cloudSegmentsDecoder = JSONDecoder()
