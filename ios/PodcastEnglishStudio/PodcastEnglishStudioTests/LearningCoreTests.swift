import XCTest
@testable import PodcastEnglishStudioCore

final class LearningCoreTests: XCTestCase {
    func testTaskCancellationIsNotPresentedAsAUserFacingFailure() {
        XCTAssertFalse(AsyncOperationErrorPresentationPolicy.shouldPresent(CancellationError()))
        XCTAssertTrue(
            AsyncOperationErrorPresentationPolicy.shouldPresent(
                NSError(domain: "SubtitleTranslation", code: 1)
            )
        )
    }

    func testTranslationTargetsExposeExactlyTheNineSupportedDestinations() {
        XCTAssertEqual(
            TranslationTarget.allCases.map(\.rawValue),
            ["zh-Hans", "zh-Hant", "es", "pt-BR", "ja", "ko", "fr", "de", "ar"]
        )
        XCTAssertEqual(TranslationTarget.traditionalChinese.autonym, "繁體中文")
        XCTAssertEqual(TranslationTarget.brazilianPortuguese.promptName, "Brazilian Portuguese")
        XCTAssertEqual(TranslationTarget.simplifiedChinese.fileComponent, "zh-Hans")
    }

    func testTranslationTargetPolicyMatchesSystemLanguageAndFallsBackToSimplifiedChinese() {
        XCTAssertEqual(
            TranslationTargetPolicy.defaultTarget(preferredLanguageIdentifiers: ["pt-PT", "pt-BR", "en-US"]),
            .brazilianPortuguese
        )
        XCTAssertEqual(
            TranslationTargetPolicy.defaultTarget(preferredLanguageIdentifiers: ["ar-SA"]),
            .arabic
        )
        XCTAssertEqual(
            TranslationTargetPolicy.defaultTarget(preferredLanguageIdentifiers: ["en-US"]),
            .simplifiedChinese
        )
        XCTAssertEqual(TranslationTargetPolicy.normalized("future-language"), .simplifiedChinese)
    }

    func testTranslationVariantIdentitySeparatesContentKindsAndLanguages() {
        XCTAssertEqual(
            TranslationVariantIdentity.make(contentKind: .podcastEpisode, contentID: "episode/42", target: .spanish),
            "podcastEpisode:episode%2F42:es"
        )
        XCTAssertNotEqual(
            TranslationVariantIdentity.make(contentKind: .podcastEpisode, contentID: "42", target: .spanish),
            TranslationVariantIdentity.make(contentKind: .youtubeVideo, contentID: "42", target: .spanish)
        )
        XCTAssertNotEqual(
            TranslationVariantIdentity.make(contentKind: .youtubeVideo, contentID: "42", target: .spanish),
            TranslationVariantIdentity.make(contentKind: .youtubeVideo, contentID: "42", target: .japanese)
        )
    }

    func testLegacyChinesePipelineMessagesNormalizeToStableCodes() {
        XCTAssertEqual(LegacyPipelineStatusPolicy.normalizedCode(step: "", message: "等待语音转文字"), "transcribe")
        XCTAssertEqual(LegacyPipelineStatusPolicy.normalizedCode(step: "legacy", message: "双语字幕已就绪"), "completed")
        XCTAssertEqual(LegacyPipelineStatusPolicy.normalizedCode(step: "future_code", message: "unknown detail"), "future_code")
    }

    func testTranslationPromptNamesTheSelectedTargetAndScript() {
        let traditional = TranslationPromptPolicy.batchSystemPrompt(
            target: .traditionalChinese,
            topicSummary: "A topic.",
            terms: [],
            contextBefore: [],
            contextAfter: [],
            qualityMode: .quality
        )
        let portuguese = TranslationPromptPolicy.singleSystemPrompt(
            target: .brazilianPortuguese,
            topicSummary: "A topic.",
            terms: [],
            qualityMode: .fast
        )

        XCTAssertTrue(traditional.contains("Traditional Chinese"))
        XCTAssertTrue(traditional.contains("\"final\""))
        XCTAssertTrue(traditional.contains("zh-Hant"))
        XCTAssertTrue(traditional.lowercased().contains("json"))
        XCTAssertTrue(portuguese.contains("Brazilian Portuguese"))
        XCTAssertTrue(portuguese.contains("\"direct\""))
        XCTAssertTrue(portuguese.contains("pt-BR"))
        XCTAssertTrue(portuguese.lowercased().contains("json"))
    }

    func testTranslationPromptJSONContractsIncludeLiteralJsonAndObjectExamples() {
        let context = TranslationPromptPolicy.contextExtractionSystemPrompt(target: .simplifiedChinese)
        let split = TranslationPromptPolicy.alignedTranslationSplitSystemPrompt(
            target: .spanish,
            partCount: 3
        )

        for prompt in [context, split, ContentFilterAgentPolicy.systemPrompt] {
            XCTAssertTrue(prompt.lowercased().contains("json"), prompt)
        }
        XCTAssertTrue(context.contains("\"summary\""))
        XCTAssertTrue(context.contains("\"terms\""))
        XCTAssertTrue(split.contains("\"parts\""))
        XCTAssertTrue(ContentFilterAgentPolicy.systemPrompt.contains("\"items\""))
    }

    func testContentFilterAgentPolicyParsesItemsObjectAndLegacyArray() {
        let objectJSON = """
        {"items":[{"id":"a","hide":true},{"id":"b","hide":false}]}
        """
        XCTAssertEqual(
            ContentFilterAgentPolicy.parseVerdicts(from: objectJSON),
            ["a": true, "b": false]
        )

        let legacyArray = """
        [{"id":"c","hide":true},{"id":1,"hide":"yes"}]
        """
        XCTAssertEqual(
            ContentFilterAgentPolicy.parseVerdicts(from: legacyArray),
            ["c": true, "1": true]
        )

        let fenced = """
        ```json
        {"items":[{"id":"d","hide":0}]}
        ```
        """
        XCTAssertEqual(ContentFilterAgentPolicy.parseVerdicts(from: fenced), ["d": false])
        XCTAssertEqual(ContentFilterAgentPolicy.parseVerdicts(from: "not json"), [:])
    }

