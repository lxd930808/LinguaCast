import Foundation
import PodcastEnglishStudioCore
import CloudSyncKit

struct YTCaptionPackage {
    var englishVTT: String
    var translatedVTT: String
    var segments: [LearningSegment]
}

/// App-facing caption service: Core fetch engine + LLM translation.
final class YTCaptionService {
    private let fetchService: PodcastEnglishStudioCore.YTCaptionService
    private let translator: TranslationClient

    init(
        session: URLSession? = nil,
        translator: TranslationClient = TranslationClient(),
        coordinator: YTCaptionRequestCoordinator? = nil,
        stateStore: YTCaptionRequestStateStoring? = nil,
        clock: YTCaptionClock? = nil,
        jitter: YTCaptionJitterSource? = nil
    ) {
        self.fetchService = PodcastEnglishStudioCore.YTCaptionService(
            session: session,
            coordinator: coordinator,
            stateStore: stateStore,
            clock: clock,
            jitter: jitter
        )
        self.translator = translator
    }

    func fetchCaptionPackage(
        videoID: String,
        configuration: AppConfiguration,
        ingestionPolicy: YTCaptionIngestionPolicy = .strict
    ) async throws -> YTCaptionPackage {
        let englishPackage = try await fetchEnglishCaptionPackage(
            videoID: videoID,
            configuration: configuration,
            ingestionPolicy: ingestionPolicy
        )
        let translatedVTT = try await translateVTT(
            from: englishPackage.segments,
            target: configuration.translationTarget,
            configuration: configuration
        )
        return YTCaptionPackage(
            englishVTT: englishPackage.englishVTT,
            translatedVTT: translatedVTT,
            segments: englishPackage.segments
        )
    }

    func fetchEnglishCaptionPackage(
        videoID: String,
        configuration: AppConfiguration,
        ingestionPolicy: YTCaptionIngestionPolicy = .strict
    ) async throws -> YTEnglishCaptionPackage {
        try await fetchService.fetchEnglishCaptionPackage(
            videoID: videoID,
            qualityTolerance: configuration.captionQualityOutlierTolerancePercent,
            pipelineVersion: SubtitlePipelineVersion.current,
            ingestionPolicy: ingestionPolicy
        )
    }

    func fetchNativeChineseVTT(videoID: String) async throws -> String {
        try await fetchService.fetchNativeChineseVTT(videoID: videoID)
    }

    func fetchAutoTranslatedChineseVTT(videoID: String) async throws -> String {
        try await fetchService.fetchAutoTranslatedChineseVTT(videoID: videoID)
    }

    func translateVTT(
        from segments: [LearningSegment],
        target: TranslationTarget,
        configuration: AppConfiguration
    ) async throws -> String {
        try await translateVTTIncrementally(from: segments, target: target, configuration: configuration) { _, _ in }
    }

    func translateVTTIncrementally(
        from segments: [LearningSegment],
        target: TranslationTarget,
        configuration: AppConfiguration,
        onProgress: @MainActor ([LearningSegment], String) async throws -> Void
    ) async throws -> String {
        guard !configuration.translationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.missingConfiguration("translation API key")
        }
        let translated = try await translator.translateIncrementally(
            segments,
            target: target,
            configuration: configuration
        ) { partialSegments in
            let translatedCues = partialSegments.compactMap { segment -> YTCue? in
                let text = segment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return YTCue(
                    id: segment.sequence,
                    start: TimeInterval(segment.startMS) / 1000,
                    end: TimeInterval(segment.endMS) / 1000,
                    text: text
                )
            }
            let partialVTT = YTVTTParser.makeVTT(from: translatedCues)
            try await onProgress(partialSegments, partialVTT)
        }
        return YTVTTParser.makeVTT(from: YTVTTParser.cues(from: translated))
    }
}

extension YTCaptionError {
    var localizedUserMessage: String {
        switch self {
        case .missingEnglishTrack:
            return L10n.string("error.caption_missing_english", fallback: "This video has no available English caption track.")
        case .emptyCaptionFile:
            return L10n.string("error.caption_invalid", fallback: "The caption file is empty or could not be parsed.")
        case .emptyCaptionResponse:
            return L10n.string("error.caption_empty_response", fallback: "YouTube returned a caption track without caption content. Try another video.")
        case .captionQualityRejected:
            return L10n.string(
                "error.caption_quality_rejected",
                fallback: "The English caption track failed quality checks and cannot be used. Try another video."
            )
        case .rateLimited(let retryAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return L10n.format(
                "error.caption_rate_limited",
                fallback: "YouTube caption requests are rate limited. Try again after %@.",
                formatter.string(from: retryAt)
            )
        case .attestationRequired:
            return L10n.string(
                "error.caption_attestation_required",
                fallback: "The current caption track requires additional verification."
            )
        case .accessBlocked:
            return L10n.string(
                "error.caption_access_blocked",
                fallback: "YouTube blocked the caption request. Try again later."
            )
        case .httpFailure:
            return L10n.string(
                "error.caption_empty_response",
                fallback: "YouTube returned a caption track without caption content. Try another video."
            )
        }
    }
}
