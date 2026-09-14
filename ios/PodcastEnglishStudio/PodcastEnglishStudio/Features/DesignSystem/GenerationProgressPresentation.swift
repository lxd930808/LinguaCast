import Foundation
import PodcastEnglishStudioCore

/// Shared entry point for podcast, video and assistant progress labels.
enum YTSourceGenerationProgressText {
    static func title(
        step: String?, progress: Double?, downloadProgress: Double? = nil,
        bytesPerSecond: Double? = nil, completedCount: Int? = nil, totalCount: Int? = nil,
        hidesZeroProgress: Bool = false
    ) -> String? {
        GenerationProgressPresentation.title(
            step: step, progress: progress, downloadProgress: downloadProgress,
            bytesPerSecond: bytesPerSecond, completedCount: completedCount, totalCount: totalCount,
            hidesZeroProgress: hidesZeroProgress,
            localize: { L10n.string($0, fallback: $1) }
        )
    }
}