    func testTranslationChatResponsePolicyExtractsContentAndRetriesEmptyDeepSeekOnce() {
        let payload: [String: Any] = [
            "choices": [
                ["message": ["content": "  {\"ok\":true}  "]]
            ]
        ]
        XCTAssertEqual(
            TranslationChatResponsePolicy.extractContent(from: payload),
            "  {\"ok\":true}  "
        )
        XCTAssertFalse(TranslationChatResponsePolicy.isEmptyContent("  {\"ok\":true}  "))
        XCTAssertTrue(TranslationChatResponsePolicy.isEmptyContent(nil))
        XCTAssertTrue(TranslationChatResponsePolicy.isEmptyContent("   "))
        XCTAssertTrue(TranslationChatResponsePolicy.isEmptyContent(""))

        XCTAssertTrue(TranslationChatResponsePolicy.shouldRetryEmptyContent(provider: "deepseek", attempt: 1))
        XCTAssertTrue(TranslationChatResponsePolicy.shouldRetryEmptyContent(provider: " DeepSeek ", attempt: 1))
        XCTAssertFalse(TranslationChatResponsePolicy.shouldRetryEmptyContent(provider: "deepseek", attempt: 2))
        XCTAssertFalse(TranslationChatResponsePolicy.shouldRetryEmptyContent(provider: "dashscope", attempt: 1))
        XCTAssertFalse(TranslationChatResponsePolicy.shouldRetryEmptyContent(provider: "cerebras", attempt: 1))
    }

    func testAcceptLanguagePolicyHonorsQualityRegionAndEnglishFallback() {
        XCTAssertEqual(
            InterfaceLanguagePolicy.bestSupportedLanguage(
                acceptLanguageHeader: "fr-CA;q=0.8, pt-BR;q=0.9, en;q=0.7"
            ),
            "pt-BR"
        )
        XCTAssertEqual(
            InterfaceLanguagePolicy.bestSupportedLanguage(
                acceptLanguageHeader: "zh-TW, zh-CN;q=0.8"
            ),
            "zh-Hant"
        )
        XCTAssertEqual(
            InterfaceLanguagePolicy.bestSupportedLanguage(acceptLanguageHeader: "ru-RU, it;q=0.8"),
            "en"
        )
        XCTAssertEqual(InterfaceLanguagePolicy.bestSupportedLanguage(acceptLanguageHeader: "zh"), "zh-Hans")
        XCTAssertEqual(InterfaceLanguagePolicy.bestSupportedLanguage(acceptLanguageHeader: "pt-PT"), "pt-BR")
    }

