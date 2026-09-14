import Foundation
import PodcastEnglishStudioCore

/// Shared local-audio → DashScope ASR → acoustic/semantic segmentation path.
/// Used by podcast PipelineRunner and YouTube audio-ASR fallback.
struct LocalAudioASRPipeline {
    var transcriptionClient = DashScopeTranscriptionClient()

    func transcribeAndSegment(
        audioURL: URL,
        apiKey: String,
        checkpointURL: URL,
        downloadedResultURL: URL,
        onStage: (@MainActor (DashScopeTranscriptionStage) async -> Void)? = nil
    ) async throws -> [LearningSegment] {
        let checkpointStore = DashScopeCheckpointStore(fileURL: checkpointURL)
        var segments = try await transcriptionClient.transcribe(
            audioURL: audioURL,
            apiKey: apiKey,
            checkpointStore: checkpointStore,
            downloadedResultURL: downloadedResultURL
        ) { stage in
            if let onStage {
                await onStage(stage)
            }
        }
        segments = segments.map { segment in
            var value = segment
            value.translation = ""
            return value
        }
        segments = TimedTextSentenceSegmenter.resegmentLearningSegments(segments)
        try? checkpointStore.remove()
        try? FileManager.default.removeItem(at: downloadedResultURL)
        return segments
    }
}
