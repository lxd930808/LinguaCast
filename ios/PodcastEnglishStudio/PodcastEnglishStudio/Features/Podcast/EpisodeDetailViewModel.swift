import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

enum ASRProgressText {
    private static let topLevelCodes: Set<String> = [
        "cloud_check",
        "download",
        "oss_upload",
        "transcribe",
        "segment_source",
        "translate",
        "build_learning_pack",
        "completed"
    ]

    static func display(message: String?, fallback: String) -> String {
        guard let message, !message.isEmpty else { return fallback }
        if topLevelCodes.contains(message) {
            return fallback
        }
        switch message {
        case "asr_preparing_upload":
            return L10n.string(
                "pipeline.asr.preparing_upload",
                fallback: "Preparing audio upload"
            )
        case "asr_uploading_audio":
            return L10n.string(
                "pipeline.asr.uploading_audio",
                fallback: "Uploading audio"
            )
        case "asr_submitting":
            return L10n.string(
                "pipeline.asr.submitting",
                fallback: "Submitting transcription task"
            )
        case "asr_polling":
            return L10n.string(
                "pipeline.asr.polling",
                fallback: "Transcribing audio in the cloud"
            )
        case "asr_downloading_result":
            return L10n.string(
                "pipeline.asr.downloading_result",
                fallback: "Downloading transcription result"
            )
        case "asr_parsing_result":
            return L10n.string(
                "pipeline.asr.parsing_result",
                fallback: "Parsing transcription result"
            )
        default:
            return message
        }
    }
}

// Cross-platform shared state and logic (no #if). Stored properties live in EpisodeDetailView.swift;
// platform-specific layout lives in EpisodeDetailView+iOS.swift / EpisodeDetailView+tvOS.swift.
extension EpisodeDetailView {

    // MARK: - Shared status views (iOS layout)

