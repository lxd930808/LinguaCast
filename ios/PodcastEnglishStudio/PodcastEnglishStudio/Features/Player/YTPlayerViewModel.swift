import AVKit
import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

#if DEBUG
private enum YTPlaybackDiagnosticSanitizer {
    static func urlSummary(_ url: URL?) -> String {
        guard let url else { return "nil" }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host ?? "-"
        let path = url.path.isEmpty ? "/" : url.path
        let queryItems = components?.queryItems ?? []
        let keys = Array(Set(queryItems.map(\.name))).sorted().joined(separator: ",")
        let itag = queryItems.first(where: { $0.name.caseInsensitiveCompare("itag") == .orderedSame })?.value
        return "host=\(host) path=\(path) itag=\(itag ?? "-") queryKeys=[\(keys)]"
    }

    static func errorSummary(_ error: Error?) -> String {
        guard let error else { return "nil" }
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let value = current, depth < 4 {
            let status = value.userInfo["statusCode"].map { String(describing: $0) } ?? "-"
            parts.append("domain=\(value.domain) code=\(value.code) status=\(status)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " <- ")
    }

    static func timeRanges(_ item: AVPlayerItem?) -> String {
        guard let item else { return "[]" }
        return item.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            return String(
                format: "%.3f..%.3f",
                range.start.seconds,
                CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            )
        }.joined(separator: ",")
    }
}
#endif

private enum YTPlayerItemBuildError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        L10n.string(
            "ytplayer.stream_preparation_timed_out",
            fallback: "Timed out while preparing the selected YouTube stream."
        )
    }
}

@MainActor
private final class YTPlayerItemBuildRace {
    private var continuation: CheckedContinuation<YTPreparedPlayback, Error>?
    private var buildTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func makePreparedPlayback(
        from source: YTPlaybackSource,
        timeoutNanoseconds: UInt64,
        prefersComposedHLSSinglePlayer: Bool,
        composedHLSDurationHint: TimeInterval?
    ) async throws -> YTPreparedPlayback {
        try await withCheckedThrowingContinuation { continuation in
            let race = YTPlayerItemBuildRace(continuation: continuation)
            race.start(
                source: source,
                timeoutNanoseconds: timeoutNanoseconds,
                prefersComposedHLSSinglePlayer: prefersComposedHLSSinglePlayer,
                composedHLSDurationHint: composedHLSDurationHint
            )
        }
    }

    private init(continuation: CheckedContinuation<YTPreparedPlayback, Error>) {
        self.continuation = continuation
    }