    func testConfigurationReadinessSummarizesMissingRequiredKeys() {
        let summary = ConfigurationReadinessPolicy.summary(
            youtubeAPIKey: "yt",
            dashscopeAPIKey: "  ",
            translationAPIKey: "translator"
        )

        XCTAssertEqual(summary.completedCount, 2)
        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.missingRequirements, [.dashscopeAPIKey])
        XCTAssertFalse(summary.isComplete)
        XCTAssertFalse(summary.hasPodcastGenerationKeys)
        XCTAssertTrue(summary.hasYouTubeMetadataKey)
    }

    func testRefreshAvailabilityIncludesDisabledReasonWhileKeepingPodcastRefreshAllowedWithoutGenerationKeys() {
        let loading = SubscriptionRefreshAvailabilityPolicy.podcastRefreshAvailability(
            isLoading: true,
            hasRequiredGenerationKeys: true
        )
        let missingKeys = SubscriptionRefreshAvailabilityPolicy.podcastRefreshAvailability(
            isLoading: false,
            hasRequiredGenerationKeys: false
        )

        XCTAssertFalse(loading.canRefresh)
        XCTAssertEqual(loading.disabledReason, "正在刷新，请稍候。")
        XCTAssertTrue(missingKeys.canRefresh)
        XCTAssertNil(missingKeys.disabledReason)
    }

    func testPodcastSubscriptionRefreshDoesNotRequireGenerationKeys() {
        XCTAssertTrue(
            SubscriptionRefreshAvailabilityPolicy.canRefreshPodcastSubscriptions(
                isLoading: false,
                hasRequiredGenerationKeys: false
            )
        )
        XCTAssertFalse(
            SubscriptionRefreshAvailabilityPolicy.canRefreshPodcastSubscriptions(
                isLoading: true,
                hasRequiredGenerationKeys: true
            )
        )
    }

    func testPodcastEpisodeProcessingPolicyRequiresExplicitStartForQueuedEpisode() {
        XCTAssertEqual(
            PodcastEpisodeProcessingPolicy.action(status: "queued", hasGenerationKeys: true),
            .start
        )
        XCTAssertEqual(
            PodcastEpisodeProcessingPolicy.action(status: "queued", hasGenerationKeys: false),
            .openSettings
        )
    }

    func testPodcastEpisodeProcessingPolicySeparatesRetryRunningAndPlaybackStates() {
        XCTAssertEqual(
            PodcastEpisodeProcessingPolicy.action(status: "failed", hasGenerationKeys: true),
            .retry
        )
        XCTAssertEqual(
            PodcastEpisodeProcessingPolicy.action(status: "failed", hasGenerationKeys: false),
            .openSettings
        )
        XCTAssertEqual(
            PodcastEpisodeProcessingPolicy.action(status: "running", hasGenerationKeys: true),
            .none
        )
        XCTAssertEqual(
            PodcastEpisodeProcessingPolicy.action(status: "completed", hasGenerationKeys: true),
            .playback
        )
    }

    func testBuildLearningPackKeepsOnlyBilingualSubtitleSegments() {
        let segments = [
            LearningSegment(
                sequence: 1,
                startMS: 0,
                endMS: 1200,
                text: "  Consistency   creates progress.  ",
                translation: "坚持带来进步。"
            )
        ]

        let pack = LearningPackBuilder.buildPack(segments: segments)

        XCTAssertEqual(pack.segments.map(\.learningText), ["Consistency creates progress."])
        XCTAssertEqual(pack.segments.map(\.translation), ["坚持带来进步。"])
    }

    func testPlaybackProgressPolicyRestoresAndThrottlesPersistence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(PlaybackProgressPolicy.restorePosition(from: nil))
        XCTAssertNil(PlaybackProgressPolicy.restorePosition(from: 2.9))
        XCTAssertEqual(PlaybackProgressPolicy.restorePosition(from: 3.1) ?? 0, 3.1, accuracy: 0.001)

        XCTAssertFalse(
            PlaybackProgressPolicy.shouldPersist(
                currentTime: 2.5,
                lastPersistedTime: nil,
                lastPersistedAt: nil,
                now: now
            )
        )
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldPersist(
                currentTime: 10,
                lastPersistedTime: nil,
                lastPersistedAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldPersist(
                currentTime: 12,
                lastPersistedTime: 10,
                lastPersistedAt: now,
                now: now.addingTimeInterval(4.9)
            )
        )
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldPersist(
                currentTime: 15,
                lastPersistedTime: 10,
                lastPersistedAt: now,
                now: now.addingTimeInterval(5.1)
            )
        )
    }

    func testPlaybackSeekPolicyClampsAbsoluteAndRelativeTargetsToDuration() {
        XCTAssertEqual(PlaybackSeekPolicy.clampedTime(-4, duration: 120), 0)
        XCTAssertEqual(PlaybackSeekPolicy.clampedTime(45, duration: 120), 45)
        XCTAssertEqual(PlaybackSeekPolicy.clampedTime(140, duration: 120), 120)
        XCTAssertEqual(PlaybackSeekPolicy.offsetTime(from: 8, by: -15, duration: 120), 0)
        XCTAssertEqual(PlaybackSeekPolicy.offsetTime(from: 114, by: 15, duration: 120), 120)
    }

    func testPlaybackScrubbingKeepsTheDragValueStableUntilTheUserCommits() {
        var state = PlaybackScrubbingState()

        state.begin(at: 10, duration: 100)
        state.update(to: 30, duration: 100)

        XCTAssertEqual(state.displayedTime(playbackTime: 12), 30)
        XCTAssertEqual(state.end(), 30)
        XCTAssertEqual(state.displayedTime(playbackTime: 12), 12)
    }

    func testPlaybackProgressPolicyReturnsForcedValidPosition() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let position = PlaybackProgressPolicy.positionToPersist(
            currentTime: 12,
            lastPersistedTime: 42,
            lastPersistedAt: now,
            now: now.addingTimeInterval(1),
            force: true
        )

        XCTAssertEqual(position ?? 0, 12, accuracy: 0.001)
    }

    func testPlaybackProgressPolicyDoesNotForcePersistUnrestorablePosition() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(
            PlaybackProgressPolicy.positionToPersist(
                currentTime: 0,
                lastPersistedTime: 42,
                lastPersistedAt: now,
                now: now.addingTimeInterval(1),
                force: true
            )
        )
        XCTAssertNil(
            PlaybackProgressPolicy.positionToPersist(
                currentTime: 2.9,
                lastPersistedTime: 42,
                lastPersistedAt: now,
                now: now.addingTimeInterval(1),
                force: true
            )
        )
    }

    func testPlaybackProgressPolicyPositionToPersistHonorsThrottle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(
            PlaybackProgressPolicy.positionToPersist(
                currentTime: 12,
                lastPersistedTime: 10,
                lastPersistedAt: now,
                now: now.addingTimeInterval(4.9)
            )
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.positionToPersist(
                currentTime: 15,
                lastPersistedTime: 10,
                lastPersistedAt: now,
                now: now.addingTimeInterval(5.1)
            ) ?? 0,
            15,
            accuracy: 0.001
        )
    }

    func testPlaybackListPolicyClassifiesUnplayedInProgressAndPlayedVideos() {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            PlaybackListPolicy.category(
                playbackPosition: nil,
                duration: nil,
                completedAt: nil
            ),
            .unplayed
        )
        XCTAssertEqual(
            PlaybackListPolicy.category(
                playbackPosition: 42,
                duration: 100,
                completedAt: nil
            ),
            .inProgress
        )
        XCTAssertEqual(
            PlaybackListPolicy.category(
                playbackPosition: 95,
                duration: 100,
                completedAt: nil
            ),
            .played
        )
        XCTAssertEqual(
            PlaybackListPolicy.category(
                playbackPosition: 10,
                duration: 100,
                completedAt: completedAt
            ),
            .played
        )
    }

    func testPlaybackListPolicyKeepsNinetyFourPercentInProgress() {
        XCTAssertEqual(
            PlaybackListPolicy.category(
                playbackPosition: 94,
                duration: 100,
                completedAt: nil
            ),
            .inProgress
        )
    }

    func testPipelinePersistencePolicyBatchesLongSegmentLists() {
        let batches = PipelinePersistencePolicy.batches(
            totalCount: 250,
            batchSize: 100
        )

        XCTAssertEqual(batches.map(\.lowerBound), [0, 100, 200])
        XCTAssertEqual(batches.map(\.upperBound), [100, 200, 250])
    }

    func testEpisodePlaybackSegmentPolicySortsSegmentsForPlayback() {
        let segments = [
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "third"),
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "first"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "second")
        ]

        let sorted = EpisodePlaybackSegmentPolicy.sorted(segments)

        XCTAssertEqual(sorted.map(\.sequence), [1, 2, 3])
    }

    func testPlaybackSegmentIndexUsesLogarithmicSearchForLongPrograms() {
        let segments = (0..<10_000).map { index in
            LearningSegment(
                sequence: index + 1,
                startMS: index * 1_000,
                endMS: index * 1_000 + 999,
                text: "Segment \(index + 1)"
            )
        }
        let index = EpisodePlaybackSegmentIndex(segments: segments)

        let result = index.search(atMilliseconds: 9_500_250)

        XCTAssertEqual(result.sequence, 9_501)
        XCTAssertLessThanOrEqual(result.inspectedCount, 32)
    }

    func testPlaybackSegmentIndexHandlesUnsortedSegmentsGapsAndEdges() {
        let index = EpisodePlaybackSegmentIndex(segments: [
            LearningSegment(sequence: 3, startMS: 3_000, endMS: 3_999, text: "third"),
            LearningSegment(sequence: 1, startMS: 500, endMS: 1_499, text: "first"),
            LearningSegment(sequence: 2, startMS: 2_000, endMS: 2_999, text: "second")
        ])

        XCTAssertEqual(index.nearestSequence(at: 0), 1)
        XCTAssertEqual(index.nearestSequence(at: 1.75), 1)
        XCTAssertEqual(index.nearestSequence(at: 2.5), 2)
        XCTAssertEqual(index.nearestSequence(at: 10), 3)
        XCTAssertNil(EpisodePlaybackSegmentIndex(segments: []).nearestSequence(at: 1))
    }

    func testSentencePlaybackPolicyFindsCurrentAndAdjacentSegmentsAcrossTimelineGaps() {
        let segments = [
            LearningSegment(sequence: 30, startMS: 4_000, endMS: 4_999, text: "third"),
            LearningSegment(sequence: 10, startMS: 0, endMS: 999, text: "first"),
            LearningSegment(sequence: 20, startMS: 2_000, endMS: 2_999, text: "second")
        ]

        let context = SentencePlaybackPolicy.context(at: 3.5, segments: segments)

        XCTAssertEqual(context.current?.text, "second")
        XCTAssertEqual(context.previous?.text, "first")
        XCTAssertEqual(context.next?.text, "third")
        XCTAssertEqual(context.position, 2)
        XCTAssertEqual(context.totalCount, 3)
        XCTAssertEqual(context.repeatRange, 2.0...2.999)
    }

    func testSentencePlaybackPolicyClampsBeforeFirstAndAfterLastSegment() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 500, endMS: 1_499, text: "first"),
            LearningSegment(sequence: 2, startMS: 2_000, endMS: 2_999, text: "second")
        ]

        let before = SentencePlaybackPolicy.context(at: 0, segments: segments)
        let after = SentencePlaybackPolicy.context(at: 30, segments: segments)

        XCTAssertEqual(before.current?.text, "first")
        XCTAssertNil(before.previous)
        XCTAssertEqual(before.next?.text, "second")
        XCTAssertEqual(after.current?.text, "second")
        XCTAssertEqual(after.previous?.text, "first")
        XCTAssertNil(after.next)
    }

    func testSentencePlaybackPolicyUsesTimestampsWhenSequencesAreDuplicated() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 1_000, endMS: 1_999, text: "later duplicate"),
            LearningSegment(sequence: 1, startMS: 0, endMS: 999, text: "earlier duplicate"),
            LearningSegment(sequence: 2, startMS: 2_000, endMS: 2_999, text: "third")
        ]

        let context = SentencePlaybackPolicy.context(at: 1.2, segments: segments)

        XCTAssertEqual(context.current?.text, "later duplicate")
        XCTAssertEqual(context.previous?.text, "earlier duplicate")
        XCTAssertEqual(context.next?.text, "third")
        XCTAssertEqual(SentencePlaybackPolicy.startTime(for: context.current), 1.0)
    }

    func testSentencePlaybackPolicyReturnsEmptyContextWithoutSegments() {
        let context = SentencePlaybackPolicy.context(at: 10, segments: [])

        XCTAssertNil(context.current)
        XCTAssertNil(context.previous)
        XCTAssertNil(context.next)
        XCTAssertNil(context.position)
        XCTAssertEqual(context.totalCount, 0)
        XCTAssertNil(context.repeatRange)
        XCTAssertNil(SentencePlaybackPolicy.startTime(for: nil))
    }

    func testTranscriptFollowPolicyDoesNotTreatProgrammaticPositionFeedbackAsUserScrolling() {
        XCTAssertTrue(
            TranscriptFollowPolicy.isFollowing(
                after: .programmaticScrollPositionChanged,
                wasFollowing: true
            )
        )
    }

    func testTranscriptFollowPolicySuspendsForUserDragAndResumesWhenLocated() {
        let suspended = TranscriptFollowPolicy.isFollowing(
            after: .userDragBegan,
            wasFollowing: true
        )
        let resumed = TranscriptFollowPolicy.isFollowing(
            after: .locatePlayback,
            wasFollowing: suspended
        )

        XCTAssertFalse(suspended)
        XCTAssertTrue(resumed)
    }

    func testProgramPlaybackGroupingPolicyKeepsStableCategoryOrder() {
        let grouped = ProgramPlaybackGroupingPolicy.group(
            items: ["unplayed", "in-progress", "played"],
            category: { item in
                switch item {
                case "played": .played
                case "in-progress": .inProgress
                default: .unplayed
                }
            }
        )

        XCTAssertEqual(grouped.map(\.category), [.unplayed, .inProgress, .played])
        XCTAssertEqual(grouped.map(\.items), [["unplayed"], ["in-progress"], ["played"]])
    }

    func testTranslationBatchPlannerKeepsTenItemAndSixHundredCharacterLimits() {
        XCTAssertEqual(TranslationBatchPlanner.batchMaxItems, 10)
        XCTAssertEqual(TranslationBatchPlanner.batchMaxCharacters, 600)
        let itemLimited = (1...11).map {
            LearningSegment(sequence: $0, startMS: $0 * 1_000, endMS: $0 * 1_000 + 500, text: "segment \($0)")
        }

        XCTAssertEqual(
            TranslationBatchPlanner.batches(for: itemLimited).map(\.segments.count),
            [10, 1]
        )

        let longSegments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: String(repeating: "a", count: 400)),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: String(repeating: "b", count: 300)),
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "short")
        ]

        XCTAssertEqual(
            TranslationBatchPlanner.batches(for: longSegments).map { $0.segments.map(\.sequence) },
            [[1], [2, 3]]
        )
    }

    func testTranslationBatchPolicyUsesSmallerCerebrasBatchesForRateLimits() {
        XCTAssertEqual(TranslationBatchPolicy.maxItems(forProvider: "cerebras"), 8)
        XCTAssertEqual(TranslationBatchPolicy.maxCharacters(forProvider: "cerebras"), 600)
        XCTAssertEqual(TranslationBatchPolicy.maxItems(forProvider: "deepseek"), 10)
        XCTAssertEqual(TranslationBatchPolicy.maxCharacters(forProvider: "deepseek"), 600)

        let itemLimited = (1...9).map {
            LearningSegment(sequence: $0, startMS: $0 * 1_000, endMS: $0 * 1_000 + 500, text: "segment \($0)")
        }

        XCTAssertEqual(
            TranslationBatchPlanner.batches(for: itemLimited, provider: "cerebras").map(\.segments.count),
            [8, 1]
        )
    }

    func testTranslationConcurrencyPolicyScalesByProvider() {
        XCTAssertEqual(TranslationConcurrencyPolicy.maxConcurrentRequests(forProvider: "deepseek"), 6)
        XCTAssertEqual(TranslationConcurrencyPolicy.maxConcurrentRequests(forProvider: "DeepSeek"), 6)
        XCTAssertEqual(TranslationConcurrencyPolicy.maxConcurrentRequests(forProvider: "cerebras"), 1)
        XCTAssertEqual(TranslationConcurrencyPolicy.maxConcurrentRequests(forProvider: "dashscope"), 3)
        XCTAssertEqual(TranslationConcurrencyPolicy.maxConcurrentRequests(forProvider: "qwen"), 3)
    }

    func testTranslationMergeKeepsSequenceOrderWhenBatchResultsReturnOutOfOrder() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "one"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "two"),
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "three")
        ]

        let merged = TranslationResultMerger.apply(
            translationsBySequence: [3: "三", 1: "一", 2: "二"],
            to: segments
        )

        XCTAssertEqual(merged.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(merged.map(\.translation), ["一", "二", "三"])
    }

    func testTranscriptionFingerprintChangesWhenSegmentBoundariesDiverge() {
        let original = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "Hello there"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "How are you"),
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "I am fine")
        ]
        let forked = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 500, text: "Hello"),
            LearningSegment(sequence: 2, startMS: 500, endMS: 1_000, text: "there"),
            LearningSegment(sequence: 3, startMS: 1_000, endMS: 2_000, text: "How are you"),
            LearningSegment(sequence: 4, startMS: 2_000, endMS: 3_000, text: "I am fine")
        ]

        XCTAssertEqual(TranscriptionFingerprint.make(segments: original), TranscriptionFingerprint.make(segments: original))
        XCTAssertNotEqual(TranscriptionFingerprint.make(segments: original), TranscriptionFingerprint.make(segments: forked))
    }

    func testMergeSavedTranslationsUsesSequenceWhenFingerprintsMatch() {
        let source = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "one"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "two"),
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "three")
        ]
        let saved = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "one", translation: "一"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "two", translation: "二"),
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "three", translation: "三")
        ]

        let merged = TranslationResultMerger.mergeSavedTranslations(
            saved: saved,
            onto: source,
            savedFingerprint: TranscriptionFingerprint.make(segments: saved)
        )

        XCTAssertEqual(merged.map(\.translation), ["一", "二", "三"])
    }

    func testMergeSavedTranslationsSalvagesExactMatchesAndClearsShiftedTail() {
        // Old ASR: three segments. New ASR forks at segment 1 → off-by-one for the tail.
        let saved = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "Hello there", translation: "你好啊"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "How are you", translation: "你好吗"),
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "I am fine", translation: "我很好")
        ]
        let source = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 500, text: "Hello"),
            LearningSegment(sequence: 2, startMS: 500, endMS: 1_000, text: "there"),
            LearningSegment(sequence: 3, startMS: 1_000, endMS: 2_000, text: "How are you"),
            LearningSegment(sequence: 4, startMS: 2_000, endMS: 3_000, text: "I am fine")
        ]

        // Legacy sequence merge would produce the A1 off-by-one:
        // seq1→你好啊, seq2→你好吗, seq3→我很好, seq4→"" — "there" wrongly gets "你好吗".
        let naive = TranslationResultMerger.apply(
            translationsBySequence: Dictionary(uniqueKeysWithValues: saved.map { ($0.sequence, $0.translation) }),
            to: source
        )
        XCTAssertEqual(naive[1].translation, "你好吗")

        let merged = TranslationResultMerger.mergeSavedTranslations(
            saved: saved,
            onto: source,
            savedFingerprint: TranscriptionFingerprint.make(segments: saved)
        )

        XCTAssertEqual(merged[0].translation, "") // "Hello" — no exact match
        XCTAssertEqual(merged[1].translation, "") // "there" — no exact match
        XCTAssertEqual(merged[2].translation, "你好吗") // exact text + time salvage
        XCTAssertEqual(merged[3].translation, "我很好")
        XCTAssertEqual(merged.filter { $0.translation.isEmpty }.count, 2)
    }

    func testMergeSavedTranslationsInfersLegacyFingerprintFromSavedEnglish() {
        let source = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "alpha"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "beta")
        ]
        let saved = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "alpha", translation: "甲"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "beta", translation: "乙")
        ]

        let merged = TranslationResultMerger.mergeSavedTranslations(
            saved: saved,
            onto: source,
            savedFingerprint: nil
        )
        XCTAssertEqual(merged.map(\.translation), ["甲", "乙"])
    }

    func testTranslationBatchPlannerReportsOnlyMissingSequences() {
        let batch = TranslationBatch(
            id: 0,
            segments: [
                LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "one"),
                LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "two"),
                LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "three")
            ]
        )

        XCTAssertEqual(
            TranslationBatchPlanner.missingSequences(in: batch, translatedSequences: [1, 3]),
            [2]
        )
    }

    func testTranslationRetryPolicyRetriesOnlyTransientDeepSeekStatuses() {
        XCTAssertTrue(TranslationRetryPolicy.shouldRetryHTTPStatus(429, provider: "deepseek"))
        XCTAssertTrue(TranslationRetryPolicy.shouldRetryHTTPStatus(500, provider: "deepseek"))
        XCTAssertTrue(TranslationRetryPolicy.shouldRetryHTTPStatus(503, provider: "deepseek"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(400, provider: "deepseek"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(401, provider: "deepseek"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(402, provider: "deepseek"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(422, provider: "deepseek"))
        XCTAssertTrue(TranslationRetryPolicy.shouldRetryHTTPStatus(429, provider: "cerebras"))
        XCTAssertTrue(TranslationRetryPolicy.shouldRetryHTTPStatus(500, provider: "cerebras"))
        XCTAssertTrue(TranslationRetryPolicy.shouldRetryHTTPStatus(503, provider: "cerebras"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(400, provider: "cerebras"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(401, provider: "cerebras"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(422, provider: "cerebras"))
        XCTAssertFalse(TranslationRetryPolicy.shouldRetryHTTPStatus(429, provider: "dashscope"))
    }

    func testTranslationRetryPolicyUsesRetryAfterBeforeExponentialBackoff() {
        XCTAssertEqual(
            TranslationRetryPolicy.retryDelaySeconds(
                statusCode: 429,
                provider: "deepseek",
                attempt: 1,
                headers: ["Retry-After": "7"]
            ),
            7
        )
        XCTAssertEqual(
            TranslationRetryPolicy.retryDelaySeconds(
                statusCode: 429,
                provider: "deepseek",
                attempt: 1,
                headers: [:]
            ),
            2
        )
        XCTAssertEqual(
            TranslationRetryPolicy.retryDelaySeconds(
                statusCode: 500,
                provider: "deepseek",
                attempt: 2,
                headers: [:]
            ),
            4
        )
    }

    func testTranslationRetryPolicyUsesMinuteDelayForCerebrasTokenQuotaWithoutRetryAfter() {
        XCTAssertEqual(
            TranslationRetryPolicy.retryDelaySeconds(
                statusCode: 429,
                provider: "cerebras",
                attempt: 1,
                headers: [:]
            ),
            60
        )
        XCTAssertEqual(
            TranslationRetryPolicy.retryDelaySeconds(
                statusCode: 429,
                provider: "cerebras",
                attempt: 1,
                headers: ["Retry-After": "12"]
            ),
            12
        )
    }

    func testTranslationChatRequestBodyUsesDeepSeekModelAndReasoningEffort() {
        let body = TranslationChatRequestPolicy.requestBody(
            provider: "deepseek",
            modelID: "deepseek-v4-pro",
            reasoningEffort: "max",
            messages: [["role": "user", "content": "Translate this."]]
        )

        XCTAssertEqual(body["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(body["reasoning_effort"] as? String, "max")
        assertDeepSeekJSONOutputFields(in: body)
    }

    func testTranslationChatRequestBodyDefaultsDeepSeekModelAndReasoningEffort() {
        let body = TranslationChatRequestPolicy.requestBody(
            provider: "deepseek",
            modelID: " ",
            reasoningEffort: "",
            messages: []
        )

        XCTAssertEqual(body["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        assertDeepSeekJSONOutputFields(in: body)
    }

    func testTranslationChatRequestBodyEnablesJSONOutputForNormalizedDeepSeekProviders() {
        for provider in ["deepseek", "DeepSeek", "  DeepSeek  "] {
            let body = TranslationChatRequestPolicy.requestBody(
                provider: provider,
                modelID: "deepseek-v4-flash",
                reasoningEffort: "high",
                messages: []
            )
            assertDeepSeekJSONOutputFields(in: body)
        }
    }

    func testTranslationChatRequestBodyUsesCerebrasDefaultsAndReasoningEffort() {
        let body = TranslationChatRequestPolicy.requestBody(
            provider: "cerebras",
            modelID: " ",
            reasoningEffort: "",
            messages: [["role": "user", "content": "Translate this."]]
        )

        XCTAssertEqual(body["model"] as? String, "gpt-oss-120b")
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        assertNoDeepSeekJSONOutputFields(in: body)
    }

    func testTranslationChatRequestBodyUsesCerebrasCustomModelAndSupportedReasoningEffort() {
        let body = TranslationChatRequestPolicy.requestBody(
            provider: "cerebras",
            modelID: "gpt-oss-20b",
            reasoningEffort: "high",
            messages: []
        )

        XCTAssertEqual(body["model"] as? String, "gpt-oss-20b")
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        assertNoDeepSeekJSONOutputFields(in: body)
    }

    func testTranslationChatRequestBodyDefaultsUnsupportedCerebrasReasoningEffort() {
        let body = TranslationChatRequestPolicy.requestBody(
            provider: "cerebras",
            modelID: "gpt-oss-120b",
            reasoningEffort: "max",
            messages: []
        )

        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        assertNoDeepSeekJSONOutputFields(in: body)
    }

    func testTranslationChatRequestBodyKeepsDashScopeDefaultsWithoutReasoningEffort() {
        let body = TranslationChatRequestPolicy.requestBody(
            provider: "dashscope",
            modelID: "deepseek-v4-pro",
            reasoningEffort: "max",
            messages: []
        )

        XCTAssertEqual(body["model"] as? String, "qwen-turbo")
        XCTAssertNil(body["reasoning_effort"])
        assertNoDeepSeekJSONOutputFields(in: body)
    }

    func testTranslationProviderDefaultsReplaceEmptyOrKnownValuesWhenSwitchingToCerebras() {
        let empty = TranslationProviderPolicy.defaultsForProviderSwitch(
            toProvider: "cerebras",
            currentBaseURL: "",
            currentModelID: "",
            currentReasoningEffort: ""
        )

        XCTAssertEqual(empty.baseURL, "https://api.cerebras.ai/v1")
        XCTAssertEqual(empty.modelID, "gpt-oss-120b")
        XCTAssertEqual(empty.reasoningEffort, "medium")

        let knownDeepSeek = TranslationProviderPolicy.defaultsForProviderSwitch(
            toProvider: "cerebras",
            currentBaseURL: "https://api.deepseek.com",
            currentModelID: "deepseek-v4-flash",
            currentReasoningEffort: "high"
        )

        XCTAssertEqual(knownDeepSeek.baseURL, "https://api.cerebras.ai/v1")
        XCTAssertEqual(knownDeepSeek.modelID, "gpt-oss-120b")
        XCTAssertEqual(knownDeepSeek.reasoningEffort, "medium")
    }

    func testTranslationProviderDefaultsPreserveCustomValuesWhenSwitchingToCerebras() {
        let defaults = TranslationProviderPolicy.defaultsForProviderSwitch(
            toProvider: "cerebras",
            currentBaseURL: "https://proxy.example.com/v1",
            currentModelID: "custom-model",
            currentReasoningEffort: "low"
        )

        XCTAssertEqual(defaults.baseURL, "https://proxy.example.com/v1")
        XCTAssertEqual(defaults.modelID, "custom-model")
        XCTAssertEqual(defaults.reasoningEffort, "low")
    }

    func testTranslationBlockContextInjectsThreeBeforeAndTwoAfter() {
        let segments = (1...10).map {
            LearningSegment(sequence: $0, startMS: $0 * 1_000, endMS: $0 * 1_000 + 500, text: "segment \($0)")
        }

        let context = TranslationBlockContextPolicy.context(
            allSegments: segments,
            blockSequences: [5, 6]
        )

        XCTAssertEqual(context.before, ["segment 2", "segment 3", "segment 4"])
        XCTAssertEqual(context.after, ["segment 7", "segment 8"])
    }

    func testTranslationBlockContextClampsAtTranscriptEdges() {
        let segments = (1...4).map {
            LearningSegment(sequence: $0, startMS: $0 * 1_000, endMS: $0 * 1_000 + 500, text: "segment \($0)")
        }

        let context = TranslationBlockContextPolicy.context(
            allSegments: segments,
            blockSequences: [1]
        )

        XCTAssertEqual(context.before, [])
        XCTAssertEqual(context.after, ["segment 2", "segment 3"])
    }

    func testTranslationRateLimitPolicyPacesCerebrasRequestsAtFivePerMinute() {
        XCTAssertEqual(TranslationRateLimitPolicy.minimumRequestIntervalSeconds(forProvider: "cerebras"), 12)
        XCTAssertEqual(TranslationRateLimitPolicy.minimumRequestIntervalSeconds(forProvider: "deepseek"), 0)
        XCTAssertEqual(TranslationRateLimitPolicy.minimumRequestIntervalSeconds(forProvider: "dashscope"), 0)
    }

    func testLocalNetworkAddressPolicySkipsLoopbackVpnVirtualAndLinkLocalAddresses() {
        let interfaces = [
            LocalNetworkInterface(name: "lo0", address: "127.0.0.1", isUp: true, isLoopback: true),
            LocalNetworkInterface(name: "utun4", address: "10.8.0.2", isUp: true, isLoopback: false),
            LocalNetworkInterface(name: "bridge100", address: "192.168.64.1", isUp: true, isLoopback: false),
            LocalNetworkInterface(name: "en0", address: "192.168.1.23", isUp: true, isLoopback: false),
            LocalNetworkInterface(name: "en1", address: "169.254.8.9", isUp: true, isLoopback: false)
        ]

        XCTAssertEqual(LocalNetworkAddressPolicy.preferredIPv4Address(from: interfaces), "192.168.1.23")
    }

    func testLocalSetupHTTPResponseUsesCRLFContentLengthAndCloseHeader() throws {
        let body = "已加载"
        let data = LocalSetupHTTPResponseBuilder.response(
            body: body,
            status: "200 OK",
            contentType: "text/plain; charset=utf-8"
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let separator = "\r\n\r\n"
        let separatorRange = try XCTUnwrap(text.range(of: separator))
        let headers = String(text[..<separatorRange.lowerBound])
        let responseBody = String(text[separatorRange.upperBound...])

        XCTAssertTrue(headers.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(headers.contains("\r\nContent-Type: text/plain; charset=utf-8\r\n"))
        XCTAssertTrue(headers.contains("\r\nContent-Length: \(Data(body.utf8).count)\r\n"))
        XCTAssertTrue(headers.contains("\r\nConnection: close"))
        for lineBreak in text.indices where text[lineBreak] == "\n" {
            XCTAssertGreaterThan(lineBreak, text.startIndex)
            XCTAssertEqual(text[text.index(before: lineBreak)], "\r")
        }
        XCTAssertEqual(responseBody, body)
        XCTAssertEqual(data.count, Data(headers.utf8).count + Data(separator.utf8).count + Data(body.utf8).count)
    }

    func testLocalSetupDismissesAfterSuccessfulSubmissionOnly() {
        XCTAssertTrue(LocalSetupDismissalPolicy.shouldDismissAfterSuccessfulSubmission(message: "设置已保存"))
        XCTAssertFalse(LocalSetupDismissalPolicy.shouldDismissAfterSuccessfulSubmission(message: ""))
        XCTAssertFalse(LocalSetupDismissalPolicy.shouldDismissAfterSuccessfulSubmission(message: "   "))
    }

    // MARK: - Completion reconciliation

    private func completionInput(
        activeTarget: TranslationTarget? = .simplifiedChinese,
        artifactTarget: TranslationTarget = .simplifiedChinese,
        manifestStatus: String? = TranslationVariantStatus.ready.rawValue,
        pipelineVersion: Int? = SubtitlePipelineVersion.current,
        segmentCount: Int = 3,
        translatedCount: Int = 3,
        manifestFingerprint: String? = "fp",
        segmentsFingerprint: String? = "fp",
        sourceFingerprint: String? = "fp"
    ) -> PodcastCompletionReconciliationPolicy.Input {
        PodcastCompletionReconciliationPolicy.Input(
            activeTarget: activeTarget,
            artifactTarget: artifactTarget,
            manifestStatus: manifestStatus,
            pipelineVersion: pipelineVersion,
            segmentCount: segmentCount,
            translatedCount: translatedCount,
            manifestFingerprint: manifestFingerprint,
            segmentsFingerprint: segmentsFingerprint,
            sourceFingerprint: sourceFingerprint
        )
    }

    func testCompletionReconciliationAcceptsFullyTranslatedCurrentTarget() {
        XCTAssertTrue(PodcastCompletionReconciliationPolicy.shouldComplete(completionInput()))
    }

    func testCompletionReconciliationAcceptsRunningManifestWhenFullyTranslated() {
        // Historical 90% stall: translate finished on disk, manifest still "running".
        XCTAssertTrue(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(manifestStatus: TranslationVariantStatus.running.rawValue)
        ))
    }

    func testCompletionReconciliationRejectsPartialTranslations() {
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(translatedCount: 2)
        ))
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(
                manifestStatus: TranslationVariantStatus.running.rawValue,
                translatedCount: 2
            )
        ))
    }

    func testCompletionReconciliationRejectsEmptySegments() {
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(segmentCount: 0, translatedCount: 0, manifestFingerprint: nil, segmentsFingerprint: nil)
        ))
    }

    func testCompletionReconciliationRejectsIncompleteManifestStatuses() {
        for status in [TranslationVariantStatus.partial, .failed, .notRequested] {
            XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
                completionInput(manifestStatus: status.rawValue)
            ), "status \(status) must not be reconciled")
        }
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(manifestStatus: nil)
        ))
    }

    func testCompletionReconciliationRejectsLegacyPipelineVersion() {
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(pipelineVersion: SubtitlePipelineVersion.current - 1)
        ))
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(pipelineVersion: nil)
        ))
    }

    func testCompletionReconciliationRejectsTargetMismatch() {
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(activeTarget: .traditionalChinese, artifactTarget: .simplifiedChinese)
        ))
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(activeTarget: nil)
        ))
    }

    func testCompletionReconciliationRejectsFingerprintMismatch() {
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(segmentsFingerprint: "different")
        ))
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(sourceFingerprint: "stale-source")
        ))
        XCTAssertFalse(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(manifestFingerprint: nil)
        ))
    }

    func testCompletionReconciliationAllowsMissingEnglishBaseWhenManifestMatchesSegments() {
        // No raw transcription on disk → fall back to manifest == segments fingerprint only.
        XCTAssertTrue(PodcastCompletionReconciliationPolicy.shouldComplete(
            completionInput(sourceFingerprint: nil)
        ))
    }

    // MARK: - Orphaned pipeline resume

    func testOrphanedPipelinePolicyResumesRunningWithoutInMemoryTask() {
        XCTAssertTrue(PodcastOrphanedPipelinePolicy.shouldResume(status: "running", hasInMemoryTask: false))
    }

    func testOrphanedPipelinePolicySkipsActiveTaskAndNonRunningStatuses() {
        XCTAssertFalse(PodcastOrphanedPipelinePolicy.shouldResume(status: "running", hasInMemoryTask: true))
        for status in ["queued", "failed", "completed", ""] {
            XCTAssertFalse(
                PodcastOrphanedPipelinePolicy.shouldResume(status: status, hasInMemoryTask: false),
                "status \(status) must not auto-resume"
            )
            XCTAssertFalse(
                PodcastOrphanedPipelinePolicy.shouldResume(status: status, hasInMemoryTask: true),
                "status \(status) must not auto-resume with a live task"
            )
        }
    }

    func testPartialLocalPodcastTranslationResumesWithoutCloudCheck() {
        XCTAssertTrue(
            PodcastTranslationAutoResumePolicy.shouldBypassCloudCheck(
                hasLocalSource: true,
                translatedCount: 170,
                totalCount: 2_084
            )
        )
        XCTAssertTrue(
            PodcastTranslationAutoResumePolicy.shouldBypassCloudCheck(
                hasLocalSource: true,
                translatedCount: 0,
                totalCount: 2_084
            )
        )
        XCTAssertFalse(
            PodcastTranslationAutoResumePolicy.shouldBypassCloudCheck(
                hasLocalSource: false,
                translatedCount: 0,
                totalCount: 0
            )
        )
        XCTAssertFalse(
            PodcastTranslationAutoResumePolicy.shouldBypassCloudCheck(
                hasLocalSource: true,
                translatedCount: 2_084,
                totalCount: 2_084
            )
        )
    }

    func testClearAndRegeneratePolicyOffersForRunningFailedCompletedOnly() {
        XCTAssertTrue(PodcastClearAndRegeneratePolicy.isAvailable(status: "running"))
        XCTAssertTrue(PodcastClearAndRegeneratePolicy.isAvailable(status: "failed"))
        XCTAssertTrue(PodcastClearAndRegeneratePolicy.isAvailable(status: "completed"))
        XCTAssertFalse(PodcastClearAndRegeneratePolicy.isAvailable(status: "queued"))
        XCTAssertFalse(PodcastClearAndRegeneratePolicy.isAvailable(status: ""))
    }

    private func assertDeepSeekJSONOutputFields(
        in body: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let responseFormat = body["response_format"] as? [String: Any]
        XCTAssertEqual(responseFormat?["type"] as? String, "json_object", file: file, line: line)
        XCTAssertEqual(
            body["max_tokens"] as? Int,
            TranslationChatRequestPolicy.deepSeekJSONOutputMaxTokens,
            file: file,
            line: line
        )
    }

    private func assertNoDeepSeekJSONOutputFields(
        in body: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(body["response_format"], file: file, line: line)
        XCTAssertNil(body["max_tokens"], file: file, line: line)
    }
}
