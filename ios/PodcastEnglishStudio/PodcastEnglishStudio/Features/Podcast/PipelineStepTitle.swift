import Foundation
import PodcastEnglishStudioCore

enum PipelineStepTitle {
    static func display(_ step: String) -> String {
        let stage = GenerationProgressPresentation.stage(step)
        return L10n.string(stage.key, fallback: stage.fallback)
    }
}