    private func start(
        source: YTPlaybackSource,
        timeoutNanoseconds: UInt64,
        prefersComposedHLSSinglePlayer: Bool,
        composedHLSDurationHint: TimeInterval?
    ) {
        buildTask = Task { @MainActor [self] in
            do {
                let playback = try await YTPlaybackItemBuilder.makePreparedPlayback(
                    from: source,
                    prefersComposedHLSSinglePlayer: prefersComposedHLSSinglePlayer,
                    composedHLSDurationHint: composedHLSDurationHint
                )
                finish(.success(playback))
            } catch {
                finish(.failure(error))
            }
        }
        timeoutTask = Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            finish(.failure(YTPlayerItemBuildError.timedOut))
        }
    }

    private func finish(_ result: Result<YTPreparedPlayback, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        buildTask?.cancel()
        timeoutTask?.cancel()
        buildTask = nil
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

// Cross-platform player state and behavior. Platform-specific hooks are injected
// through YTPlayerPlatformSupport in YTPlayerView+iOS.swift and YTPlayerView+tvOS.swift.
@MainActor
@Observable
final class YTPlayerViewModel {
    private enum StallFallbackStage {
        case primary
        case hls
        case progressive
        case exhausted
    }

    var playerItem: AVPlayerItem?
    var auxiliaryAudioItem: AVPlayerItem?
    /// Keeps the synthesized-HLS resource loader alive while a composed-HLS item
    /// is installed (AVAssetResourceLoader holds its delegate weakly).
    private var composedHLSAsset: YTComposedHLSAsset?
    var playbackSelection: YTPlaybackSelection?
    var playbackRecoveryTime: TimeInterval?
    var playbackRecoveryShouldResume: Bool?
    var nativeStreamError: String?
    var actualPlaybackHeight: Int?
    var actualPlaybackCodec: String?
    /// Set when a manual quality pick could not be honored and playback fell back.
    var qualityDegradedNotice: String?
    var availableQualityTiers: [YTStreamSelectionPolicy] = YTStreamSelectionPolicy.qualityTierOptions
    var playbackItemToken = UUID()

    private let resolver: any YTMediaStreamResolving
    private let cloudResolver: (any CloudVideoMediaResolving)?
    /// Committed app configuration for cloud media lookup. Set by the player view
    /// before `load`; signed URLs are never stored here.
    var cloudConfiguration: AppConfiguration?
    private var resolvedStreams: YTResolvedMediaStreams?
    private var loadedVideoID: String?
    private var didRetryForbiddenOrExpired = false
    private var didRefreshCloudURL = false
    private var autoDowngradePolicy: YTStreamSelectionPolicy?
    private var stallFallbackStage: StallFallbackStage = .primary
    private var lastNetworkKind: YTPlaybackNetworkKind?
    private var playbackOperationGeneration = UUID()
    /// Video-length hint for the composed-HLS `#EXTINF` (metadata duration from
    /// the caller; the stream URL's `dur` parameter is the in-Core fallback).
    private var composedHLSDurationHint: TimeInterval?

    init(
        resolver: (any YTMediaStreamResolving)? = nil,
        cloudResolver: (any CloudVideoMediaResolving)? = CloudVideoMediaResolver()
    ) {
        self.resolver = resolver ?? YTPlaybackBackend.makeResolver()
        self.cloudResolver = cloudResolver
    }

    private var isPlayingCloudMedia: Bool {
        playbackSelection?.selectionMode == CloudVideoPlaybackRouting.selectionMode
    }

    func load(
        videoID: String,
        initialTime: TimeInterval?,
        currentTime: Binding<TimeInterval>,
        duration: Binding<TimeInterval>,
        quality: YTStreamSelectionPolicy? = nil,
        wasPlaying: Bool,
        durationHint: TimeInterval? = nil
    ) async {
        let operationGeneration = UUID()
        playbackOperationGeneration = operationGeneration
        let loadStartedAt = Date()
        let shouldResumeAfterLoad = loadedVideoID == videoID ? wasPlaying : true
        if loadedVideoID != videoID {
            if let previousVideoID = loadedVideoID {
                await resolver.invalidate(videoID: previousVideoID)
            }
            playerItem = nil
            auxiliaryAudioItem = nil
            composedHLSAsset = nil
            playbackSelection = nil
            resolvedStreams = nil
            didRetryForbiddenOrExpired = false
            didRefreshCloudURL = false
            autoDowngradePolicy = nil
            stallFallbackStage = .primary
            actualPlaybackHeight = nil
            actualPlaybackCodec = nil
            qualityDegradedNotice = nil
        }
        composedHLSDurationHint = durationHint
        nativeStreamError = nil
        qualityDegradedNotice = nil
        currentTime.wrappedValue = initialTime ?? currentTime.wrappedValue
        duration.wrappedValue = 0
        loadedVideoID = videoID
        lastNetworkKind = YTPlaybackNetworkMonitor.shared.kind

        do {
            let installedCloud = await installCloudIfAvailable(
                videoID: videoID,
                quality: quality,
                restoreTime: initialTime ?? currentTime.wrappedValue,
                wasPlaying: shouldResumeAfterLoad,
                operationGeneration: operationGeneration,
                forceRefresh: false
            )
            if installedCloud { return }

            print("YTPlayerView: resolving native stream for \(videoID)")
            let streams = try await resolveStreams(videoID: videoID, quality: quality)
            guard playbackOperationGeneration == operationGeneration else { return }
            let resolveMs = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
            print("YTPlayerView: resolve done videoID=\(videoID) ms=\(resolveMs)")
            resolvedStreams = streams
            availableQualityTiers = YTPlaybackSourceSelector.availableQualityTiers(from: streams)
            try await applySelection(
                videoID: videoID,
                streams: streams,
                quality: quality,
                restoreTime: initialTime ?? currentTime.wrappedValue,
                wasPlaying: shouldResumeAfterLoad,
                expectedOperationGeneration: operationGeneration
            )
            guard playbackOperationGeneration == operationGeneration else { return }
            let installMs = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
            print(
                "YTPlayerView: item installed videoID=\(videoID) mode=\(playbackSelection?.selectionMode ?? "-") segmented=\(composedHLSAsset?.usedSegmentedPlaylists == true) ms=\(installMs)"
            )
        } catch {
            guard playbackOperationGeneration == operationGeneration else { return }
            print("YouTube native stream resolver failed: \(error.localizedDescription)")
            nativeStreamError = error.localizedDescription
            playerItem = nil
            auxiliaryAudioItem = nil
            composedHLSAsset = nil
            playbackSelection = nil
        }
    }

    func handleNetworkChangeIfNeeded(
        quality: YTStreamSelectionPolicy?,
        wasPlaying: Bool
    ) async {
        let network = YTPlaybackNetworkMonitor.shared.kind
        defer { lastNetworkKind = network }
        guard let lastNetworkKind, lastNetworkKind != network else { return }
        guard CloudVideoPlaybackRouting.shouldReapplyOnNetworkChange(
            selectionMode: playbackSelection?.selectionMode
        ) else { return }
        // Auto tier re-applies the cellular 1080p cap when leaving Wi‑Fi.
        let isAuto = quality == nil || quality == .highestQuality
        guard isAuto, network == .cellular, lastNetworkKind != .cellular else { return }
        guard let videoID = loadedVideoID, let streams = resolvedStreams else { return }
        let operationGeneration = UUID()
        playbackOperationGeneration = operationGeneration
        autoDowngradePolicy = nil
        stallFallbackStage = .primary
        try? await applySelection(
            videoID: videoID,
            streams: streams,
            quality: quality,
            restoreTime: nil,
            wasPlaying: wasPlaying,
            expectedOperationGeneration: operationGeneration
        )
    }

    func handlePlaybackFailure(
        statusCode: Int?,
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        quality: YTStreamSelectionPolicy?,
        expectedPlaybackItemToken: UUID? = nil
    ) async {
        guard expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken else { return }
        let operationGeneration = playbackOperationGeneration
        guard let videoID = loadedVideoID else { return }
        if let statusCode, statusCode == 429 {
            nativeStreamError = YTMediaStreamResolverError.rateLimited.localizedDescription
            playerItem = nil
            auxiliaryAudioItem = nil
            composedHLSAsset = nil
            playbackSelection = nil
            return
        }
        if isPlayingCloudMedia {
            let decision = CloudVideoPlaybackRouting.decideOnPlayerFailure(
                statusCode: statusCode,
                currentSelectionMode: playbackSelection?.selectionMode,
                didRefreshCloudURL: didRefreshCloudURL
            )
            if decision == .refreshCloudOnce {
                didRefreshCloudURL = true
                let installed = await installCloudIfAvailable(
                    videoID: videoID,
                    quality: quality,
                    restoreTime: restoreTime,
                    wasPlaying: wasPlaying,
                    operationGeneration: operationGeneration,
                    forceRefresh: true
                )
                if installed { return }
            }
            await installYouTubeFallback(
                quality: quality,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
            return
        }
        let shouldReparse = (statusCode == 403 || statusCode == 410) && !didRetryForbiddenOrExpired
        if shouldReparse {
            didRetryForbiddenOrExpired = true
            await resolver.invalidate(videoID: videoID)
            do {
                let streams = try await resolveStreams(videoID: videoID, quality: quality)
                guard playbackOperationGeneration == operationGeneration,
                      expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
                else { return }
                resolvedStreams = streams
                stallFallbackStage = .primary
                availableQualityTiers = YTPlaybackSourceSelector.availableQualityTiers(from: streams)
                try await applySelection(
                    videoID: videoID,
                    streams: streams,
                    quality: quality,
                    restoreTime: restoreTime,
                    wasPlaying: wasPlaying,
                    expectedOperationGeneration: operationGeneration,
                    expectedPlaybackItemToken: expectedPlaybackItemToken
                )
            } catch {
                guard playbackOperationGeneration == operationGeneration,
                      expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
                else { return }
                nativeStreamError = error.localizedDescription
                playerItem = nil
                auxiliaryAudioItem = nil
                composedHLSAsset = nil
            }
            return
        }
        if stallFallbackStage == .progressive || stallFallbackStage == .exhausted {
            exhaustPlaybackFallbacks()
            return
        }

        // Composed-HLS item failed → rebuild the same separated streams as the
        // proven dual-AVPlayer composed playback before degrading quality.
        if activeComposedHLSSource != nil {
            await installDualComposedFallback(
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
            return
        }

        // Fall back to the best progressive muxed stream when composition/source fails.
        await installProgressiveFallback(
            restoreTime: restoreTime,
            wasPlaying: wasPlaying,
            expectedPlaybackItemToken: expectedPlaybackItemToken,
            expectedOperationGeneration: operationGeneration
        )
    }

    func resetAutoDowngrade() {
        autoDowngradePolicy = nil
        stallFallbackStage = .primary
    }

    func handleAutoQualityStall(
        currentHeight: Int?,
        quality: YTStreamSelectionPolicy?,
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        expectedPlaybackItemToken: UUID
    ) async {
        guard expectedPlaybackItemToken == playbackItemToken else { return }
        let operationGeneration = playbackOperationGeneration
        if isPlayingCloudMedia {
            await installYouTubeFallback(
                quality: quality,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
            return
        }
        guard let videoID = loadedVideoID, let streams = resolvedStreams else { return }
        if let currentSelection = playbackSelection,
           case .hls = currentSelection.source {
            stallFallbackStage = .hls
        }

        // First sustained stall on the synthesized composed-HLS item → rebuild the
        // same separated streams as dual-AVPlayer composed playback; the next stall
        // continues down the adaptive-HLS rung below (stage stays .primary).
        if stallFallbackStage == .primary, activeComposedHLSSource != nil {
            await installDualComposedFallback(
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
            return
        }

        // A composed DASH item depends on two independent remote resources. Prefer the
        // adaptive HLS manifest on the first sustained stall so AVPlayer can change
        // bitrate without rebuilding the player item.
        if stallFallbackStage == .primary,
           let hlsURL = streams.hlsURL,
           playbackSelection?.selectionMode != "hls-stall-fallback" {
            stallFallbackStage = .hls
            let maximumHeight = lastNetworkKind == .cellular ? 1080 : nil
            let selection = YTPlaybackSelection(
                source: .hls(hlsURL, maximumHeight: maximumHeight),
                actualHeight: nil,
                actualCodec: "hls",
                selectionMode: "hls-stall-fallback"
            )
            print("YTPlayerView: sustained stall, switching to adaptive HLS")
            let item = AVPlayerItem(url: hlsURL)
            if let maximumHeight {
                item.preferredMaximumResolution = CGSize(
                    width: CGFloat(maximumHeight) * 16 / 9,
                    height: CGFloat(maximumHeight)
                )
            }
            install(
                selection: selection,
                item: item,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying
            )
            return
        }

        // If HLS also stalls, use a single-resource progressive stream instead of
        // bouncing back to the same composed source.
        if stallFallbackStage == .hls {
            print("YTPlayerView: HLS stalled, switching to progressive fallback")
            await installProgressiveFallback(
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
            return
        }

        if stallFallbackStage == .progressive || stallFallbackStage == .exhausted {
            exhaustPlaybackFallbacks()
            return
        }

        let isAuto = quality == nil || quality == .highestQuality
        guard isAuto else {
            await installProgressiveFallback(
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
            return
        }
        guard let lower = YTPlaybackSourceSelector.lowerQualityTier(from: currentHeight) else { return }
        if let current = autoDowngradePolicy, current == lower {
            await installProgressiveFallback(
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
            return
        }
        autoDowngradePolicy = lower
        print("YTPlayerView: auto downgrade to \(lower.storedRawValue)")
        do {
            try await applySelection(
                videoID: videoID,
                streams: streams,
                quality: lower,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedOperationGeneration: operationGeneration,
                expectedPlaybackItemToken: expectedPlaybackItemToken
            )
        } catch {
            guard playbackOperationGeneration == operationGeneration,
                  expectedPlaybackItemToken == playbackItemToken
            else { return }
            await installProgressiveFallback(
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: operationGeneration
            )
        }
    }

    private func applySelection(
        videoID: String,
        streams: YTResolvedMediaStreams,
        quality: YTStreamSelectionPolicy?,
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        expectedOperationGeneration: UUID? = nil,
        expectedPlaybackItemToken: UUID? = nil
    ) async throws {
        let effectiveQuality = autoDowngradePolicy ?? quality
        var workingStreams = streams
        // Kept apart because they carry different weight: a preflight refusal is only a
        // hint (the probe can disagree with what AVPlayer is able to fetch), while a
        // failed player-item build is a fact worth honouring for the rest of this attempt.
        var preflightRefusedURLs = Set<URL>()
        var prepareFailedURLs = Set<URL>()
        var lastSelection: YTPlaybackSelection?
        var lastError: Error?

        // Bounded attempts: a definitively refused candidate (401/403/410) is excluded
        // and selection runs again. Preflight is fail-open, so timeouts never cost an
        // attempt and the whole loop stays well inside the prepare watchdog.
        for _ in 0..<3 {
            let context = selectionContext(quality: effectiveQuality)
            guard let selection = YTPlaybackSourceSelector.select(from: workingStreams, context: context) else {
                break
            }
            lastSelection = selection
            logSelection(videoID: videoID, selection: selection, context: context)

            let playable = await YTMediaStreamURLPreflight.isSourcePlayable(selection.source)
            guard expectedOperationGeneration == nil
                    || expectedOperationGeneration == playbackOperationGeneration,
                  expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
            else { return }
            if !playable {
                let failed = YTMediaStreamURLPreflight.urls(in: selection.source)
                print(
                    "YTPlayerView: preflight rejected mode=\(selection.selectionMode) height=\(selection.actualHeight ?? -1)"
                )
                preflightRefusedURLs.formUnion(failed)
                workingStreams = YTResolvedMediaStreamsFiltering.excluding(
                    streams,
                    urls: preflightRefusedURLs.union(prepareFailedURLs)
                )
                availableQualityTiers = YTPlaybackSourceSelector.availableQualityTiers(from: workingStreams)
                lastError = YTMediaStreamResolverError.remoteForbidden
                continue
            }

            let installedSelection: YTPlaybackSelection
            if selection.selectionMode == "composed" || selection.selectionMode == "direct" {
                installedSelection = YTPlaybackSelection(
                    source: selection.source,
                    actualHeight: selection.actualHeight,
                    actualCodec: selection.actualCodec,
                    selectionMode: selection.selectionMode == "composed"
                        ? "composed-preflight"
                        : "direct-preflight"
                )
            } else if selection.selectionMode.hasPrefix("hls") {
                installedSelection = YTPlaybackSelection(
                    source: selection.source,
                    actualHeight: selection.actualHeight,
                    actualCodec: selection.actualCodec,
                    selectionMode: selection.selectionMode == "hls"
                        ? "hls-preflight"
                        : selection.selectionMode
                )
            } else {
                installedSelection = selection
            }

            do {
                let playback = try await makePreparedPlayback(from: installedSelection.source)
                guard expectedOperationGeneration == nil
                        || expectedOperationGeneration == playbackOperationGeneration,
                      expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
                else { return }
                noteQualityDegradationIfNeeded(
                    requested: effectiveQuality,
                    installed: installedSelection
                )
                install(
                    selection: installedSelection,
                    playback: playback,
                    restoreTime: restoreTime,
                    wasPlaying: wasPlaying
                )
                return
            } catch {
                lastError = error
                // Player-item preparation failure → exclude these URLs and retry.
                prepareFailedURLs.formUnion(YTMediaStreamURLPreflight.urls(in: selection.source))
                workingStreams = YTResolvedMediaStreamsFiltering.excluding(
                    streams,
                    urls: preflightRefusedURLs.union(prepareFailedURLs)
                )
                availableQualityTiers = YTPlaybackSourceSelector.availableQualityTiers(from: workingStreams)
            }
        }

        // Last resort: progressive / legacy without another preflight loop.
        let fallbackContext = selectionContext(quality: .legacyCompatible)
        let progressiveOnly = YTResolvedMediaStreams(
            progressive: workingStreams.progressive,
            videoOnly: [],
            audioOnly: [],
            hlsURL: nil,
            expiresAt: workingStreams.expiresAt
        )
        if let fallback = YTPlaybackSourceSelector.select(from: progressiveOnly, context: fallbackContext)
            ?? YTPlaybackSourceSelector.select(from: progressiveOnly, context: selectionContext(quality: effectiveQuality)) {
            do {
                let playback = try await makePreparedPlayback(from: fallback.source)
                guard expectedOperationGeneration == nil
                        || expectedOperationGeneration == playbackOperationGeneration,
                      expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
                else { return }
                install(
                    selection: fallback,
                    playback: playback,
                    restoreTime: restoreTime,
                    wasPlaying: wasPlaying
                )
                return
            } catch {
                lastError = error
            }
        }

        // Preflight only ever gets a vote when a verified alternative exists. If every
        // candidate was refused, ignore those verdicts and hand the best one to AVPlayer
        // anyway: the probe cannot see the media stack's own credentials, and the
        // stall-recovery ladder is a better answer than refusing to play at all.
        if !preflightRefusedURLs.isEmpty {
            let unverified = YTResolvedMediaStreamsFiltering.excluding(streams, urls: prepareFailedURLs)
            if let candidate = YTPlaybackSourceSelector.select(
                from: unverified,
                context: selectionContext(quality: effectiveQuality)
            ) {
                print(
                    "YTPlayerView: no preflight-verified candidate, trying best-effort mode=\(candidate.selectionMode) height=\(candidate.actualHeight ?? -1)"
                )
                do {
                    let playback = try await makePreparedPlayback(from: candidate.source)
                    guard expectedOperationGeneration == nil
                            || expectedOperationGeneration == playbackOperationGeneration,
                          expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
                    else { return }
                    availableQualityTiers = YTPlaybackSourceSelector.availableQualityTiers(from: unverified)
                    noteQualityDegradationIfNeeded(requested: effectiveQuality, installed: candidate)
                    install(
                        selection: candidate,
                        playback: playback,
                        restoreTime: restoreTime,
                        wasPlaying: wasPlaying
                    )
                    return
                } catch {
                    lastError = error
                }
            }
        }

        if let lastSelection, case .composed = lastSelection.source,
           let fallback = YTPlaybackSourceSelector.select(from: streams, context: fallbackContext) {
            let playback = try await makePreparedPlayback(from: fallback.source)
            guard expectedOperationGeneration == nil
                    || expectedOperationGeneration == playbackOperationGeneration,
                  expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
            else { return }
            install(
                selection: fallback,
                playback: playback,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying
            )
            return
        }

        throw lastError ?? YTMediaStreamResolverError.noPlayableStream
    }

    /// The composed source currently playing as a synthesized single-item HLS, if
    /// any. Distinguishing trait: a composed selection installed with no auxiliary
    /// audio item. The first rung of the fallback ladder rebuilds this source as
    /// the proven dual-AVPlayer composed playback before HLS/progressive.
    private var activeComposedHLSSource: YTPlaybackSource? {
        guard let selection = playbackSelection,
              case .composed = selection.source,
              playerItem != nil,
              auxiliaryAudioItem == nil
        else { return nil }
        return selection.source
    }

    private func installDualComposedFallback(
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        expectedPlaybackItemToken: UUID?,
        expectedOperationGeneration: UUID
    ) async {
        guard let source = activeComposedHLSSource,
              let selection = playbackSelection
        else { return }
        print("YTPlayerView: composed HLS playback failed, falling back to dual-player composed")
        do {
            let playback = try await makePreparedPlayback(
                from: source,
                prefersComposedHLSSinglePlayer: false
            )
            guard expectedOperationGeneration == playbackOperationGeneration,
                  expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
            else { return }
            install(
                selection: selection,
                playback: playback,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying
            )
        } catch {
            guard expectedOperationGeneration == playbackOperationGeneration,
                  expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
            else { return }
            await installProgressiveFallback(
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedPlaybackItemToken: expectedPlaybackItemToken,
                expectedOperationGeneration: expectedOperationGeneration
            )
        }
    }

    private func installProgressiveFallback(
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        expectedPlaybackItemToken: UUID? = nil,
        expectedOperationGeneration: UUID? = nil
    ) async {
        guard expectedOperationGeneration == nil
                || expectedOperationGeneration == playbackOperationGeneration,
              expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
        else { return }
        guard stallFallbackStage != .progressive, stallFallbackStage != .exhausted else {
            exhaustPlaybackFallbacks()
            return
        }
        guard let streams = resolvedStreams else {
            exhaustPlaybackFallbacks()
            return
        }
        let context = selectionContext(quality: .legacyCompatible)
        let progressiveOnly = YTResolvedMediaStreams(
            progressive: streams.progressive,
            videoOnly: [],
            audioOnly: [],
            hlsURL: nil,
            expiresAt: streams.expiresAt
        )
        guard let selection = YTPlaybackSourceSelector.select(from: progressiveOnly, context: context) else {
            exhaustPlaybackFallbacks()
            return
        }
        do {
            let playback = try await makePreparedPlayback(from: selection.source)
            guard expectedOperationGeneration == nil
                    || expectedOperationGeneration == playbackOperationGeneration,
                  expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
            else { return }
            stallFallbackStage = .progressive
            install(
                selection: selection,
                playback: playback,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying
            )
        } catch {
            guard expectedOperationGeneration == nil
                    || expectedOperationGeneration == playbackOperationGeneration,
                  expectedPlaybackItemToken == nil || expectedPlaybackItemToken == playbackItemToken
            else { return }
            exhaustPlaybackFallbacks(error: error)
        }
    }

    private func exhaustPlaybackFallbacks(error: Error? = nil) {
        stallFallbackStage = .exhausted
        nativeStreamError = error?.localizedDescription
            ?? YTMediaStreamResolverError.noPlayableStream.localizedDescription
        playerItem = nil
        auxiliaryAudioItem = nil
        composedHLSAsset = nil
        playbackSelection = nil
    }

    private func makePreparedPlayback(
        from source: YTPlaybackSource,
        prefersComposedHLSSinglePlayer: Bool = YTPlayerPlatformSupport.prefersComposedHLSSinglePlayer
    ) async throws -> YTPreparedPlayback {
        do {
            return try await YTPlayerItemBuildRace.makePreparedPlayback(
                from: source,
                timeoutNanoseconds: 10_000_000_000,
                prefersComposedHLSSinglePlayer: prefersComposedHLSSinglePlayer,
                composedHLSDurationHint: composedHLSDurationHint
            )
        } catch {
            print("YTPlayerView: player item preparation failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func install(
        selection: YTPlaybackSelection,
        playback: YTPreparedPlayback,
        restoreTime: TimeInterval? = nil,
        wasPlaying: Bool? = nil
    ) {
        install(
            selection: selection,
            item: playback.primaryItem,
            auxiliaryAudioItem: playback.auxiliaryAudioItem,
            restoreTime: restoreTime,
            wasPlaying: wasPlaying
        )
        // Retain after the item install (which clears any previous loader).
        composedHLSAsset = playback.composedHLSAsset
    }

    private func install(
        selection: YTPlaybackSelection,
        item: AVPlayerItem,
        auxiliaryAudioItem: AVPlayerItem? = nil,
        restoreTime: TimeInterval? = nil,
        wasPlaying: Bool? = nil
    ) {
        // Direct item installs (HLS stall fallback) never use the synthesized loader.
        composedHLSAsset = nil
        playbackSelection = selection
        actualPlaybackHeight = selection.actualHeight
        actualPlaybackCodec = selection.actualCodec
        playbackRecoveryTime = restoreTime
        playbackRecoveryShouldResume = wasPlaying
        playerItem = item
        self.auxiliaryAudioItem = auxiliaryAudioItem
        playbackItemToken = UUID()
        nativeStreamError = nil
        print(
            "YTPlayerView: selected mode=\(selection.selectionMode) height=\(selection.actualHeight ?? -1) codec=\(selection.actualCodec ?? "-")"
        )
    }

    private func selectionContext(quality: YTStreamSelectionPolicy?) -> YTPlaybackSelectionContext {
        YTPlaybackSelectionContext(
            policy: quality ?? YTPlayerPlatformSupport.streamSelectionPolicy,
            network: YTPlaybackNetworkMonitor.shared.kind,
            supportsAV1HardwareDecode: YTHardwareDecodeSupport.isAV1Supported,
            applyCellularAutoCap: true,
            prefersFixedQualityOverAdaptiveHLS: YTPlayerPlatformSupport.prefersFixedQualityOverAdaptiveHLS
        )
    }

    private func noteQualityDegradationIfNeeded(
        requested: YTStreamSelectionPolicy?,
        installed: YTPlaybackSelection
    ) {
        guard case .preferred(let requestedHeight) = requested else {
            qualityDegradedNotice = nil
            return
        }
        let usedHLS = installed.actualCodec == "hls" || installed.selectionMode.contains("hls")
        let actualHeight = installed.actualHeight ?? 0
        if usedHLS || actualHeight < requestedHeight {
            qualityDegradedNotice = L10n.string(
                "ytplayer.quality_unavailable_using_best",
                fallback: "Requested quality unavailable; using best playable stream."
            )
        } else {
            qualityDegradedNotice = nil
        }
    }

    private func installCloudIfAvailable(
        videoID: String,
        quality: YTStreamSelectionPolicy?,
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        operationGeneration: UUID,
        forceRefresh: Bool
    ) async -> Bool {
        guard let cloudResolver, let cloudConfiguration else { return false }
        guard CloudVideoPlaybackRouting.shouldAttemptCloud(usesOfficialIFrame: false) else {
            return false
        }
        var outcome = await cloudResolver.lookup(
            videoID: videoID,
            preferredHeight: CloudVideoPlaybackRouting.preferredHeight(from: quality),
            configuration: cloudConfiguration,
            forceRefresh: forceRefresh
        )
        while case .notReady(let retryAfter) = outcome {
            qualityDegradedNotice = L10n.string("video_save.preparing", fallback: "Saving video to cloud…")
            do { try await Task.sleep(for: .seconds(max(2, min(retryAfter ?? 8, 30)))) }
            catch { return true }
            guard playbackOperationGeneration == operationGeneration else { return true }
            outcome = await cloudResolver.lookup(videoID: videoID,
                preferredHeight: CloudVideoPlaybackRouting.preferredHeight(from: quality),
                configuration: cloudConfiguration, forceRefresh: true)
        }
        if case .transport = outcome {
            qualityDegradedNotice = L10n.string("video_save.query_failed", fallback: "Could not check cloud video. Please retry.")
            return true
        }
        guard playbackOperationGeneration == operationGeneration else { return true }
        let decision = CloudVideoPlaybackRouting.decideOnLookup(
            outcome: outcome,
            quality: quality,
            expectedDuration: composedHLSDurationHint,
            supportsAV1: YTHardwareDecodeSupport.isAV1Supported
        )
        switch decision {
        case .useCloud(let candidate):
            do {
                try await installCloudCandidate(
                    candidate,
                    restoreTime: restoreTime,
                    wasPlaying: wasPlaying,
                    expectedOperationGeneration: operationGeneration
                )
                return true
            } catch {
                print("YTPlayerView: cloud media install failed: \(error.localizedDescription)")
                return false
            }
        case .manualQualityMiss, .fallback, .refreshCloudOnce:
            return false
        }
    }

    private func installCloudCandidate(
        _ candidate: CloudVideoPlaybackCandidate,
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        expectedOperationGeneration: UUID
    ) async throws {
        let selection = CloudVideoPlaybackRouting.playbackSelection(from: candidate)
        let playback = try await makePreparedPlayback(from: selection.source)
        guard expectedOperationGeneration == playbackOperationGeneration else { return }
        availableQualityTiers = CloudVideoPlaybackRouting.availableQualityTiers(height: candidate.height)
        resolvedStreams = nil
        install(
            selection: selection,
            playback: playback,
            restoreTime: restoreTime,
            wasPlaying: wasPlaying
        )
        print("YTPlayerView: installed cloud-media media=\(candidate.mediaId) height=\(candidate.height)")
    }

    private func installYouTubeFallback(
        quality: YTStreamSelectionPolicy?,
        restoreTime: TimeInterval?,
        wasPlaying: Bool,
        expectedPlaybackItemToken: UUID?,
        expectedOperationGeneration: UUID
    ) async {
        guard let videoID = loadedVideoID else { return }
        do {
            let streams = try await resolveStreams(videoID: videoID, quality: quality)
            guard expectedOperationGeneration == playbackOperationGeneration else { return }
            resolvedStreams = streams
            availableQualityTiers = YTPlaybackSourceSelector.availableQualityTiers(from: streams)
            try await applySelection(
                videoID: videoID,
                streams: streams,
                quality: quality,
                restoreTime: restoreTime,
                wasPlaying: wasPlaying,
                expectedOperationGeneration: expectedOperationGeneration,
                expectedPlaybackItemToken: expectedPlaybackItemToken
            )
        } catch {
            guard expectedOperationGeneration == playbackOperationGeneration else { return }
            nativeStreamError = error.localizedDescription
            playerItem = nil
            auxiliaryAudioItem = nil
            composedHLSAsset = nil
            playbackSelection = nil
        }
    }

    private func resolveStreams(
        videoID: String,
        quality: YTStreamSelectionPolicy?
    ) async throws -> YTResolvedMediaStreams {
        let streams = try await resolver.resolve(videoID: videoID)
        let isAutoQuality = quality == nil || quality == .highestQuality
        let isHLSOnly = streams.hlsURL != nil
            && streams.progressive.isEmpty
            && streams.videoOnly.isEmpty
            && streams.audioOnly.isEmpty
        guard !isAutoQuality, isHLSOnly else {
            return streams
        }
        return try await resolver.resolve(videoID: videoID)
    }

    private func logSelection(videoID: String, selection: YTPlaybackSelection, context: YTPlaybackSelectionContext) {
        let itag: Int
        let codec: String
        switch selection.source {
        case .direct(let stream):
            itag = stream.itag
            codec = stream.videoCodecRaw ?? stream.videoCodec?.rawValue ?? "-"
        case .composed(let video, _):
            itag = video.itag
            codec = video.videoCodecRaw ?? video.videoCodec?.rawValue ?? "-"
        case .hls:
            itag = 0
            codec = "hls"
        }
        print(
            "YTPlayerView: videoID=\(videoID) itag=\(itag) codec=\(codec) height=\(selection.actualHeight ?? -1) mode=\(selection.selectionMode) network=\(context.network)"
        )
    }
}

struct YTNativePlayerView: UIViewControllerRepresentable {
    var playerItem: AVPlayerItem
    var auxiliaryAudioItem: AVPlayerItem?
    var playbackItemToken: UUID
    var playbackRecoveryTime: TimeInterval?
    var playbackRecoveryShouldResume: Bool?
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval
    var initialTime: TimeInterval?
    var subtitleState: YTSubtitleDisplayState
    var subtitlePreferences: SubtitlePresentationPreferences
    var playbackRate: Double
    var subtitleDisplayMode: String
    var playbackCommand: YTPlaybackCommand?
    var repeatRange: ClosedRange<TimeInterval>?
    var shouldResumeAfterInitialSeek: Bool
    var isAutoQuality: Bool
    var onPlaybackStateChange: (Bool) -> Void
    var onEffectiveRateChange: (Double) -> Void
    var onPlaybackEnded: () -> Void
    var onPlaybackFailed: (Int?, TimeInterval, Bool) -> Void
    var onAutoQualityStall: (Int?, TimeInterval, Bool) -> Void
    var onPresentationSizeChange: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            currentTime: $currentTime,
            duration: $duration,
            initialTime: initialTime,
            subtitleState: subtitleState,
            subtitlePreferences: subtitlePreferences,
            playbackRate: playbackRate,
            subtitleDisplayMode: subtitleDisplayMode,
            playbackCommand: playbackCommand,
            repeatRange: repeatRange,
            shouldResumeAfterInitialSeek: shouldResumeAfterInitialSeek,
            isAutoQuality: isAutoQuality,
            onPlaybackStateChange: onPlaybackStateChange,
            onEffectiveRateChange: onEffectiveRateChange,
            onPlaybackEnded: onPlaybackEnded,
            onPlaybackFailed: onPlaybackFailed,
            onAutoQualityStall: onAutoQualityStall,
            onPresentationSizeChange: onPresentationSizeChange
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        YTPlayerPlatformSupport.configurePlayerController(controller)
        controller.delegate = context.coordinator
        let player = AVPlayer(playerItem: playerItem)
        let audioPlayer = auxiliaryAudioItem.map(AVPlayer.init(playerItem:))
        controller.player = player
        print("YTNativePlayerView: player created dual=\(audioPlayer != nil)")
        context.coordinator.player = player
        context.coordinator.audioPlayer = audioPlayer
        context.coordinator.playbackItemToken = playbackItemToken
        context.coordinator.initialTime = initialTime
        context.coordinator.subtitlePreferences = subtitlePreferences
        context.coordinator.playbackRate = playbackRate
        context.coordinator.subtitleDisplayMode = subtitleDisplayMode
        context.coordinator.shouldResumeAfterInitialSeek = shouldResumeAfterInitialSeek
        context.coordinator.isAutoQuality = isAutoQuality
        context.coordinator.resetInitialSeek()
        let restorePosition =
            playbackRecoveryTime
            ?? PlaybackProgressPolicy.restorePosition(from: initialTime)
            ?? 0
        let wantsPlayback = playbackRecoveryShouldResume ?? shouldResumeAfterInitialSeek
        context.coordinator.beginMediaItemRecovery(
            position: restorePosition,
            wantsPlayback: wantsPlayback,
            rate: playbackRate
        )
        context.coordinator.observePlayerItems(
            primary: playerItem,
            auxiliaryAudio: auxiliaryAudioItem
        )
        context.coordinator.installSubtitleOverlay(in: controller)
        context.coordinator.startObserving()
        context.coordinator.updateRepeatRange(repeatRange)
        context.coordinator.consume(playbackCommand)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.initialTime = initialTime
        context.coordinator.subtitlePreferences = subtitlePreferences
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        context.coordinator.onPlaybackFailed = onPlaybackFailed
        context.coordinator.onAutoQualityStall = onAutoQualityStall
        context.coordinator.onPresentationSizeChange = onPresentationSizeChange
        context.coordinator.playbackRate = playbackRate
        context.coordinator.subtitleDisplayMode = subtitleDisplayMode
        context.coordinator.shouldResumeAfterInitialSeek = shouldResumeAfterInitialSeek
        context.coordinator.isAutoQuality = isAutoQuality
        context.coordinator.onPlaybackStateChange = onPlaybackStateChange
        context.coordinator.onEffectiveRateChange = onEffectiveRateChange
        context.coordinator.applyPlaybackRateIfNeeded()
        context.coordinator.updateRepeatRange(repeatRange)
        context.coordinator.consume(playbackCommand)
        context.coordinator.updateSubtitleOverlay()
        guard context.coordinator.playbackItemToken != playbackItemToken else { return }

        let preserveTime = playbackRecoveryTime
            ?? context.coordinator.trustedPlaybackPosition
        let wasPlaying = playbackRecoveryShouldResume
            ?? (
                (context.coordinator.player?.rate ?? 0) > 0
                    || context.coordinator.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    || context.coordinator.pendingStallRecoveryShouldResume
            )
        let rate = context.coordinator.playbackRate

        // Pause before replace so AVPlayer does not start the new item at 0.
        context.coordinator.player?.pause()
        context.coordinator.audioPlayer?.pause()
        context.coordinator.beginMediaItemRecovery(
            position: preserveTime,
            wantsPlayback: wasPlaying,
            rate: rate
        )

        if let player = controller.player {
            player.replaceCurrentItem(with: playerItem)
            context.coordinator.player = player
        } else {
            let player = AVPlayer(playerItem: playerItem)
            controller.player = player
            context.coordinator.player = player
        }
        if let auxiliaryAudioItem {
            if let audioPlayer = context.coordinator.audioPlayer {
                audioPlayer.replaceCurrentItem(with: auxiliaryAudioItem)
            } else {
                context.coordinator.audioPlayer = AVPlayer(playerItem: auxiliaryAudioItem)
            }
        } else {
            context.coordinator.audioPlayer?.pause()
            context.coordinator.audioPlayer = nil
        }
        print("YTNativePlayerView: player item replaced")
        context.coordinator.playbackItemToken = playbackItemToken
        context.coordinator.pendingStallRecoveryShouldResume = false
        context.coordinator.resetInitialSeek()
        context.coordinator.observePlayerItems(
            primary: playerItem,
            auxiliaryAudio: auxiliaryAudioItem
        )
        context.coordinator.installSubtitleOverlay(in: controller)
        context.coordinator.startObserving()
        context.coordinator.resetStallTracking()
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stopObserving()
        uiViewController.player?.pause()
        coordinator.audioPlayer?.pause()
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var player: AVPlayer?
        var audioPlayer: AVPlayer?
        var playbackItemToken: UUID?
        var initialTime: TimeInterval?
        private var recoveryMachine = YTPlaybackRecoveryMachine()
        private var recoveryWatchdog: DispatchWorkItem?
        private var recoveryWatchdogKind: YTPlaybackRecoveryWatchdogKind?
        private var currentTime: Binding<TimeInterval>
        private var duration: Binding<TimeInterval>
        private var subtitleState: YTSubtitleDisplayState
        var subtitlePreferences: SubtitlePresentationPreferences
        var playbackRate: Double
        var subtitleDisplayMode: String
        var onPlaybackEnded: () -> Void
        var onPlaybackFailed: (Int?, TimeInterval, Bool) -> Void
        var onAutoQualityStall: (Int?, TimeInterval, Bool) -> Void
        var onPresentationSizeChange: (CGSize) -> Void
        private var timeObserver: Any?
        private var playerRateObservation: NSKeyValueObservation?
        private var playerTimeControlObservation: NSKeyValueObservation?
        private var itemStatusObservation: NSKeyValueObservation?
        private var itemLikelyToKeepUpObservation: NSKeyValueObservation?
        private var audioItemStatusObservation: NSKeyValueObservation?
        private var audioItemLikelyToKeepUpObservation: NSKeyValueObservation?
        private var audioTimeControlObservation: NSKeyValueObservation?
        private var presentationSizeObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private var stalledObserver: NSObjectProtocol?
        private var audioStalledObserver: NSObjectProtocol?
        private var boundaryObserver: Any?
        private var observedRepeatRange: ClosedRange<TimeInterval>?
        private var lastConsumedCommandSequence = 0
        var overlayHost: UIHostingController<YTFullscreenSubtitleOverlay>?
        private var didSeekInitialPosition = false
        var shouldResumeAfterInitialSeek: Bool
        var isAutoQuality: Bool
        var onPlaybackStateChange: (Bool) -> Void
        var onEffectiveRateChange: (Double) -> Void

        var pendingStallRecoveryShouldResume = false
        private var lastAudioSyncTime: TimeInterval = 0
        private var pausedForPeerBuffering = false
        private var peerBufferingWaitingOnAudio: Bool?
        private var seekOperationGeneration = 0
        private var audioSyncGeneration = 0
        private var itemInstallStartedAt: Date?
        private var didLogReadyToPlay = false
        private var didLogFirstPlaying = false
#if DEBUG
        private var mediaLogObservers: [NSObjectProtocol] = []
#endif

        var trustedPlaybackPosition: TimeInterval {
            let current = currentTime.wrappedValue
            if recoveryMachine.shouldPublishObservedPlaybackTime,
               current.isFinite,
               current >= 0 {
                return current
            }
            let trusted = recoveryMachine.trustedRecoveryPosition
            if trusted > 0 { return trusted }
            if let playerTime = player?.currentTime().seconds,
               playerTime.isFinite,
               playerTime >= 0 {
                return playerTime
            }
            return max(0, current)
        }
        init(
            currentTime: Binding<TimeInterval>,
            duration: Binding<TimeInterval>,
            initialTime: TimeInterval?,
            subtitleState: YTSubtitleDisplayState,
            subtitlePreferences: SubtitlePresentationPreferences,
            playbackRate: Double,
            subtitleDisplayMode: String,
            playbackCommand: YTPlaybackCommand?,
            repeatRange: ClosedRange<TimeInterval>?,
            shouldResumeAfterInitialSeek: Bool,
            isAutoQuality: Bool,
            onPlaybackStateChange: @escaping (Bool) -> Void,
            onEffectiveRateChange: @escaping (Double) -> Void,
            onPlaybackEnded: @escaping () -> Void,
            onPlaybackFailed: @escaping (Int?, TimeInterval, Bool) -> Void,
            onAutoQualityStall: @escaping (Int?, TimeInterval, Bool) -> Void,
            onPresentationSizeChange: @escaping (CGSize) -> Void
        ) {
            self.currentTime = currentTime
            self.duration = duration
            self.initialTime = initialTime
            self.subtitleState = subtitleState
            self.subtitlePreferences = subtitlePreferences
            self.playbackRate = playbackRate
            self.subtitleDisplayMode = subtitleDisplayMode
            self.shouldResumeAfterInitialSeek = shouldResumeAfterInitialSeek
            self.isAutoQuality = isAutoQuality
            self.onPlaybackStateChange = onPlaybackStateChange
            self.onEffectiveRateChange = onEffectiveRateChange
            self.onPlaybackEnded = onPlaybackEnded
            self.onPlaybackFailed = onPlaybackFailed
            self.onAutoQualityStall = onAutoQualityStall
            self.onPresentationSizeChange = onPresentationSizeChange
            self.lastConsumedCommandSequence = playbackCommand?.sequence ?? 0
            self.observedRepeatRange = repeatRange
        }

        func resetStallTracking() {
            pendingStallRecoveryShouldResume = false
            pausedForPeerBuffering = false
            peerBufferingWaitingOnAudio = nil
            // Stall/prepare watchdogs are owned by the recovery machine generation.
        }

        func beginMediaItemRecovery(
            position: TimeInterval?,
            wantsPlayback: Bool,
            rate: Double
        ) {
            let snapshot = YTPlaybackRecoverySnapshot(
                position: max(0, position ?? 0),
                wantsPlayback: wantsPlayback,
                rate: rate > 0 ? rate : 1
            )
            let effect = recoveryMachine.handle(.beginItemReplace(snapshot: snapshot))
#if DEBUG
            print(
                "YTMediaRecoveryDiagnostic: begin phase=\(recoveryMachine.phase) generation=\(recoveryMachine.generation) target=\(String(format: "%.3f", snapshot.position)) wantsPlayback=\(snapshot.wantsPlayback) rate=\(snapshot.rate)"
            )
#endif
            applyRecoveryEffect(effect)
        }

        private func applyRecoveryEffect(_ effect: YTPlaybackRecoveryEffect) {
            switch effect {
            case .none:
                break
            case .scheduleWatchdog(let kind, let delay):
                scheduleRecoveryWatchdog(kind, after: delay)
            case .cancelWatchdog:
                cancelRecoveryWatchdog()
            case .requestDowngrade(let position, let wantsPlayback):
                cancelRecoveryWatchdog()
                pausePlayers()
                pendingStallRecoveryShouldResume = wantsPlayback
                let height = Int(player?.currentItem?.presentationSize.height ?? 0)
#if DEBUG
                print(
                    "YTMediaRecoveryDiagnostic: downgrade phase=\(recoveryMachine.phase) generation=\(recoveryMachine.generation) position=\(String(format: "%.3f", position)) wantsPlayback=\(wantsPlayback)"
                )
#endif
                onAutoQualityStall(
                    height > 0 ? height : nil,
                    position,
                    wantsPlayback
                )
            case .seekBothPlayers(let position, _, let rate):
                let generation = recoveryMachine.generation
                if position < 1 {
                    currentTime.wrappedValue = position
                    subtitleState.playbackTime = position
                    let effect = recoveryMachine.handle(
                        .restoreSeekSucceeded,
                        expectedGeneration: generation
                    )
                    applyRecoveryEffect(effect)
                    return
                }
                let time = CMTime(seconds: position, preferredTimescale: 600)
                seekPlayers(
                    to: time,
                    resume: false,
                    rate: Float(rate)
                ) { [weak self] finished in
                    guard let self else { return }
                    let event: YTPlaybackRecoveryEvent =
                        finished ? .restoreSeekSucceeded : .restoreSeekFailed
                    let effect = self.recoveryMachine.handle(
                        event,
                        expectedGeneration: generation
                    )
                    if finished {
                        self.currentTime.wrappedValue = position
                        self.subtitleState.playbackTime = position
                        self.didSeekInitialPosition = true
                    }
                    self.applyRecoveryEffect(effect)
                }
            case .resumePlayback(let rate):
                didSeekInitialPosition = true
                playPlayers(atRate: Float(rate))
            case .stayPaused:
                didSeekInitialPosition = true
                pausePlayers()
            }
        }

        private func scheduleRecoveryWatchdog(
            _ kind: YTPlaybackRecoveryWatchdogKind,
            after delay: TimeInterval
        ) {
            cancelRecoveryWatchdog()
            let generation = recoveryMachine.generation
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.recoveryMachine.generation == generation else { return }

                if kind == .sustainedStall {
                    let isWaiting = self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let audioIsWaiting =
                        self.audioPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let stillStalled =
                        !self.allItemsLikelyToKeepUp || isWaiting || audioIsWaiting
                    let wantsPlayback =
                        (self.player?.rate ?? 0) > 0
                        || isWaiting
                        || self.pausedForPeerBuffering
                        || (self.recoveryMachine.snapshot?.wantsPlayback == true)
                    if !stillStalled || !wantsPlayback {
                        let effect = self.recoveryMachine.handle(
                            .keepUpChanged(true),
                            expectedGeneration: generation
                        )
                        self.applyRecoveryEffect(effect)
                        return
                    }
                    // Refresh trusted position before the machine emits downgrade.
                    self.recoveryMachine.noteObservedPosition(self.trustedPlaybackPosition)
                }

                let event: YTPlaybackRecoveryEvent =
                    kind == .prepareTimeout ? .prepareWatchdogFired : .stallWatchdogFired
                let effect = self.recoveryMachine.handle(
                    event,
                    expectedGeneration: generation
                )
                self.applyRecoveryEffect(effect)
            }
            recoveryWatchdog = work
            recoveryWatchdogKind = kind
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func cancelRecoveryWatchdog() {
            recoveryWatchdog?.cancel()
            recoveryWatchdog = nil
            recoveryWatchdogKind = nil
        }

        private func handleItemsReadyForRecoveryIfNeeded() {
            guard allItemsReady else { return }
            let generation = recoveryMachine.generation
            guard recoveryMachine.phase == .preparing else { return }
            let effect = recoveryMachine.handle(
                .itemsReady,
                expectedGeneration: generation
            )
#if DEBUG
            print(
                "YTMediaRecoveryDiagnostic: items-ready generation=\(generation) effect=\(String(describing: effect))"
            )
#endif
            applyRecoveryEffect(effect)
        }

        private func noteSustainablePlaybackIfNeeded() {
            guard recoveryMachine.phase == .warmingUp,
                  allItemsLikelyToKeepUp
            else {
                return
            }
            let effect = recoveryMachine.handle(
                .firstSustainablePlayback,
                expectedGeneration: recoveryMachine.generation
            )
            applyRecoveryEffect(effect)
        }

        private var allItemsLikelyToKeepUp: Bool {
            guard player?.currentItem?.isPlaybackLikelyToKeepUp == true else { return false }
            guard let audioItem = audioPlayer?.currentItem else { return true }
            return audioItem.isPlaybackLikelyToKeepUp
        }

        private var allItemsReady: Bool {
            guard player?.currentItem?.status == .readyToPlay else { return false }
            guard let audioItem = audioPlayer?.currentItem else { return true }
            return audioItem.status == .readyToPlay
        }

        private func syncAuxiliaryAudioIfNeeded(videoTime: TimeInterval) {
            guard videoTime - lastAudioSyncTime >= 1,
                  let audioPlayer,
                  audioPlayer.currentItem?.status == .readyToPlay
            else {
                return
            }
            lastAudioSyncTime = videoTime
            let audioTime = audioPlayer.currentTime().seconds
            guard case .seekAudio(let target) = YTDualPlayerSyncPolicy.action(
                videoTime: videoTime,
                audioTime: audioTime
            ) else {
                return
            }
            let time = CMTime(seconds: target, preferredTimescale: 600)
            let operationGeneration = seekOperationGeneration
            audioSyncGeneration += 1
            let syncGeneration = audioSyncGeneration
            let primaryItem = player?.currentItem
            let audioItem = audioPlayer.currentItem
            audioPlayer.seek(
                to: time,
                toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)
            ) { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self,
                          finished,
                          self.seekOperationGeneration == operationGeneration,
                          self.audioSyncGeneration == syncGeneration,
                          self.player?.currentItem === primaryItem,
                          self.audioPlayer?.currentItem === audioItem,
                          (self.player?.rate ?? 0) > 0
                    else {
                        return
                    }
                    self.audioPlayer?.playImmediately(atRate: Float(self.playbackRate))
                }
            }
        }

        func installSubtitleOverlay(in controller: AVPlayerViewController) {
            guard overlayHost == nil, let overlay = controller.contentOverlayView else { return }
            let host = UIHostingController(rootView: fullscreenSubtitleOverlay)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: YTPlayerPlatformSupport.subtitleBottomOffset)
            ])
            host.view.isUserInteractionEnabled = false
            host.view.isHidden = YTPlayerPlatformSupport.subtitleOverlayInitiallyHidden
            overlayHost = host
        }

        func updateSubtitleOverlay() {
            overlayHost?.rootView = fullscreenSubtitleOverlay
        }

        private var fullscreenSubtitleOverlay: YTFullscreenSubtitleOverlay {
            YTFullscreenSubtitleOverlay(
                subtitleState: subtitleState,
                subtitlePreferences: subtitlePreferences,
                subtitleDisplayMode: subtitleDisplayMode
            )
        }

        // AVPlayer resets rate to 0 on pause and to 1 on play; re-apply the desired
        // rate whenever playback is actually running at a different speed.
        func applyPlaybackRateIfNeeded() {
            guard let player else { return }
            let target = Float(playbackRate)
            guard target > 0, player.rate > 0 else { return }
            if abs(player.rate - target) > 0.01 {
                player.rate = target
            }
            if let audioPlayer, abs(audioPlayer.rate - target) > 0.01 {
                audioPlayer.rate = target
            }
        }

        private func playPlayers(atRate rate: Float) {
            audioPlayer?.playImmediately(atRate: rate)
            player?.playImmediately(atRate: rate)
        }

        private func pausePlayers() {
            player?.pause()
            audioPlayer?.pause()
        }

        private func pauseForPeerBufferingIfNeeded(waitingOnAudio: Bool) {
            guard didSeekInitialPosition, !pausedForPeerBuffering else { return }
            let shouldResume =
                (player?.rate ?? 0) > 0
                || player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                || (audioPlayer?.rate ?? 0) > 0
                || audioPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            guard shouldResume else { return }
            pausedForPeerBuffering = true
            peerBufferingWaitingOnAudio = waitingOnAudio
            if waitingOnAudio {
                player?.pause()
            } else {
                audioPlayer?.pause()
            }
        }

        private func resumeAfterPeerBufferingIfPossible() {
            guard pausedForPeerBuffering, allItemsLikelyToKeepUp, let player else { return }
            pausedForPeerBuffering = false
            peerBufferingWaitingOnAudio = nil
            let time = player.currentTime()
            seekPlayers(
                to: time,
                resume: true,
                rate: Float(playbackRate)
            )
        }

        private func mirrorPrimaryPlaybackState() {
            guard let player, let audioPlayer else { return }
            if player.rate > 0 {
                guard audioPlayer.currentItem?.status == .readyToPlay else { return }
                let target = Float(playbackRate)
                if abs(audioPlayer.rate - target) > 0.01 {
                    audioPlayer.playImmediately(atRate: target)
                }
            } else if player.timeControlStatus == .paused,
                      !(pausedForPeerBuffering && peerBufferingWaitingOnAudio == true) {
                audioPlayer.pause()
            }
        }

        private func seekPlayers(
            to time: CMTime,
            resume: Bool,
            rate: Float,
            completion: ((Bool) -> Void)? = nil
        ) {
            guard let player else {
                completion?(false)
                return
            }
            lastAudioSyncTime = max(0, time.seconds - 1)
            seekOperationGeneration += 1
            audioSyncGeneration += 1
            let operationGeneration = seekOperationGeneration
            let primaryItem = player.currentItem
            let audioItem = audioPlayer?.currentItem
            let group = DispatchGroup()
            var primaryFinished = false
            var audioFinished = audioPlayer == nil
            group.enter()
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
#if DEBUG
                print(
                    "YTMediaSeekDiagnostic: primary-completion finished=\(finished) target=\(String(format: "%.3f", time.seconds)) actual=\(String(format: "%.3f", player.currentTime().seconds))"
                )
#endif
                primaryFinished = finished
                group.leave()
            }
            if let audioPlayer {
                group.enter()
                audioPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
#if DEBUG
                    print(
                        "YTMediaSeekDiagnostic: auxiliary-completion finished=\(finished) target=\(String(format: "%.3f", time.seconds)) actual=\(String(format: "%.3f", audioPlayer.currentTime().seconds))"
                    )
#endif
                    audioFinished = finished
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                guard self.seekOperationGeneration == operationGeneration,
                      self.player?.currentItem === primaryItem,
                      self.audioPlayer?.currentItem === audioItem
                else {
                    completion?(false)
                    return
                }
                let finished = primaryFinished && audioFinished
#if DEBUG
                print(
                    "YTMediaSeekDiagnostic: group-completion finished=\(finished) target=\(String(format: "%.3f", time.seconds)) resume=\(resume) primary=\(String(format: "%.3f", player.currentTime().seconds)) auxiliary=\(audioPlayer.map { String(format: "%.3f", $0.currentTime().seconds) } ?? "-")"
                )
#endif
                if finished {
                    if resume {
                        self.playPlayers(atRate: rate)
                    } else {
                        self.pausePlayers()
                    }
                } else {
                    self.pausePlayers()
                }
                completion?(finished)
            }
        }

        func consume(_ command: YTPlaybackCommand?) {
            guard let command, command.sequence > lastConsumedCommandSequence, player != nil else { return }
            lastConsumedCommandSequence = command.sequence

            if !recoveryMachine.shouldApplyCommandsDirectlyToPlayer {
                let recoveryCommand: YTPlaybackRecoveryCommand
                switch command.action {
                case .play:
                    recoveryCommand = .play
                case .pause:
                    recoveryCommand = .pause
                case .seek(let seconds, let resumeAfterSeek):
                    recoveryCommand = .seek(seconds, resumeAfterSeek: resumeAfterSeek)
                }
                _ = recoveryMachine.handle(.command(recoveryCommand))
#if DEBUG
                print(
                    "YTMediaRecoveryDiagnostic: deferred-command generation=\(recoveryMachine.generation) snapshot=\(String(describing: recoveryMachine.snapshot))"
                )
#endif
                return
            }

            switch command.action {
            case .play:
                seekOperationGeneration += 1
                pausedForPeerBuffering = false
                peerBufferingWaitingOnAudio = nil
                playPlayers(atRate: Float(playbackRate))
            case .pause:
                seekOperationGeneration += 1
                pausedForPeerBuffering = false
                peerBufferingWaitingOnAudio = nil
                pausePlayers()
            case .seek(let seconds, let resumeAfterSeek):
                let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
                seekPlayers(
                    to: time,
                    resume: resumeAfterSeek,
                    rate: Float(playbackRate)
                ) { [weak self] finished in
                    guard finished else { return }
                    self?.currentTime.wrappedValue = seconds
                    self?.recoveryMachine.noteObservedPosition(seconds)
                }
            }
        }

        func updateRepeatRange(_ range: ClosedRange<TimeInterval>?) {
            guard observedRepeatRange != range || (range != nil && boundaryObserver == nil) else { return }
            removeBoundaryObserver()
            observedRepeatRange = range
            guard let range, let player else { return }
            let boundary = CMTime(seconds: range.upperBound, preferredTimescale: 600)
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: boundary)],
                queue: .main
            ) { [weak self] in
                guard let self, self.observedRepeatRange == range else { return }
                let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
                self.seekPlayers(
                    to: start,
                    resume: true,
                    rate: Float(self.playbackRate)
                ) { [weak self] finished in
                    guard finished else { return }
                    self?.currentTime.wrappedValue = range.lowerBound
                    self?.recoveryMachine.noteObservedPosition(range.lowerBound)
                }
            }
        }

        func startObserving() {
            guard let player else { return }
            if timeObserver == nil {
                playerRateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.applyPlaybackRateIfNeeded()
                        self.mirrorPrimaryPlaybackState()
                        let isPlaying = (self.player?.rate ?? 0) > 0
                        self.onPlaybackStateChange(isPlaying)
                        if isPlaying {
                            self.onEffectiveRateChange(Double(self.player?.rate ?? 1))
                        }
                        if self.player?.currentItem?.isPlaybackLikelyToKeepUp == false,
                           isPlaying || self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                            self.handleLikelyToKeepUp(false)
                        }
                    }
                }
                playerTimeControlObservation = player.observe(
                    \.timeControlStatus,
                    options: [.initial, .new]
                ) { [weak self] player, _ in
                    DispatchQueue.main.async {
                        guard let self, self.player === player else { return }
#if DEBUG
                        let current = player.currentTime().seconds
                        let status: String
                        switch player.timeControlStatus {
                        case .paused: status = "paused"
                        case .waitingToPlayAtSpecifiedRate: status = "waiting"
                        case .playing: status = "playing"
                        @unknown default: status = "unknown"
                        }
                        print(
                            "YTMediaAVDiagnostic: timeControl status=\(status) rate=\(player.rate) current=\(current.isFinite ? String(format: "%.3f", current) : "-") waitingReason=\(player.reasonForWaitingToPlay?.rawValue ?? "-") ranges=[\(YTPlaybackDiagnosticSanitizer.timeRanges(player.currentItem))]"
                        )
#endif
                        switch player.timeControlStatus {
                        case .waitingToPlayAtSpecifiedRate:
                            self.pauseForPeerBufferingIfNeeded(waitingOnAudio: false)
                            self.handleLikelyToKeepUp(false)
                        case .playing:
                            self.logFirstPlayingIfNeeded()
                            self.mirrorPrimaryPlaybackState()
                            if player.currentItem?.isPlaybackLikelyToKeepUp == true {
                                self.handleLikelyToKeepUp(self.allItemsLikelyToKeepUp)
                            }
                        case .paused:
                            self.mirrorPrimaryPlaybackState()
                        @unknown default:
                            break
                        }
                    }
                }
                updateRepeatRange(observedRepeatRange)
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                    queue: .main
                ) { [weak self] time in
                    guard let self else { return }
                    let seconds = time.seconds.isFinite ? time.seconds : 0
                    if self.recoveryMachine.shouldPublishObservedPlaybackTime {
                        self.currentTime.wrappedValue = seconds
                        self.subtitleState.playbackTime = seconds
                        self.recoveryMachine.noteObservedPosition(seconds)
                        self.syncAuxiliaryAudioIfNeeded(videoTime: seconds)
                    }
                    if let itemDuration = self.player?.currentItem?.duration.seconds,
                       itemDuration.isFinite,
                       itemDuration > 0 {
                        self.duration.wrappedValue = itemDuration
                    }
                }
            }
            observeAudioTimeControl()
        }

        private func observeAudioTimeControl() {
            audioTimeControlObservation = nil
            guard let audioPlayer else { return }
            audioTimeControlObservation = audioPlayer.observe(
                \.timeControlStatus,
                options: [.initial, .new]
            ) { [weak self] audioPlayer, _ in
                DispatchQueue.main.async {
                    guard let self, self.audioPlayer === audioPlayer else { return }
                    if audioPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        self.pauseForPeerBufferingIfNeeded(waitingOnAudio: true)
                        self.handleLikelyToKeepUp(false)
                    } else if audioPlayer.timeControlStatus == .playing {
                        self.handleLikelyToKeepUp(self.allItemsLikelyToKeepUp)
                    }
                }
            }
        }

        func stopObserving() {
            if let timeObserver {
                player?.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            playerRateObservation = nil
            playerTimeControlObservation = nil
            audioTimeControlObservation = nil
            itemStatusObservation = nil
            itemLikelyToKeepUpObservation = nil
            audioItemStatusObservation = nil
            audioItemLikelyToKeepUpObservation = nil
            presentationSizeObservation = nil
            cancelRecoveryWatchdog()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            if let stalledObserver {
                NotificationCenter.default.removeObserver(stalledObserver)
            }
            stalledObserver = nil
            if let audioStalledObserver {
                NotificationCenter.default.removeObserver(audioStalledObserver)
            }
            audioStalledObserver = nil
#if DEBUG
            removeMediaLogObservers()
#endif
            removeBoundaryObserver()
            audioPlayer?.pause()
        }

        func observePlayerItems(
            primary item: AVPlayerItem?,
            auxiliaryAudio audioItem: AVPlayerItem?
        ) {
            itemStatusObservation = nil
            itemLikelyToKeepUpObservation = nil
            audioItemStatusObservation = nil
            audioItemLikelyToKeepUpObservation = nil
            presentationSizeObservation = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            if let stalledObserver {
                NotificationCenter.default.removeObserver(stalledObserver)
            }
            stalledObserver = nil
            if let audioStalledObserver {
                NotificationCenter.default.removeObserver(audioStalledObserver)
            }
            audioStalledObserver = nil
#if DEBUG
            removeMediaLogObservers()
#endif
            guard let item else { return }
            itemInstallStartedAt = Date()
            didLogReadyToPlay = false
            didLogFirstPlaying = false
#if DEBUG
            installMediaLogObservers(for: item, label: "primary")
#endif
            itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard self?.player?.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    DispatchQueue.main.async {
                        guard let self, self.player?.currentItem === item else { return }
                        let duration = item.duration.seconds
                        if duration.isFinite, duration > 0 {
                            self.duration.wrappedValue = duration
                        }
                        if !self.didLogReadyToPlay {
                            self.didLogReadyToPlay = true
                            let ms = self.itemInstallStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                            print("YTNativePlayerView: item readyToPlay ms=\(ms)")
                        }
                        self.handleItemsReadyForRecoveryIfNeeded()
                    }
                case .failed:
                    print("YTNativePlayerView: item failed: \(item.error?.localizedDescription ?? "unknown")")
#if DEBUG
                    print(
                        "YTMediaAVDiagnostic: item-failed label=primary error=\(YTPlaybackDiagnosticSanitizer.errorSummary(item.error)) ranges=[\(YTPlaybackDiagnosticSanitizer.timeRanges(item))]"
                    )
#endif
                    DispatchQueue.main.async {
                        guard let self, self.player?.currentItem === item else { return }
                        self.cancelRecoveryWatchdog()
                        self.recoveryMachine.acknowledgeFallbackIssued()
                        let time = self.trustedPlaybackPosition
                        let wasPlaying =
                            (self.recoveryMachine.snapshot?.wantsPlayback
                                ?? self.shouldResumeAfterInitialSeek)
                            || (self.player?.rate ?? 0) > 0
                            || self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                        self.pendingStallRecoveryShouldResume = wasPlaying
                        let status = Self.httpStatus(from: item.error)
                        self.onPlaybackFailed(status, time, wasPlaying)
                    }
                case .unknown:
                    print("YTNativePlayerView: item status unknown")
                @unknown default:
                    print("YTNativePlayerView: item status unknown default")
                }
            }
            itemLikelyToKeepUpObservation = item.observe(
                \.isPlaybackLikelyToKeepUp,
                options: [.initial, .new]
            ) { [weak self] item, _ in
                print("YTNativePlayerView: isPlaybackLikelyToKeepUp=\(item.isPlaybackLikelyToKeepUp), loadedTimeRanges=\(item.loadedTimeRanges)")
                DispatchQueue.main.async {
                    guard let self, self.player?.currentItem === item else { return }
                    self.handleLikelyToKeepUp(self.allItemsLikelyToKeepUp)
                }
            }
            presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                let size = item.presentationSize
                DispatchQueue.main.async {
                    guard let self, self.player?.currentItem === item else { return }
                    self.onPresentationSizeChange(size)
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onPlaybackEnded()
            }
            stalledObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.player?.currentItem === item else { return }
