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

    func testConfigurationReadinessRequiresYouTubeKeyAndCloudService() {
        let summary = ConfigurationReadinessPolicy.summary(
            youtubeAPIKey: "yt",
            cloudServiceReady: false
        )

        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.missingRequirements, [.cloudService])
        XCTAssertFalse(summary.isComplete)
        XCTAssertFalse(summary.hasCloudService)
        XCTAssertTrue(summary.hasYouTubeMetadataKey)

        let blankKey = ConfigurationReadinessPolicy.summary(youtubeAPIKey: "  ", cloudServiceReady: true)
        XCTAssertEqual(blankKey.missingRequirements, [.youtubeAPIKey])
        XCTAssertTrue(blankKey.hasCloudService)
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

    func testClearAndRegeneratePolicyOffersForRunningFailedCompletedOnly() {
        XCTAssertTrue(PodcastClearAndRegeneratePolicy.isAvailable(status: "running"))
        XCTAssertTrue(PodcastClearAndRegeneratePolicy.isAvailable(status: "failed"))
        XCTAssertTrue(PodcastClearAndRegeneratePolicy.isAvailable(status: "completed"))
        XCTAssertFalse(PodcastClearAndRegeneratePolicy.isAvailable(status: "queued"))
        XCTAssertFalse(PodcastClearAndRegeneratePolicy.isAvailable(status: ""))
    }
}
