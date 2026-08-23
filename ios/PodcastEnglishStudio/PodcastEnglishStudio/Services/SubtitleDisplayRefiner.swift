import Foundation
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

/// Background display sub-clause refinement. Runs after a podcast translation is already
/// `ready/completed` so long-sentence splitting never blocks playback. Checkpoints per
/// concurrent batch; cancel / process exit leave refinement pending for the next launch.
@MainActor
final class SubtitleDisplayRefiner {
    private let fileStore: LocalFileStore
    private let translationClient: TranslationClient
    private let subtitleSync: SubtitleArtifactSyncing

    init(
        fileStore: LocalFileStore = LocalFileStore(),
        translationClient: TranslationClient = TranslationClient(),
        subtitleSync: SubtitleArtifactSyncing? = nil
    ) {
        self.fileStore = fileStore
        self.translationClient = translationClient
        self.subtitleSync = subtitleSync ?? CloudSyncCoordinator.shared
    }

    /// Refine display sub-clauses for an already-playable translation. On success, atomically
    /// replaces `segments.json`, stamps the manifest completed, and publishes the final cloud
    /// artifact. Cancellation and file-level errors leave checkpoint + pending status; the
    /// episode stays completed.
    func refine(
        episodeID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        sourceFingerprint: String,
        artifactIdentity: SubtitleArtifactIdentity?,
        updateManifest: (DisplayRefinementStatus, Int, Int) throws -> Void
    ) async throws {
        let files = try fileStore.translationFiles(episodeID: episodeID, target: target)
        let original = try fileStore.readJSON([LearningSegment].self, from: files.segments)
        let candidates = DisplayRefinementPlanner.candidateIndices(in: original)
        let total = candidates.count
        guard total > 0 else {
            try updateManifest(.completed, 0, 0)
            try? fileStore.removeIfExists(files.displayRefinementCheckpoint)
            if let artifactIdentity {
                try? await subtitleSync.publishReady(
                    identity: artifactIdentity,
                    segments: original,
                    generatedAt: Date()
                )
            }
            return
        }

        try updateManifest(.running, completedCount(from: files, fingerprint: sourceFingerprint), total)

        var checkpoint = loadCheckpoint(at: files.displayRefinementCheckpoint, fingerprint: sourceFingerprint)
            ?? DisplayRefinementCheckpoint(sourceFingerprint: sourceFingerprint)
        var refinedBySequence = checkpoint.resultsBySequence

        let pending = original.filter { segment in
            SubtitleDisplaySplitPolicy.isRefinementCandidate(segment)
                && refinedBySequence[segment.sequence] == nil
        }
        let maxConcurrent = TranslationConcurrencyPolicy.maxConcurrentRequests(
            forProvider: configuration.translationProvider
        )

        var nextIndex = 0
        try await withThrowingTaskGroup(of: DisplayRefinementCheckpointEntry.self) { group in
            func enqueueNext() {
                guard nextIndex < pending.count else { return }
                let segment = pending[nextIndex]
                nextIndex += 1
                group.addTask {
                    let pieces = try await self.splitIntoDisplaySubClauses(
                        segment: segment,
                        target: target,
                        configuration: configuration
                    )
                    return DisplayRefinementCheckpointEntry(
                        originalSequence: segment.sequence,
                        segments: pieces
                    )
                }
            }

            for _ in 0..<min(maxConcurrent, pending.count) {
                enqueueNext()
            }

            var batchEntries: [DisplayRefinementCheckpointEntry] = []
            while let entry = try await group.next() {
                batchEntries.append(entry)
                refinedBySequence[entry.originalSequence] = entry.segments
                enqueueNext()

                // Persist after each completed work item so a kill mid-batch loses at most one
                // in-flight candidate; concurrent siblings still flush as they finish.
                checkpoint.entries = refinedBySequence.keys.sorted().compactMap { sequence in
                    guard let segments = refinedBySequence[sequence] else { return nil }
                    return DisplayRefinementCheckpointEntry(
                        originalSequence: sequence,
                        segments: segments
                    )
                }
                try fileStore.writeJSON(checkpoint, to: files.displayRefinementCheckpoint)
                try updateManifest(.running, checkpoint.entries.count, total)
            }
        }

        let assembled = LearningPackBuilder.buildPack(
            segments: DisplayRefinementPlanner.assemble(
                original: original,
                refinedBySequence: refinedBySequence
            )
        ).segments
        try fileStore.writeJSON(assembled, to: files.segments)
        try updateManifest(.completed, total, total)
        try? fileStore.removeIfExists(files.displayRefinementCheckpoint)

        if let artifactIdentity {
            try? await subtitleSync.publishReady(
                identity: artifactIdentity,
                segments: assembled,
                generatedAt: Date()
            )
        }
    }

