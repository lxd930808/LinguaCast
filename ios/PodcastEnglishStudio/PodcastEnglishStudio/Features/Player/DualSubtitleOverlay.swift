import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

@Observable
final class YTSubtitleDisplayState {
    /// Single timeline: English text and translation are always paired on one segment.
    var segments: [LearningSegment] = []
    var errorMessage: String?
    var cloudCheckRequired = false
    var canGenerateFromAudio = false
    /// Bumped by settings/other CTAs to trigger DualSubtitleOverlay audio ASR.
    var generateFromAudioRequestID = 0
    var audioDownloadProgress: Double?
    var audioDownloadBytesPerSecond: Double?
    var playbackTime: TimeInterval = 0

    func segment(at time: TimeInterval) -> LearningSegment? {
        let timeMS = Int((time * 1000).rounded())
        return segments.first { timeMS >= $0.startMS && timeMS <= $0.endMS }
    }

    func requestGenerateFromAudio() {
        canGenerateFromAudio = true
        generateFromAudioRequestID += 1
    }

    func resetAudioDownloadMetrics() {
        audioDownloadProgress = nil
        audioDownloadBytesPerSecond = nil
    }
}

struct DualSubtitleOverlay: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    var video: YTVideoRecord
    var currentTime: TimeInterval
    var subtitleState: YTSubtitleDisplayState
    var showsDisplay = true

    @State private var localService = YTLocalService()
    @State private var loadingSubtitleKeys: Set<String> = []
    @State private var loadedSubtitleKey: String?
    @State private var retryGeneration = 0
    @State private var bypassCloudCheck = false
    @State private var generateFromAudio = false
    @State private var isGeneratingFromAudio = false

    private var currentSegment: LearningSegment? {
        subtitleState.segment(at: currentTime)
    }

    private var generationProgressText: String? {
        YTSourceGenerationProgressText.title(
            step: video.sourceGenerationStep,
            progress: video.sourceGenerationProgress,
            downloadProgress: subtitleState.audioDownloadProgress,
            bytesPerSecond: subtitleState.audioDownloadBytesPerSecond
        )
    }

    private var generationProgressValue: Double? {
        if video.sourceGenerationStep == "downloading" {
            return subtitleState.audioDownloadProgress
        }
        return video.sourceGenerationProgress
    }

    var body: some View {
        display
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        // Keep interactive CTAs above sibling overlays for reliable hit testing.
        .zIndex(subtitleState.canGenerateFromAudio || subtitleState.cloudCheckRequired ? 2 : 0)
        .task(id: "\(subtitleKey):\(retryGeneration):\(generateFromAudio)") {
            let configuration = settings.configuration
            if generateFromAudio {
                await runAudioASR(configuration: configuration)
            } else {
                await loadSubtitles(key: subtitleKey, configuration: configuration)
            }
        }
        .onChange(of: subtitleState.generateFromAudioRequestID) { _, requestID in
            guard requestID > 0 else { return }
            startAudioASR()
        }
        .onAppear {
            recoverFromStaleSourceGenerationState()
        }
    }

    @ViewBuilder
    private var display: some View {
        if showsDisplay && settings.committedConfiguration.subtitleDisplayMode != "off" {
            YTSubtitleDisplayView(
                english: currentSegment?.text,
                translation: currentSegment?.translation.nilIfEmpty,
                errorMessage: subtitleState.errorMessage,
                isPreparing: (subtitleState.errorMessage == nil
                    && currentSegment == nil
                    && subtitleState.segments.isEmpty)
                    || isGeneratingFromAudio
                    || (video.sourceGenerationStep != nil
                        && video.subtitleStatus != "ready"
                        && video.subtitleStatus != "failed"),
                preparingMessage: generationProgressText,
                preparingProgress: isGeneratingFromAudio || video.sourceGenerationStep != nil
                    ? generationProgressValue
                    : nil,
                preferences: settings.committedSubtitlePresentation,
                displayMode: settings.committedConfiguration.subtitleDisplayMode,
                onRetryCloud: subtitleState.cloudCheckRequired ? retryCloudCheck : nil,
                onGenerateAnyway: subtitleState.cloudCheckRequired ? generateAnyway : nil,
                onGenerateFromAudio: subtitleState.canGenerateFromAudio ? startAudioASR : nil
            )
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Caption ingestion policy resolved from the committed configuration through the
    /// same effective-playback-mode interface the player uses. Unsaved Settings drafts
    /// never change subtitle loading.
    private var captionIngestionPolicy: YTCaptionIngestionPolicy {
        IOSYouTubePlaybackMode.effective(
            configured: settings.committedConfiguration.youTubePlaybackMode
        ).captionIngestionPolicy
    }

    private var subtitleKey: String {
        "\(video.id):\(settings.configuration.translationTargetLanguage):\(captionIngestionPolicy.rawValue)"
    }

    private func loadSubtitles(key: String, configuration: AppConfiguration) async {
        if loadingSubtitleKeys.contains(key) { return }
        if loadedSubtitleKey == key, !subtitleState.segments.isEmpty {
            return
        }
        loadingSubtitleKeys.insert(key)
        defer { loadingSubtitleKeys.remove(key) }
        if settings.configuration.translationTarget == configuration.translationTarget {
            subtitleState.errorMessage = nil
            subtitleState.cloudCheckRequired = false
            subtitleState.canGenerateFromAudio = false
        }
        do {
            print("DualSubtitleOverlay: loading subtitles for \(video.id)")
            let segments = try await localService.ensureSubtitles(
                video: video,
                configuration: configuration,
                context: modelContext,
                bypassCloudCheck: bypassCloudCheck,
                captionIngestionPolicy: captionIngestionPolicy
            ) { partial in
                guard settings.configuration.translationTarget == configuration.translationTarget else { return }
                subtitleState.segments = partial
                subtitleState.errorMessage = nil
                subtitleState.cloudCheckRequired = false
                subtitleState.canGenerateFromAudio = false
            }
            bypassCloudCheck = false
            guard settings.configuration.translationTarget == configuration.translationTarget else { return }
            subtitleState.segments = segments
            loadedSubtitleKey = key
            print("DualSubtitleOverlay: loaded subtitles for \(video.id), segments=\(segments.count)")
        } catch {
            guard AsyncOperationErrorPresentationPolicy.shouldPresent(error) else { return }
            print("DualSubtitleOverlay: subtitle load failed for \(video.id): \(error.localizedDescription)")
            if settings.configuration.translationTarget == configuration.translationTarget {
                subtitleState.errorMessage = error.localizedDescription
                subtitleState.cloudCheckRequired = error is CloudSubtitleLookupError
                subtitleState.canGenerateFromAudio = YTLocalService.canGenerateFromAudio(after: error)
            }
        }
    }

    private func runAudioASR(configuration: AppConfiguration) async {
        guard !isGeneratingFromAudio else { return }
        isGeneratingFromAudio = true
        defer {
            isGeneratingFromAudio = false
            generateFromAudio = false
            subtitleState.resetAudioDownloadMetrics()
        }
        subtitleState.errorMessage = nil
        subtitleState.canGenerateFromAudio = false
        subtitleState.resetAudioDownloadMetrics()
        do {
            let segments = try await localService.generateSubtitlesFromAudio(
                video: video,
                configuration: configuration,
                context: modelContext,
                onDownloadProgress: { progress, bytesPerSecond in
                    subtitleState.audioDownloadProgress = progress
                    subtitleState.audioDownloadBytesPerSecond = bytesPerSecond
                }
            ) { partial in
                guard settings.configuration.translationTarget == configuration.translationTarget else { return }
                subtitleState.segments = partial
            }
            guard settings.configuration.translationTarget == configuration.translationTarget else { return }
            subtitleState.segments = segments
            loadedSubtitleKey = subtitleKey
        } catch {
            guard AsyncOperationErrorPresentationPolicy.shouldPresent(error) else { return }
            if settings.configuration.translationTarget == configuration.translationTarget {
                subtitleState.errorMessage = error.localizedDescription
                subtitleState.canGenerateFromAudio = true
            }
        }
    }

    private func retryCloudCheck() {
        bypassCloudCheck = false
        generateFromAudio = false
        retryGeneration += 1
    }

    private func generateAnyway() {
        bypassCloudCheck = true
        generateFromAudio = false
        retryGeneration += 1
    }

    private func startAudioASR() {
        generateFromAudio = true
        retryGeneration += 1
    }

    private func recoverFromStaleSourceGenerationState() {
        guard SourceGenerationStateRecoveryPolicy.shouldClear(
            step: video.sourceGenerationStep,
            subtitleStatus: video.subtitleStatus
        ) else {
            return
        }
        video.sourceGenerationStep = nil
        video.sourceGenerationProgress = nil
        subtitleState.resetAudioDownloadMetrics()
        try? modelContext.save()
    }
}

struct YTSubtitleDisplayView: View {
    var english: String?
    var translation: String?
    var errorMessage: String?
    var isPreparing: Bool
    var preparingMessage: String? = nil
    var preparingProgress: Double? = nil
    var preferences: SubtitlePresentationPreferences = .default
    /// Subtitle display mode from committed settings.
    var displayMode: String = AppConfiguration.defaultSubtitleDisplayMode
    var onRetryCloud: (() -> Void)?
    var onGenerateAnyway: (() -> Void)?
    var onGenerateFromAudio: (() -> Void)?
    /// Dynamic Type scale applied after base point-size calculation.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var showsTranslation: Bool {
        displayMode == "bilingual"
    }

    private var englishFontSize: CGFloat {
        CGFloat(preferences.englishPointSize()) * dynamicTypeScale
    }

    private var targetFontSize: CGFloat {
        CGFloat(preferences.targetPointSize()) * dynamicTypeScale
    }

    private var englishText: String? {
        english?.nilIfEmpty
    }

    private var targetText: String? {
        guard showsTranslation else { return nil }
        return translation?.nilIfEmpty
    }

    var body: some View {
        Group {
            if displayMode == "off" {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            } else {
                VStack(alignment: .center, spacing: 6) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.9))
                        if let onRetryCloud, let onGenerateAnyway {
                            HStack(spacing: 10) {
                                Button(L10n.string("episode_detail.retry", fallback: "Retry"), action: onRetryCloud)
                                Button(L10n.string("episodes.generate_bilingual_subtitles", fallback: "Generate bilingual subtitles"), action: onGenerateAnyway)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption.weight(.semibold))
                        }
                        if let onGenerateFromAudio {
                            Button(
                                L10n.string(
                                    "ytvideo_player.generate_from_audio",
                                    fallback: "Generate bilingual content from audio"
                                ),
                                action: onGenerateFromAudio
                            )
                            .buttonStyle(.borderedProminent)
                            .font(.caption.weight(.semibold))
                        }
                    } else if isPreparing {
                        if let preparingProgress {
                            ProgressView(value: min(max(preparingProgress, 0), 1))
                                .tint(.white)
                                .frame(maxWidth: 220)
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(
                            preparingMessage
                                ?? L10n.string("common.subtitles_in_preparation", fallback: "Subtitles in preparation")
                        )
                        .font(.caption.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                    } else {
                        subtitleLines
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: max(560, CGFloat(preferences.englishPointSize() * 22)), alignment: .center)
                .background(.black.opacity(hasVisibleContent ? 0.44 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if hasVisibleContent {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleLines: some View {
        switch preferences.order {
        case .englishFirst:
            if let englishText {
                englishLine(englishText)
            }
            if let targetText {
                targetLine(targetText)
            }
        case .targetFirst:
            if let targetText {
                targetLine(targetText)
            }
            if let englishText {
                englishLine(englishText)
            }
        }
    }

    private func englishLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: englishFontSize, weight: .semibold, design: .default))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            #if os(iOS)
            .textSelection(.enabled)
            #endif
    }

    private func targetLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: targetFontSize, weight: .medium, design: .default))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
    }

    private var hasVisibleContent: Bool {
        if errorMessage != nil || isPreparing { return true }
        return englishText != nil || targetText != nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum YTSourceGenerationProgressText {
    static func title(
        step: String?,
        progress: Double?,
        downloadProgress: Double? = nil,
        bytesPerSecond: Double? = nil
    ) -> String? {
        guard let step, !step.isEmpty else { return nil }
        let base: String
        switch step {
        case "resolving":
            base = L10n.string("ytvideo_player.asr_resolving_audio", fallback: "Resolving audio stream")
        case "downloading":
            base = L10n.string("pipeline.step.download", fallback: "Downloading Audio")
        case "uploading":
            base = L10n.string("pipeline.step.upload", fallback: "Uploading Audio")
        case "transcribing":
            base = L10n.string("pipeline.step.transcribe", fallback: "Transcribing Audio")
        case "segmenting":
            base = L10n.string("pipeline.step.segment_source", fallback: "Optimizing Subtitle Breaks")
        case "translating":
            base = L10n.string("pipeline.step.translate", fallback: "Translating Subtitles")
        default:
            base = L10n.string("pipeline.step.preparing", fallback: "Preparing")
        }
        let displayedProgress = step == "downloading" ? downloadProgress : progress
        var components = [base]
        if let displayedProgress, displayedProgress >= 0, displayedProgress < 1 {
            let percent = Int((displayedProgress * 100).rounded())
            components.append("\(percent)%")
        }
        if step == "downloading", let bytesPerSecond, bytesPerSecond > 0 {
            components.append(YTDownloadSpeedText.string(bytesPerSecond: bytesPerSecond))
        }
        return components.joined(separator: " · ")
    }
}

private enum YTDownloadSpeedText {
    static func string(bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }
}
