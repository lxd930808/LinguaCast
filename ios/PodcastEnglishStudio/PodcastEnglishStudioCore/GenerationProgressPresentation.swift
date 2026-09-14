import Foundation

/// Presentation-only normalization; persisted pipeline states remain unchanged.
public enum GenerationProgressPresentation {
    public static func stage(_ raw: String) -> (key: String, fallback: String) {
        switch raw {
        case "queued", "requested", "waitingService":
            return ("cloud.stage.queued", "Queued on the server")
        case "download", "downloading", "fetching_audio":
            return ("pipeline.step.download", "Downloading Audio")
        case "oss_upload", "uploading", "asr_preparing_upload", "asr_uploading_audio":
            return ("pipeline.step.upload", "Uploading Audio")
        case "transcribe", "transcribing", "asr_submitting", "asr_polling", "asr_downloading_result", "asr_parsing_result":
            return ("pipeline.step.transcribe", "Transcribing Audio")
        case "segment_source", "segmenting", "refine_subtitles", "refining_subtitles":
            return ("pipeline.step.segment_source", "Optimizing Subtitle Breaks")
        case "translate", "translating":
            return ("pipeline.step.translate", "Translating Subtitles")
        case "build_learning_pack", "packaging", "package":
            return ("pipeline.step.build", "Building Subtitles")
        case "completed":
            return ("pipeline.step.completed", "Completed")
        case "expired":
            return ("cloud.stage.expired", "Expired on the server")
        default:
            return ("pipeline.step.preparing", "Preparing")
        }
    }

    public static func title(
        step: String?, progress: Double?, downloadProgress: Double? = nil,
        bytesPerSecond: Double? = nil, completedCount: Int? = nil, totalCount: Int? = nil,
        hidesZeroProgress: Bool = false,
        localize: (String, String) -> String
    ) -> String? {
        guard let step, !step.isEmpty else { return nil }
        let stage = stage(step)
        var parts = [localize(stage.key, stage.fallback)]
        let isDownload = ["download", "downloading", "fetching_audio"].contains(step)
        let isTerminal = ["completed", "expired"].contains(step)
        let isQueued = ["queued", "requested", "waitingService"].contains(step)
        if !isTerminal && !isQueued {
            if let completedCount, let totalCount, totalCount > 0,
               completedCount >= 0, completedCount <= totalCount {
                parts.append("\(completedCount) / \(totalCount)")
            } else if let fraction = validFraction(isDownload ? (downloadProgress ?? progress) : progress),
                      !hidesZeroProgress || fraction > 0 {
                parts.append("\(Int((fraction * 100).rounded()))%")
            }
            if isDownload, let bytesPerSecond, bytesPerSecond.isFinite,
               bytesPerSecond > 0, bytesPerSecond < Double(Int64.max) {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useKB, .useMB, .useGB]
                formatter.countStyle = .file
                parts.append("\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s")
            }
        }
        return parts.joined(separator: " · ")
    }

    public static func validFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
}