#if DEBUG
                print(
                    "YTMediaAVDiagnostic: playback-stalled label=primary current=\(self.player?.currentTime().seconds ?? -1) ranges=[\(YTPlaybackDiagnosticSanitizer.timeRanges(item))] error=\(YTPlaybackDiagnosticSanitizer.errorSummary(item.error))"
                )
#endif
                self.handleLikelyToKeepUp(false)
            }

            guard let audioItem else { return }
#if DEBUG
            installMediaLogObservers(for: audioItem, label: "auxiliary-audio")
#endif
            audioItemStatusObservation = audioItem.observe(
                \.status,
                options: [.initial, .new]
            ) { [weak self] audioItem, _ in
                guard self?.audioPlayer?.currentItem === audioItem else { return }
                switch audioItem.status {
                case .readyToPlay:
                    DispatchQueue.main.async {
                        guard let self, self.audioPlayer?.currentItem === audioItem else { return }
                        self.handleItemsReadyForRecoveryIfNeeded()
                    }
                    print("YTNativePlayerView: auxiliary audio readyToPlay")
                case .failed:
                    print(
                        "YTNativePlayerView: auxiliary audio failed: \(audioItem.error?.localizedDescription ?? "unknown")"
                    )
#if DEBUG
                    print(
                        "YTMediaAVDiagnostic: item-failed label=auxiliary-audio error=\(YTPlaybackDiagnosticSanitizer.errorSummary(audioItem.error)) ranges=[\(YTPlaybackDiagnosticSanitizer.timeRanges(audioItem))]"
                    )
#endif
                    DispatchQueue.main.async {
                        guard let self, self.audioPlayer?.currentItem === audioItem else { return }
                        self.cancelRecoveryWatchdog()
                        self.recoveryMachine.acknowledgeFallbackIssued()
                        let wasPlaying =
                            (self.recoveryMachine.snapshot?.wantsPlayback
                                ?? self.shouldResumeAfterInitialSeek)
                            || (self.player?.rate ?? 0) > 0
                            || self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                        self.pendingStallRecoveryShouldResume = wasPlaying
                        self.onPlaybackFailed(
                            Self.httpStatus(from: audioItem.error),
                            self.trustedPlaybackPosition,
                            wasPlaying
                        )
                    }
                case .unknown:
                    print("YTNativePlayerView: auxiliary audio status unknown")
                @unknown default:
                    print("YTNativePlayerView: auxiliary audio status unknown default")
                }
            }
            audioItemLikelyToKeepUpObservation = audioItem.observe(
                \.isPlaybackLikelyToKeepUp,
                options: [.initial, .new]
            ) { [weak self] audioItem, _ in
                print(
                    "YTNativePlayerView: auxiliary audio likelyToKeepUp=\(audioItem.isPlaybackLikelyToKeepUp), loadedTimeRanges=\(audioItem.loadedTimeRanges)"
                )
                DispatchQueue.main.async {
                    guard let self, self.audioPlayer?.currentItem === audioItem else { return }
                    self.handleLikelyToKeepUp(self.allItemsLikelyToKeepUp)
                }
            }
            audioStalledObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: audioItem,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.audioPlayer?.currentItem === audioItem else { return }