    private func completedCount(from files: TranslationVariantFiles, fingerprint: String) -> Int {
        loadCheckpoint(at: files.displayRefinementCheckpoint, fingerprint: fingerprint)?.entries.count ?? 0
    }

    private func loadCheckpoint(
        at url: URL,
        fingerprint: String
    ) -> DisplayRefinementCheckpoint? {
        guard let checkpoint = try? fileStore.readJSON(DisplayRefinementCheckpoint.self, from: url),
              checkpoint.sourceFingerprint == fingerprint
        else { return nil }
        return checkpoint
    }

    /// Recursively split one translated segment into display sub-clauses (bounded by
    /// `SubtitleDisplaySplitPolicy.maxRecursionDepth`). Returns `[segment]` unchanged when no
    /// split is required or possible. Permanent model failures keep the whole sentence.
    private func splitIntoDisplaySubClauses(
        segment: LearningSegment,
        target: TranslationTarget,
        configuration: AppConfiguration,
        depth: Int = 0
    ) async throws -> [LearningSegment] {
        let source = segment.text
        let translation = segment.translation
        guard depth < SubtitleDisplaySplitPolicy.maxRecursionDepth,
              SubtitleDisplaySplitPolicy.requiresDisplaySplit(source: source, translation: translation),
              !segment.words.isEmpty else {
            return [segment]
        }

        guard let cut = TimedTextSentenceSegmenter.bestBinarySplit(
            segment.words,
            profile: .podcast
        ), cut > 0, cut < segment.words.count else {
            return [segment]
        }

        let leftWords = Array(segment.words[..<cut])
        let rightWords = Array(segment.words[cut...])
        let sourcePieces = [
            TimedTextSentenceSegmenter.renderText(leftWords),
            TimedTextSentenceSegmenter.renderText(rightWords)
        ]
        guard sourcePieces.allSatisfy({ !$0.isEmpty }) else {
            return [segment]
        }

        guard let translationPieces = try await translationClient.splitTranslation(
            translation,
            intoPartCount: sourcePieces.count,
            target: target,
            configuration: configuration
        ), translationPieces.count == sourcePieces.count else {
            return [segment]
        }

        let playback = PlaybackSentence(
            id: segment.sequence,
            text: source,
            translation: translation,
            startMS: segment.playbackStartMS,
            endMS: segment.playbackEndMS
        )

        let wordSlices = [leftWords, rightWords]
        var result: [LearningSegment] = []
        for index in sourcePieces.indices {
            let slice = wordSlices[index]
            var sub = segment
            sub.startMS = slice.first?.startMS ?? segment.startMS
            sub.endMS = max(slice.last?.endMS ?? segment.endMS, (slice.first?.startMS ?? segment.startMS) + 1)
            sub.text = sourcePieces[index]
            sub.learningText = sourcePieces[index]
            sub.translation = translationPieces[index]
            sub.words = slice
            sub.timingSource = .wordTimeline
            sub.playbackSentence = playback
            let further = try await splitIntoDisplaySubClauses(
                segment: sub,
                target: target,
                configuration: configuration,
                depth: depth + 1
            )
            result.append(contentsOf: further)
        }
        return result
    }
}

private extension LocalFileStore {
    func removeIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.fileSystemPath) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