    var loadingSegmentsView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(L10n.string("episode_detail.loading_bilingual_subtitles", fallback: "Loading bilingual subtitles"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var segmentUnavailableView: some View {
        ContentUnavailableView {
            Label(L10n.string("episode_detail.failed_to_read_bilingual_subtitles", fallback: "Failed to read bilingual subtitles"), systemImage: "exclamationmark.triangle")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("subtitle.error-state")
        } description: {
            Text(segmentLoadError ?? L10n.string("episode_detail.please_go_back_and_re_enter_this_episode", fallback: "Please go back and re-enter this episode."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle.error-state")
    }

    var unavailableView: some View {
        Group {
            if episode.status == "running" {
                VStack(spacing: 16) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L10n.string("episode_detail.generating_bilingual_subtitles", fallback: "Generating bilingual subtitles"))
                        .font(.title2.bold())
                    Text(progressMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text(verbatim: "\(progressValue.formatted(.percent.precision(.fractionLength(0)))) · \(progressStepTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        runner.retry(episode: episode, context: modelContext, configuration: settings.configuration)
                    } label: {
                        Label(L10n.string("episode_detail.retry", fallback: "Retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("subtitle.retry")
                    Button {
                        Task {
                            await runner.clearAndRegenerate(
                                episode: episode,
                                context: modelContext,
                                configuration: settings.configuration
                            )
                        }
                    } label: {
                        Label(
                            L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("podcast.clear-and-regenerate")
                }
                .padding(.horizontal, 32)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("podcast.processing-progress")
            } else if episode.status == "queued" {
                queuedEpisodeView
            } else {
                ContentUnavailableView {
                    Label(L10n.string("episode_detail.bilingual_subtitles_are_not_ready_yet", fallback: "Bilingual subtitles are not ready yet"), systemImage: "hourglass")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("subtitle.error-state")
                } description: {
                    Text(episode.errorMessage ?? progressMessage)
                } actions: {
                    if cloudCheckRequired {
                        Button {
                            runner.retry(episode: episode, context: modelContext, configuration: settings.configuration)
                        } label: {
                            Label(L10n.string("episode_detail.retry", fallback: "Retry"), systemImage: "icloud.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("subtitle.cloud-retry")
                        Button {
                            runner.generateWithoutCloudCheck(
                                episode: episode,
                                context: modelContext,
                                configuration: settings.configuration
                            )
                        } label: {
                            Label(L10n.string("episodes.generate_bilingual_subtitles", fallback: "Generate bilingual subtitles"), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("subtitle.cloud-bypass")
                    } else if processingAction == .retry {
                        Button {
                            runner.retry(episode: episode, context: modelContext, configuration: settings.configuration)
                        } label: {
                            Label(L10n.string("episode_detail.retry", fallback: "Retry"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("subtitle.retry")
                        Button {
                            Task {
                                await runner.clearAndRegenerate(
                                    episode: episode,
                                    context: modelContext,
                                    configuration: settings.configuration
                                )
                            }
                        } label: {
                            Label(
                                L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("podcast.clear-and-regenerate")
                    } else if processingAction == .openSettings {
                        Button(action: openSettingsAndDismiss) {
                            Label(L10n.string("episode_detail.go_to_settings", fallback: "Go to Settings"), systemImage: "gearshape")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("podcast.open-settings")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle.error-state")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queuedEpisodeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.string("episode_detail.ready_to_process", fallback: "Ready to process"))
                .font(.title2.bold())
            Text(episode.showTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let publishedAt = episode.publishedAt {
                Text(publishedAt, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            podcastConfigurationChecklist

            Button(action: startProcessing) {
                Label(L10n.string("episode_detail.start_processing", fallback: "Start processing"), systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(processingAction != .start)
            .accessibilityIdentifier("podcast.start-processing")

            if processingAction == .openSettings {
                Button(action: openSettingsAndDismiss) {
                    Label(L10n.string("episode_detail.go_to_settings", fallback: "Go to Settings"), systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("podcast.open-settings")
            }
        }
        .padding(.horizontal, 32)
    }

    private var podcastConfigurationChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            configurationRequirement(
                L10n.string("settings.dashscope_api_key", fallback: "DashScope API Key"),
                isReady: settings.configuration.hasDashScopeASRKey
            )
            configurationRequirement(
                L10n.string("settings.translation_api_key", fallback: "Translation API Key"),
                isReady: settings.configuration.hasTranslationKey
            )
        }
        .font(.caption)
    }

    private func configurationRequirement(_ title: String, isReady: Bool) -> some View {
        Label(title, systemImage: isReady ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isReady ? LinguaTheme.success : Color.secondary)
    }
    // MARK: - Processing action and progress

    var processingAction: PodcastEpisodeProcessingAction {
        PodcastEpisodeProcessingPolicy.action(
            status: episode.status,
            hasGenerationKeys: settings.configuration.hasRequiredGenerationKeys,
            allowsCloudLookup: true
        )
    }

    var cloudCheckRequired: Bool {
        episode.pipelineStep == "cloud_check" && episode.pipelineMessage == "cloud_check_required"
    }

    func startProcessing() {
        runner.start(episode: episode, context: modelContext, configuration: settings.configuration)
    }

    func clearAndRegenerateProcessing() {
        Task {
            await runner.clearAndRegenerate(
                episode: episode,
                context: modelContext,
                configuration: settings.configuration
            )
        }
    }

    func openSettingsAndDismiss() {
        dismiss()
        onOpenSettings()
    }

    var progressValue: Double {
        min(max(episode.pipelineProgress ?? fallbackProgress(for: episode.pipelineStep), 0), 1)
    }

    var progressStepTitle: String {
        switch episode.pipelineStep {
        case "cloud_check": L10n.string("cloud.status.starting", fallback: "Checking iCloud")
        case "download": L10n.string("pipeline.step.download", fallback: "Downloading Audio")
        case "oss_upload": L10n.string("pipeline.step.upload", fallback: "Uploading Audio")
        case "transcribe": L10n.string("pipeline.step.transcribe", fallback: "Transcribing Audio")
        case "segment_source": L10n.string("pipeline.step.segment_source", fallback: "Optimizing Subtitle Breaks")
        case "translate": L10n.string("pipeline.step.translate", fallback: "Translating Subtitles")
        case "build_learning_pack": L10n.string("pipeline.step.build", fallback: "Building Subtitles")
        case "completed": L10n.string("pipeline.step.completed", fallback: "Completed")
        default: L10n.string("pipeline.step.preparing", fallback: "Preparing")
        }
    }

    private var progressMessage: String {
        ASRProgressText.display(
            message: episode.pipelineMessage,
            fallback: progressStepTitle
        )
    }

    private func fallbackProgress(for step: String) -> Double {
        switch step {
        case "cloud_check": 0.02
        case "download": 0.12
        case "oss_upload": 0.28
        case "transcribe": 0.48
        case "translate": 0.72
        case "build_learning_pack": 0.9
        case "completed": 1.0
        default: 0.05
        }
    }

    // MARK: - Subtitle loading

    func loadSegmentsForEpisode() async {
        isLoadingSegments = true
        segmentLoadError = nil
        defer { isLoadingSegments = false }

        do {
            let normalizedStep = LegacyPipelineStatusPolicy.normalizedCode(
                step: episode.pipelineStep,
                message: episode.pipelineMessage
            )
            episode.pipelineStep = normalizedStep
            if let code = LegacyPipelineStatusPolicy.code(forLegacyMessage: episode.pipelineMessage) {
                episode.pipelineMessage = code
            }
            let configuration = settings.configuration
            let target = configuration.translationTarget
            let files = try fileStore.translationFiles(episodeID: episode.id, target: target)
            let variant = try TranslationVariantRepository.getOrCreate(
                contentKind: .podcastEpisode,
                contentID: episode.id,
                target: target,
                context: modelContext
            )
            if target == .simplifiedChinese,
               try fileStore.migrateLegacySimplifiedChineseIfNeeded(episodeID: episode.id, to: files) {
                variant.segmentsPath = files.segments.fileSystemPath
            }
            try fileStore.migrateLegacyEnglishBaseIfNeeded(episodeID: episode.id)
            let episodeID = episode.id
            let legacyRecords = try modelContext.fetch(FetchDescriptor<SegmentRecord>(
                predicate: #Predicate { $0.episodeID == episodeID }
            ))
            if try fileStore.migrateLegacySegmentRecordsIfNeeded(
                legacyRecords,
                episodeID: episode.id,
                target: target,
                destination: files
            ) {
                variant.segmentsPath = files.segments.fileSystemPath
            }
            guard FileManager.default.fileExists(atPath: files.segments.fileSystemPath) else {
                let episodeFiles = try fileStore.episodeFiles(episodeID: episode.id)
                var localSourceCount = 0
                if FileManager.default.fileExists(atPath: episodeFiles.rawTranscription.fileSystemPath) {
                    let english = try await readSegments(from: episodeFiles.rawTranscription)
                    guard settings.configuration.translationTarget == target else { return }
                    segments = EpisodePlaybackSegmentPolicy.sorted(english)
                    localSourceCount = segments.count
                } else {
                    segments = []
                }
                autoResumeTranslation(
                    configuration: configuration,
                    hasLocalSource: localSourceCount > 0,
                    translatedCount: 0,
                    totalCount: localSourceCount
                )
                return
            }
            let loaded = try await readSegments(from: files.segments)
            guard settings.configuration.translationTarget == target else { return }
            let sorted = EpisodePlaybackSegmentPolicy.sorted(loaded)
            if sorted.isEmpty {
                segments = []
                segmentLoadError = L10n.string("episode_detail.there_are_no_playable_subtitles_for_this_episode_please_regenera", fallback: "There are no playable subtitles for this episode. Please regenerate bilingual subtitles.")
            } else {
                segments = sorted
                variant.segmentsPath = files.segments.fileSystemPath
                let translatedCount = sorted.filter {
                    !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count
                variant.translatedCount = translatedCount
                variant.totalCount = sorted.count
                variant.variantStatus = translatedCount == sorted.count ? .ready : .partial
                try? modelContext.save()
                if variant.variantStatus != .ready {
                    autoResumeTranslation(
                        configuration: configuration,
                        hasLocalSource: true,
                        translatedCount: translatedCount,
                        totalCount: sorted.count
                    )
                }
            }
        } catch {
            segments = []
            segmentLoadError = L10n.format("episode.error.read_subtitles", fallback: "Unable to read local subtitle file: %@", error.localizedDescription)
        }
    }

    private func autoResumeTranslation(
        configuration: AppConfiguration,
        hasLocalSource: Bool,
        translatedCount: Int,
        totalCount: Int
    ) {
        if PodcastTranslationAutoResumePolicy.shouldBypassCloudCheck(
            hasLocalSource: hasLocalSource,
            translatedCount: translatedCount,
            totalCount: totalCount
        ) {
            runner.generateWithoutCloudCheck(
                episode: episode,
                context: modelContext,
                configuration: configuration
            )
        } else {
            runner.retry(
                episode: episode,
                context: modelContext,
                configuration: configuration
            )
        }
    }

    private func readSegments(from url: URL) async throws -> [LearningSegment] {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([LearningSegment].self, from: data)
        }.value
    }

    // MARK: - Audio wiring and repair

    func loadAudioForPlayback() async {
        if loadExistingAudioForPlayback() {
            return
        }
        await repairMissingAudio()
    }

    private func loadExistingAudioForPlayback() -> Bool {
        if let files = try? fileStore.episodeFiles(episodeID: episode.id),
           isUsableAudioFile(files.sourceAudio) {
            episode.localAudioPath = files.sourceAudio.fileSystemPath
            player.load(audioURL: files.sourceAudio, segments: segments, initialTime: episode.playbackPositionSeconds)
            return true
        }
        if let value = episode.localAudioPath {
            let url = URL.storedFileURL(from: value)
            if isUsableAudioFile(url) {
                episode.localAudioPath = url.fileSystemPath
                player.load(audioURL: url, segments: segments, initialTime: episode.playbackPositionSeconds)
                return true
            }
        }
        player.errorMessage = L10n.string("episode_detail.the_local_audio_is_missing_and_is_being_downloaded_again", fallback: "The local audio is missing and is being downloaded again...")
        return false
    }

    private func repairMissingAudio() async {
        guard !isRepairingAudio else { return }
        guard let remoteURL = URL(string: episode.enclosureURL) else {
            player.errorMessage = L10n.string("episode_detail.local_audio_is_missing_and_the_program_audio_address_is_invalid", fallback: "Local audio is missing and the program audio address is invalid. Please regenerate bilingual subtitles.")
            return
        }
        isRepairingAudio = true
        defer { isRepairingAudio = false }

        do {
            let files = try fileStore.episodeFiles(episodeID: episode.id)
            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw PipelineError.badResponse(L10n.format("episode.error.audio_redownload_http", fallback: "Audio redownload failed (HTTP %@).", String(status)))
            }
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            let partial = files.directory.appending(path: "source.mp3.repair.\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: partial) }
            try? FileManager.default.removeItem(at: partial)
            do {
                try FileManager.default.copyItem(at: tempURL, to: partial)
            } catch {
                try FileManager.default.moveItem(at: tempURL, to: partial)
            }
            guard isUsableAudioFile(partial) else {
                throw PipelineError.badResponse(L10n.string("episode_detail.audio_redownload_completes_but_file_is_empty", fallback: "Audio redownload completes but file is empty."))
            }
            try? FileManager.default.removeItem(at: files.sourceAudio)
            try FileManager.default.moveItem(at: partial, to: files.sourceAudio)
            guard isUsableAudioFile(files.sourceAudio) else {
                throw PipelineError.badResponse(L10n.string("episode_detail.audio_file_writing_failed", fallback: "Audio file writing failed."))
            }
            episode.localAudioPath = files.sourceAudio.fileSystemPath
            try? modelContext.save()
            player.load(audioURL: files.sourceAudio, segments: segments, initialTime: episode.playbackPositionSeconds)
        } catch {
            player.errorMessage = L10n.format("episode.error.audio_redownload", fallback: "Local audio redownload failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Playback progress persistence

    func persistPlaybackProgress(_ currentTime: TimeInterval, force: Bool = false) {
        let now = Date()
        guard let position = PlaybackProgressPolicy.positionToPersist(
            currentTime: currentTime,
            lastPersistedTime: lastPersistedPlaybackTime,
            lastPersistedAt: lastPersistedPlaybackAt,
            now: now,
            force: force
        ) else { return }
        episode.playbackPositionSeconds = position
        episode.playbackUpdatedAt = now
        markCompletedIfThresholdReached(position: position, now: now)
        episode.updatedAt = now
        lastPersistedPlaybackTime = position
        lastPersistedPlaybackAt = now
        try? modelContext.save()
        syncPlaybackProgress(position: position, now: now)
    }

    // Forwards the persisted progress to iCloud sync. The coordinator derives the stable
    // cross-device identity and the playable catalog snapshot from the domain records.
    private func syncPlaybackProgress(position: TimeInterval, now: Date) {
        guard let subscriptionID = episode.subscriptionID else { return }
        let subscription = try? modelContext.fetch(
            FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.id == subscriptionID })
        ).first
        guard let subscription, !subscription.showURL.isEmpty else { return }
        CloudSyncCoordinator.shared.recordPlaybackProgress(
            episode: episode,
            subscription: subscription,
            positionSeconds: position,
            durationSeconds: episode.playbackDurationSeconds,
            completedAt: episode.playbackCompletedAt,
            modifiedAt: now
        )
    }

    func persistPlaybackDurationIfNeeded(_ mediaDuration: TimeInterval? = nil) {
        let duration = mediaDuration ?? inferredDuration ?? 0
        guard duration.isFinite, duration > 0 else { return }
        if let existing = episode.playbackDurationSeconds,
           abs(existing - duration) < 0.5 {
            return
        }
        episode.playbackDurationSeconds = duration
        episode.updatedAt = Date()
        try? modelContext.save()
    }

    private var inferredDuration: TimeInterval? {
        EpisodePlaybackSegmentPolicy.inferredDuration(from: segments)
    }

    private func markCompletedIfThresholdReached(position: TimeInterval, now: Date) {
        guard episode.playbackCompletedAt == nil else { return }
        let category = PlaybackListPolicy.category(
            playbackPosition: position,
            duration: episode.playbackDurationSeconds,
            completedAt: nil
        )
        if category == .played {
            episode.playbackCompletedAt = now
        }
    }

    private func isUsableAudioFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else {
            return false
        }
        return true
    }

    // MARK: - Scene phase (lock / background resume)

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .inactive, .background:
            suspendPlaybackForScenePhase()
        case .active:
            guard hasSuspendedForScenePhase else { return }
            hasSuspendedForScenePhase = false
            rebuildPlayableStateAfterForeground()
        @unknown default:
            break
        }
    }

    private func suspendPlaybackForScenePhase() {
        guard episode.status == "completed" else { return }
        hasSuspendedForScenePhase = true
        restoreFollowOnNextPlay = true
        persistPlaybackProgress(player.currentTime, force: true)
        if player.isPlaying {
            player.pausePlayback()
        }
        let resumeTime = episode.playbackPositionSeconds ?? player.currentTime
        player.prepareResume(at: resumeTime)
    }

    /// Rebuild a playable player at the saved position after unlock / foreground.
    /// Does not autoplay — the user must tap play (which seeks then starts).
    func rebuildPlayableStateAfterForeground() {
        guard episode.status == "completed", !segments.isEmpty else { return }
        let resumeTime = episode.playbackPositionSeconds ?? player.currentTime
        if loadExistingAudioForPlayback() {
            player.prepareResume(at: resumeTime)
        } else {
            player.prepareResume(at: resumeTime)
            player.refreshActiveSequence()
            Task { await repairMissingAudio() }
        }
    }

    /// After the first play following lock/unlock, re-enable subtitle follow and scroll.
    func handlePlaybackStarted() {
        guard restoreFollowOnNextPlay else { return }
        restoreFollowOnNextPlay = false
        updateTranscriptFollowing(after: .locatePlayback)
        locatePlaybackRequest += 1
    }

    // MARK: - Follow and scroll

    // Anchor used when auto-scrolling to the active transcript row. The active row can be
    // several lines tall (English + optional translation + speaker label), and centering a
    // tall row can clip its top or bottom. A top-biased unit-point anchor places the row top
    // at y * (viewportHeight - rowHeight), so any row shorter than the viewport stays fully
    // visible; a row taller than the viewport keeps its top visible instead of clipping both
    // ends. y = 1/3 keeps the whole active sentence in the upper-third reading zone with
    // breathing room below the navigation bar (a 0.25 anchor pushed tall rows under the top
    // chrome, clipping the English line). Shared by iOS (ScrollViewProxy.scrollTo) and tvOS
    // (.scrollPosition anchor).
    var activeTranscriptScrollAnchor: UnitPoint { UnitPoint(x: 0.5, y: 1.0 / 3.0) }

    func locateCurrentPlayback() {
        updateTranscriptFollowing(after: .locatePlayback)
        locatePlaybackRequest += 1
    }

    func updateTranscriptFollowing(after event: TranscriptFollowEvent) {
        let nextValue = TranscriptFollowPolicy.isFollowing(
            after: event,
            wasFollowing: isFollowingPlayback
        )
        guard nextValue != isFollowingPlayback else { return }
        isFollowingPlayback = nextValue
    }

    func shouldShowSpeaker(at index: Int) -> Bool {
        let speaker = segments[index].speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker, !speaker.isEmpty else { return false }
        guard index > 0 else { return true }
        return segments[index - 1].speaker?.trimmingCharacters(in: .whitespacesAndNewlines) != speaker
    }

    func scrollToSequence(_ sequence: Int?) {
        guard let sequence else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollPositionSequence = sequence
        }
    }
}