#if DEBUG
                print(
                    "YTMediaAVDiagnostic: playback-stalled label=auxiliary-audio current=\(self.audioPlayer?.currentTime().seconds ?? -1) ranges=[\(YTPlaybackDiagnosticSanitizer.timeRanges(audioItem))] error=\(YTPlaybackDiagnosticSanitizer.errorSummary(audioItem.error))"
                )
#endif
                self.handleLikelyToKeepUp(false)
            }
        }

#if DEBUG
        private func installMediaLogObservers(for item: AVPlayerItem, label: String) {
            let center = NotificationCenter.default
            mediaLogObservers.append(
                center.addObserver(
                    forName: .AVPlayerItemNewErrorLogEntry,
                    object: item,
                    queue: .main
                ) { [weak item] _ in
                    guard let event = item?.errorLog()?.events.last else { return }
                    let uri = event.uri.flatMap(URL.init(string:))
                    print(
                        "YTMediaAVDiagnostic: error-log label=\(label) status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(event.errorComment ?? "-") \(YTPlaybackDiagnosticSanitizer.urlSummary(uri))"
                    )
                }
            )
            mediaLogObservers.append(
                center.addObserver(
                    forName: .AVPlayerItemNewAccessLogEntry,
                    object: item,
                    queue: .main
                ) { [weak item] _ in
                    guard let event = item?.accessLog()?.events.last else { return }
                    let uri = event.uri.flatMap(URL.init(string:))
                    print(
                        "YTMediaAVDiagnostic: access-log label=\(label) stalls=\(event.numberOfStalls) observedBitrate=\(Int(event.observedBitrate)) indicatedBitrate=\(Int(event.indicatedBitrate)) bytes=\(event.numberOfBytesTransferred) transferDuration=\(String(format: "%.3f", event.transferDuration)) \(YTPlaybackDiagnosticSanitizer.urlSummary(uri))"
                    )
                }
            )
        }

        private func removeMediaLogObservers() {
            let center = NotificationCenter.default
            for observer in mediaLogObservers {
                center.removeObserver(observer)
            }
            mediaLogObservers.removeAll()
        }
