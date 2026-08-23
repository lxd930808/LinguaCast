import Foundation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels

/// Repairs podcast episodes left in a persisted `running` state even though their
/// translation already finished and was written to disk. This is the reconciliation
/// half of the completion-bug fix: the pipeline now commits completion atomically,
/// but episodes orphaned by an earlier crash / force-quit / target switch still sit
/// at `running / build_learning_pack` with a fully translated variant beside them.
///
/// The scan is intentionally read-only apart from the single promoted `completed`
/// write per episode: it never calls the translation API, never re-downloads audio,
/// and refuses to promote anything that fails an integrity gate (see
/// `PodcastCompletionReconciliationPolicy`). It runs at app launch and on foreground
/// re-entry so the play page recovers in the current process without a restart.
///
/// Promoted orphans are stamped `displayRefinementStatus = pending` so the background
/// refiner can finish long-sentence display splits without blocking playback.
@MainActor
struct PodcastCompletionReconciler {
    private let fileStore: LocalFileStore

    init(fileStore: LocalFileStore = LocalFileStore()) {
        self.fileStore = fileStore
    }

    /// Promotes every `running` episode whose current-target translation is complete
    /// and valid to `completed`. Returns the number of episodes repaired.
    @discardableResult
    func reconcileRunningEpisodes(context: ModelContext) -> Int {
        let running = (try? context.fetch(FetchDescriptor<EpisodeRecord>(
            predicate: #Predicate { $0.status == "running" }
        ))) ?? []
        var repaired = 0
        for episode in running where reconcile(episode: episode, context: context) {
            repaired += 1
        }
        if repaired > 0 {
            try? context.save()
        }
        return repaired
    }

    /// Attempts to promote a single episode. Returns `true` when it was repaired.
    @discardableResult
    func reconcile(episode: EpisodeRecord, context: ModelContext) -> Bool {
        guard episode.status == "running" else { return false }
        guard let activeTarget = activeTarget(for: episode) else { return false }
        let files: TranslationVariantFiles
        do {
            files = try fileStore.translationFiles(episodeID: episode.id, target: activeTarget)
        } catch {
            return false
        }
        let manifest = try? fileStore.readJSON(TranslationArtifactManifest.self, from: files.manifest)
        let segments = (try? fileStore.readJSON([LearningSegment].self, from: files.segments)) ?? []
        let input = PodcastCompletionReconciliationPolicy.Input(
            activeTarget: activeTarget,
            artifactTarget: activeTarget,
            manifestStatus: manifest?.status,
            pipelineVersion: manifest?.pipelineVersion,
            segmentCount: segments.count,
            translatedCount: segments.filter {
                !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count,
            manifestFingerprint: manifest?.sourceFingerprint,
            segmentsFingerprint: segments.isEmpty ? nil : TranscriptionFingerprint.make(segments: segments),
            sourceFingerprint: sourceFingerprint(for: episode)
        )
        guard PodcastCompletionReconciliationPolicy.shouldComplete(input) else { return false }

        promoteToCompleted(
            episode: episode,
            activeTarget: activeTarget,
            files: files,
            segments: segments,
            existingManifest: manifest,
            context: context
        )
        return true
    }

    private func promoteToCompleted(
        episode: EpisodeRecord,
        activeTarget: TranslationTarget,
        files: TranslationVariantFiles,
        segments: [LearningSegment],
        existingManifest: TranslationArtifactManifest?,
        context: ModelContext
    ) {
        let now = Date()
        episode.status = "completed"
        episode.pipelineStep = "completed"
        episode.pipelineProgress = 1.0
        episode.pipelineMessage = "completed"
        episode.errorMessage = nil
        episode.updatedAt = now

        // Keep the variant consistent with the on-disk artifacts it points at.
        if let variant = try? TranslationVariantRepository.find(
            contentKind: .podcastEpisode,
            contentID: episode.id,
            target: activeTarget,
            context: context
        ) {
            variant.variantStatus = .ready
            variant.segmentsPath = files.segments.fileSystemPath
            variant.translatedCount = segments.count
            variant.totalCount = segments.count
            variant.errorCode = nil
            variant.technicalDetails = nil
            variant.updatedAt = now
        }

        // Bring the file-based pipeline manifest to the terminal state too; previously
        // it stayed one step behind (running / build_learning_pack) even on success.
        if let episodeFiles = try? fileStore.episodeFiles(episodeID: episode.id) {
            try? fileStore.writeJSON(
                PipelineManifest(
                    episodeID: episode.id,
                    status: "completed",
                    currentStep: "completed",
                    updatedAt: now,
                    error: nil,
                    artifacts: ["source_audio": episodeFiles.sourceAudio.fileSystemPath]
                ),
                to: episodeFiles.manifest
            )
        }

        // Stamp the translation manifest ready. Orphans from mid-refinement / pre-refine
        // crashes need pending refinement; older ready manifests without the field stay
        // completed. Prefer preserving an existing fingerprint over recomputing from
        // possibly already-split texts.
        let fingerprint = existingManifest?.sourceFingerprint
            ?? (segments.isEmpty ? nil : TranscriptionFingerprint.make(segments: segments))
        let existingRefinement = DisplayRefinementManifestPolicy.effectiveStatus(
            from: existingManifest?.displayRefinementStatus
        )
        let needsRefine = DisplayRefinementPlanner.needsRefinement(segments)
        // If the orphan still looks like unsplit base segments, mark pending. If the
        // field was already completed (or absent on a ready stamp with no candidates),
        // leave it completed.
        let refinement: DisplayRefinementStatus = {
            if existingManifest?.status == TranslationVariantStatus.ready.rawValue,
               existingManifest?.displayRefinementStatus == nil,
               !needsRefine {
                return .completed
            }
            if DisplayRefinementManifestPolicy.needsResume(existingRefinement) {
                return existingRefinement
            }
            return needsRefine ? .pending : .completed
        }()
        let total = DisplayRefinementPlanner.candidateIndices(in: segments).count
        try? fileStore.writeJSON(
            TranslationArtifactManifest(
                contentKind: TranslationContentKind.podcastEpisode.rawValue,
                contentID: episode.id,
                targetLanguage: activeTarget.rawValue,
                status: TranslationVariantStatus.ready.rawValue,
                updatedAt: now,
                artifacts: ["segments": files.segments.fileSystemPath],
                sourceFingerprint: fingerprint,
                pipelineVersion: existingManifest?.pipelineVersion ?? SubtitlePipelineVersion.current,
                displayRefinementStatus: refinement.rawValue,
                displayRefinementCompletedCount: refinement == .completed ? total : 0,
                displayRefinementTotalCount: total
            ),
            to: files.manifest
        )
    }

    private func activeTarget(for episode: EpisodeRecord) -> TranslationTarget? {
        guard let raw = episode.activeTranslationTargetLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let target = TranslationTarget(rawValue: raw)
        else { return nil }
        return target
    }

    /// Fingerprint of the episode's English base transcription, when one exists on disk.
    private func sourceFingerprint(for episode: EpisodeRecord) -> String? {
        guard let episodeFiles = try? fileStore.episodeFiles(episodeID: episode.id),
              FileManager.default.fileExists(atPath: episodeFiles.rawTranscription.fileSystemPath),
              let raw = try? fileStore.readJSON([LearningSegment].self, from: episodeFiles.rawTranscription),
              !raw.isEmpty
        else { return nil }
        return TranscriptionFingerprint.make(segments: raw)
    }
}