#endif

        func resetInitialSeek() {
            didSeekInitialPosition = false
            lastAudioSyncTime = 0
            pausedForPeerBuffering = false
            peerBufferingWaitingOnAudio = nil
            seekOperationGeneration += 1
            audioSyncGeneration += 1
        }

        private func handleLikelyToKeepUp(_ keepUp: Bool) {
            if keepUp {
                resumeAfterPeerBufferingIfPossible()
                noteSustainablePlaybackIfNeeded()
            }
            let effect = recoveryMachine.handle(
                .keepUpChanged(keepUp),
                expectedGeneration: recoveryMachine.generation
            )
            applyRecoveryEffect(effect)
        }

        private func logFirstPlayingIfNeeded() {
            guard !didLogFirstPlaying else { return }
            didLogFirstPlaying = true
            let ms = itemInstallStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            print("YTNativePlayerView: first playing ms=\(ms)")
            noteSustainablePlaybackIfNeeded()
        }

        private static func httpStatus(from error: Error?) -> Int? {
            guard let error else { return nil }
            let nsError = error as NSError
            if let status = nsError.userInfo["statusCode"] as? Int { return status }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                if let status = underlying.userInfo["statusCode"] as? Int { return status }
            }
            let text = nsError.localizedDescription
            for code in [403, 410, 429] where text.contains(String(code)) {
                return code
            }
            return nil
        }

        private func removeBoundaryObserver() {
            if let boundaryObserver {
                player?.removeTimeObserver(boundaryObserver)
            }
            boundaryObserver = nil
        }
    }
}

struct YTFullscreenSubtitleOverlay: View {
    var subtitleState: YTSubtitleDisplayState
    var subtitlePreferences: SubtitlePresentationPreferences = .default
    var subtitleDisplayMode: String = AppConfiguration.defaultSubtitleDisplayMode

    private var currentSegment: LearningSegment? {
        subtitleState.segment(at: subtitleState.playbackTime)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 24)
            YTSubtitleDisplayView(
                english: currentSegment?.text,
                translation: {
                    let value = currentSegment?.translation.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return value.isEmpty ? nil : value
                }(),
                errorMessage: subtitleState.errorMessage,
                isPreparing: currentSegment == nil && subtitleState.segments.isEmpty,
                preferences: subtitlePreferences,
                displayMode: subtitleDisplayMode
            )
            Spacer(minLength: 24)
        }
        .allowsHitTesting(false)
    }
}

enum YTStreamResolverError: LocalizedError {
    case noPlayableStream
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noPlayableStream:
            L10n.string("ytplayer.no_usable_video_stream_was_resolved", fallback: "No usable video stream was resolved.")
        case .badResponse(let message):
            message
        }
    }
}

@Observable
final class YTStreamResolver {
    // YouTube Data API does not expose playable stream URLs or a tvOS native player.
    // Apple TV playback keeps this existing compatibility path while channel/video
    // metadata now comes from the official Data API.
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamURL(videoID: String) async throws -> URL {
        try await streamURL(videoID: videoID, policy: nil)
    }

    // When `policy` is provided it overrides the platform default for every client attempt.
    func streamURL(videoID: String, policy: YTStreamSelectionPolicy?) async throws -> URL {
        var lastError: Error?
        for client in YTStreamClient.allCases {
            do {
                if let url = try await streamURL(videoID: videoID, client: client, policy: policy) {
                    return url
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw YTStreamResolverError.noPlayableStream
    }

    private func streamURL(videoID: String, client: YTStreamClient, policy: YTStreamSelectionPolicy?) async throws -> URL? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw YTStreamResolverError.noPlayableStream
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.headerName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: playerBody(videoID: videoID, client: client))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YTStreamResolverError.badResponse("YouTube stream API failed (HTTP \(status)).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let status = ((object["playabilityStatus"] as? [String: Any])?["status"] as? String),
           status != "OK" {
            return nil
        }
        guard let streamingData = object["streamingData"] as? [String: Any] else {
            return nil
        }
        if let hls = streamingData["hlsManifestUrl"] as? String,
           let url = URL(string: hls) {
            return url
        }
        let formats = streamingData["formats"] as? [[String: Any]] ?? []
        let resolvedPolicy = policy ?? YTPlayerPlatformSupport.streamSelectionPolicy
        if let url = YTStreamFormatSelector.selectURL(from: formats, policy: resolvedPolicy) {
            return url
        }
        return nil
    }

    private func playerBody(videoID: String, client: YTStreamClient) -> [String: Any] {
        [
            "context": [
                "client": client.context
            ],
            "videoId": videoID,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
    }
}

struct YTStreamClient {
    var name: String
    var version: String
    var headerName: String
    var userAgent: String
    var extraContext: [String: Any]

    var context: [String: Any] {
        var value = extraContext
        value["clientName"] = name
        value["clientVersion"] = version
        value["userAgent"] = userAgent
        value["hl"] = "en"
        value["timeZone"] = "UTC"
        value["utcOffsetMinutes"] = 0
        return value
    }

    static let allCases: [YTStreamClient] = [.android, .ios]

    static let android = YTStreamClient(
        name: "ANDROID",
        version: "21.02.35",
        headerName: "3",
        userAgent: "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
        extraContext: [
            "androidSdkVersion": 30,
            "osName": "Android",
            "osVersion": "11"
        ]
    )

    static let ios = YTStreamClient(
        name: "IOS",
        version: "21.02.3",
        headerName: "5",
        userAgent: "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extraContext: [
            "deviceMake": "Apple",
            "deviceModel": "iPhone16,2",
            "osName": "iPhone",
            "osVersion": "18.3.2.22D82"
        ]
    )
}
