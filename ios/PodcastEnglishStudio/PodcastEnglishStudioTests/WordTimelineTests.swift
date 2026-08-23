import XCTest
@testable import PodcastEnglishStudioCore

// MARK: - WordTimelineSentenceAligner

final class WordTimelineSentenceAlignerTests: XCTestCase {
    private func word(_ text: String, _ start: Int, _ end: Int, punctuation: String? = nil) -> TranscriptWord {
        TranscriptWord(text: text, startMS: start, endMS: end, punctuation: punctuation)
    }

    func testAlignsSentencesToWordStream() throws {
        let words = [
            word("Hello", 0, 400, punctuation: ","),
            word("world", 400, 900, punctuation: "."),
            word("How", 1200, 1500),
            word("are", 1500, 1800),
            word("you", 1800, 2200, punctuation: "?")
        ]
        let sentences = [
            WordTimelineSentenceAligner.SentenceInput(text: "Hello, world.", startMS: 0, endMS: 0),
            WordTimelineSentenceAligner.SentenceInput(text: "How are you?", startMS: 0, endMS: 0)
        ]

        let aligned = try WordTimelineSentenceAligner.align(sentences: sentences, to: words)

        XCTAssertEqual(aligned.count, 2)
        XCTAssertEqual(aligned[0].startMS, 0)
        XCTAssertEqual(aligned[0].endMS, 900)
        XCTAssertEqual(aligned[0].words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(aligned[0].timingSource, .wordTimeline)
        XCTAssertEqual(aligned[1].startMS, 1200)
        XCTAssertEqual(aligned[1].endMS, 2200)
        XCTAssertEqual(aligned[1].words.map(\.text), ["How", "are", "you"])
    }

    func testAlignIgnoresCaseAndPunctuationDifferences() throws {
        let words = [
            word("don't", 0, 300, punctuation: ","),
            word("STOP", 300, 700, punctuation: "!")
        ]
        let sentences = [
            WordTimelineSentenceAligner.SentenceInput(text: "Dont stop", startMS: 0, endMS: 0)
        ]

        let aligned = try WordTimelineSentenceAligner.align(sentences: sentences, to: words)

        XCTAssertEqual(aligned[0].startMS, 0)
        XCTAssertEqual(aligned[0].endMS, 700)
    }

    func testRepeatedSentencesMatchInOrder() throws {
        let words = [
            word("go", 0, 300, punctuation: "."),
            word("wait", 500, 800, punctuation: "."),
            word("go", 1000, 1300, punctuation: ".")
        ]
        let sentences = [
            WordTimelineSentenceAligner.SentenceInput(text: "go.", startMS: 0, endMS: 0),
            WordTimelineSentenceAligner.SentenceInput(text: "wait.", startMS: 0, endMS: 0),
            WordTimelineSentenceAligner.SentenceInput(text: "go.", startMS: 0, endMS: 0)
        ]

        let aligned = try WordTimelineSentenceAligner.align(sentences: sentences, to: words)

        XCTAssertEqual(aligned[0].startMS, 0)
        XCTAssertEqual(aligned[1].startMS, 500)
        XCTAssertEqual(aligned[2].startMS, 1000)
        // Monotonic, non-overlapping.
        XCTAssertTrue(zip(aligned, aligned.dropFirst()).allSatisfy { $0.endMS <= $1.startMS })
    }

    func testAbbreviationsAndContractionsNormalize() throws {
        let words = [
            word("U.S.A.", 0, 500),
            word("is", 500, 700),
            word("big", 700, 1000, punctuation: ".")
        ]
        let sentences = [
            WordTimelineSentenceAligner.SentenceInput(text: "USA is big.", startMS: 0, endMS: 0)
        ]

        let aligned = try WordTimelineSentenceAligner.align(sentences: sentences, to: words)

        XCTAssertEqual(aligned[0].startMS, 0)
        XCTAssertEqual(aligned[0].endMS, 1000)
    }

    func testMismatchThrowsInsteadOfGuessing() {
        let words = [word("alpha", 0, 300), word("beta", 300, 600)]
        let sentences = [
            WordTimelineSentenceAligner.SentenceInput(text: "completely different sentence", startMS: 0, endMS: 0)
        ]

        XCTAssertThrowsError(try WordTimelineSentenceAligner.align(sentences: sentences, to: words)) { error in
            guard case WordTimelineAlignmentError.sentenceMismatch = error else {
                return XCTFail("Expected sentenceMismatch, got \(error)")
            }
        }
    }

    func testEmptyWordStreamFallsBackToSentenceTimingWhenAllowed() throws {
        let sentences = [
            WordTimelineSentenceAligner.SentenceInput(text: "No words here.", startMS: 100, endMS: 900)
        ]

        let aligned = try WordTimelineSentenceAligner.align(sentences: sentences, to: [])

        XCTAssertEqual(aligned[0].startMS, 100)
        XCTAssertEqual(aligned[0].endMS, 900)
        XCTAssertEqual(aligned[0].timingSource, .legacy)
        XCTAssertTrue(aligned[0].words.isEmpty)
    }

    func testEmptyWordStreamThrowsWhenFallbackDisabled() {
        let sentences = [
            WordTimelineSentenceAligner.SentenceInput(text: "No words here.", startMS: 100, endMS: 900)
        ]

        XCTAssertThrowsError(
            try WordTimelineSentenceAligner.align(
                sentences: sentences,
                to: [],
                options: .init(allowSentenceFallbackWithoutWords: false)
            )
        ) { error in
            XCTAssertEqual(error as? WordTimelineAlignmentError, .emptyWordStream)
        }
    }

    func testAlignSegmentsPreservesTranslationAndMetadata() throws {
        let words = [word("hello", 0, 400, punctuation: "."), word("there", 400, 900)]
        let playback = PlaybackSentence(id: 1, text: "hello. there", translation: "你好", startMS: 0, endMS: 900)
        let segment = LearningSegment(
            sequence: 5,
            startMS: 0,
            endMS: 1,
            text: "hello. there",
            translation: "你好",
            speaker: "spk1",
            notes: "note",
            playbackSentence: playback
        )

        let aligned = try WordTimelineSentenceAligner.align(segments: [segment], to: words)

        XCTAssertEqual(aligned[0].sequence, 5)
        XCTAssertEqual(aligned[0].translation, "你好")
        XCTAssertEqual(aligned[0].speaker, "spk1")
        XCTAssertEqual(aligned[0].notes, "note")
        XCTAssertEqual(aligned[0].playbackSentence, playback)
        XCTAssertEqual(aligned[0].endMS, 900)
        XCTAssertEqual(aligned[0].words.map(\.text), ["hello", "there"])
    }
}

// MARK: - SubtitleWeightedLength

final class SubtitleWeightedLengthTests: XCTestCase {
    func testLatinIsUnitWeight() {
        XCTAssertEqual(SubtitleWeightedLength.calculate("Hello"), 5.0, accuracy: 0.0001)
    }

    func testCJKIdeographsAre175() {
        XCTAssertEqual(SubtitleWeightedLength.calculate("你好"), 3.5, accuracy: 0.0001)
    }

    func testKanaAndFullWidthPunctuationAre175() {
        XCTAssertEqual(SubtitleWeightedLength.calculate("こんにちは。"), 6 * 1.75, accuracy: 0.0001)
        XCTAssertEqual(SubtitleWeightedLength.calculate("，"), 1.75, accuracy: 0.0001)
    }

    func testHangulIs15() {
        XCTAssertEqual(SubtitleWeightedLength.calculate("한글"), 3.0, accuracy: 0.0001)
    }

    func testThaiIsUnitWeight() {
        XCTAssertEqual(SubtitleWeightedLength.calculate("สวัสดี"), 6.0, accuracy: 0.0001)
    }

    func testMixedTextSumsPerGlyph() {
        // "Hi你好한" => 2*1 + 2*1.75 + 1*1.5 = 2 + 3.5 + 1.5 = 7
        XCTAssertEqual(SubtitleWeightedLength.calculate("Hi你好한"), 7.0, accuracy: 0.0001)
    }
}

// MARK: - SubtitleDisplaySplitPolicy

final class SubtitleDisplaySplitPolicyTests: XCTestCase {
    func testLongSourceTriggersSplit() {
        let longSource = String(repeating: "a", count: 76)
        XCTAssertTrue(SubtitleDisplaySplitPolicy.requiresDisplaySplit(source: longSource, translation: "短"))
    }

    func testHeavyTranslationTriggersSplit() {
        // 40 CJK glyphs = 70 weighted; 70 * 1.2 = 84 > 75 → split.
        let heavy = String(repeating: "你", count: 40)
        XCTAssertEqual(SubtitleWeightedLength.calculate(heavy), 70, accuracy: 0.001)
        XCTAssertTrue(SubtitleDisplaySplitPolicy.requiresDisplaySplit(source: "short", translation: heavy))
    }

    func testShortPairDoesNotSplit() {
        XCTAssertFalse(SubtitleDisplaySplitPolicy.requiresDisplaySplit(source: "Hello there.", translation: "你好"))
    }
}

// MARK: - Display refinement planner / checkpoint resume

final class DisplayRefinementPlannerTests: XCTestCase {
    private func word(_ text: String, start: Int, end: Int) -> TranscriptWord {
        TranscriptWord(text: text, startMS: start, endMS: end)
    }

    private func longCandidate(sequence: Int) -> LearningSegment {
        let source = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)
        let words = source.split(separator: " ").enumerated().map { index, token in
            word(String(token), start: index * 100, end: index * 100 + 90)
        }
        return LearningSegment(
            sequence: sequence,
            startMS: 0,
            endMS: words.last?.endMS ?? 1000,
            text: source,
            translation: String(repeating: "译", count: 40),
            words: words
        )
    }

    func testNeedsRefinementOnlyWhenCandidatesExist() {
        let short = LearningSegment(
            sequence: 1,
            startMS: 0,
            endMS: 500,
            text: "Hello.",
            translation: "你好。"
        )
        XCTAssertFalse(DisplayRefinementPlanner.needsRefinement([short]))
        XCTAssertTrue(DisplayRefinementPlanner.needsRefinement([longCandidate(sequence: 1)]))
    }

    func testCandidateRequiresWordStream() {
        var long = longCandidate(sequence: 1)
        long.words = []
        XCTAssertFalse(SubtitleDisplaySplitPolicy.isRefinementCandidate(long))
        XCTAssertTrue(DisplayRefinementPlanner.candidateIndices(in: [long]).isEmpty)
    }

    func testAssemblePreservesOrderAndResequences() {
        let original = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 100, text: "One", translation: "一"),
            longCandidate(sequence: 2),
            LearningSegment(sequence: 3, startMS: 3000, endMS: 3100, text: "Three", translation: "三")
        ]
        let refined = [
            LearningSegment(
                sequence: 2,
                startMS: 0,
                endMS: 500,
                text: "First half of a long display clause.",
                translation: "前半",
                playbackSentence: PlaybackSentence(
                    id: 2,
                    text: original[1].text,
                    translation: original[1].translation,
                    startMS: original[1].startMS,
                    endMS: original[1].endMS
                )
            ),
            LearningSegment(
                sequence: 2,
                startMS: 500,
                endMS: 1000,
                text: "Second half of a long display clause.",
                translation: "后半",
                playbackSentence: PlaybackSentence(
                    id: 2,
                    text: original[1].text,
                    translation: original[1].translation,
                    startMS: original[1].startMS,
                    endMS: original[1].endMS
                )
            )
        ]
        let assembled = DisplayRefinementPlanner.assemble(
            original: original,
            refinedBySequence: [2: refined]
        )
        XCTAssertEqual(assembled.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(assembled.map(\.text), [
            "One",
            "First half of a long display clause.",
            "Second half of a long display clause.",
            "Three"
        ])
        XCTAssertEqual(assembled[1].playbackGroupID, 2)
        XCTAssertEqual(assembled[2].playbackGroupID, 2)
    }

    func testPendingCandidatesSkipCheckpointedSequences() {
        let segments = [
            longCandidate(sequence: 1),
            longCandidate(sequence: 2),
            longCandidate(sequence: 3)
        ]
        let fingerprint = TranscriptionFingerprint.make(segments: segments)
        let checkpoint = DisplayRefinementCheckpoint(
            sourceFingerprint: fingerprint,
            entries: [
                DisplayRefinementCheckpointEntry(originalSequence: 2, segments: [segments[1]])
            ]
        )
        XCTAssertEqual(
            DisplayRefinementPlanner.pendingCandidateSequences(in: segments, checkpoint: checkpoint),
            [1, 3]
        )
    }

    func testManifestPolicyTreatsMissingStatusAsCompleted() {
        XCTAssertEqual(DisplayRefinementManifestPolicy.effectiveStatus(from: nil), .completed)
        XCTAssertFalse(DisplayRefinementManifestPolicy.needsResume(.completed))
        XCTAssertTrue(DisplayRefinementManifestPolicy.needsResume(.pending))
        XCTAssertTrue(DisplayRefinementManifestPolicy.needsResume(.running))
    }
}

// MARK: - TranslationQualityMode / Freshness

final class TranslationQualityModeTests: XCTestCase {
    func testDefaultsToQuality() {
        XCTAssertEqual(TranslationQualityMode.normalized(nil), .quality)
        XCTAssertEqual(TranslationQualityMode.normalized(""), .quality)
        XCTAssertEqual(TranslationQualityMode.normalized("bogus"), .quality)
    }

    func testParsesModes() {
        XCTAssertEqual(TranslationQualityMode.normalized("quality"), .quality)
        XCTAssertEqual(TranslationQualityMode.normalized("FAST"), .fast)
        XCTAssertTrue(TranslationQualityMode.quality.usesReflection)
        XCTAssertFalse(TranslationQualityMode.fast.usesReflection)
    }
}

final class SubtitleArtifactFreshnessPolicyTests: XCTestCase {
    func testCurrentPipelineCompleteIsCurrent() {
        let status = SubtitleArtifactFreshnessPolicy.status(
            pipelineVersion: SubtitlePipelineVersion.current,
            isDecodable: true,
            isComplete: true
        )
        XCTAssertEqual(status, .current)
        XCTAssertFalse(SubtitleArtifactFreshnessPolicy.shouldOfferUpgrade(status))
    }

    func testLegacyCompleteIsPlayableLegacyAndOffersUpgrade() {
        let status = SubtitleArtifactFreshnessPolicy.status(
            pipelineVersion: SubtitlePipelineVersion.current - 1,
            isDecodable: true,
            isComplete: true
        )
        XCTAssertEqual(status, .playableLegacy)
        XCTAssertTrue(SubtitleArtifactFreshnessPolicy.shouldOfferUpgrade(status))
    }

    func testMissingVersionIsPlayableLegacy() {
        let status = SubtitleArtifactFreshnessPolicy.status(
            pipelineVersion: nil,
            isDecodable: true,
            isComplete: true
        )
        XCTAssertEqual(status, .playableLegacy)
    }

    func testUndecodableIsIncompatible() {
        let status = SubtitleArtifactFreshnessPolicy.status(
            pipelineVersion: SubtitlePipelineVersion.current,
            isDecodable: false,
            isComplete: false
        )
        XCTAssertEqual(status, .incompatible)
        XCTAssertFalse(SubtitleArtifactFreshnessPolicy.shouldOfferUpgrade(status))
    }
}

// MARK: - Playback grouping (dual-track navigation)

final class SentencePlaybackGroupingTests: XCTestCase {
    private func subClause(sequence: Int, group: Int, start: Int, end: Int) -> LearningSegment {
        LearningSegment(
            sequence: sequence,
            startMS: start,
            endMS: end,
            text: "clause \(sequence)",
            playbackSentence: PlaybackSentence(
                id: group,
                text: "whole \(group)",
                translation: "整句 \(group)",
                startMS: start,
                endMS: end
            )
        )
    }

    func testSegmentsWithoutPlaybackSentenceUseOwnTiming() {
        let segment = LearningSegment(sequence: 3, startMS: 100, endMS: 900, text: "standalone")
        XCTAssertEqual(segment.playbackStartMS, 100)
        XCTAssertEqual(segment.playbackEndMS, 900)
        XCTAssertEqual(segment.playbackGroupID, 3)
    }

    func testDisplaySubClausesShareWholeSentenceRange() {
        let whole = PlaybackSentence(id: 7, text: "a b", translation: "甲乙", startMS: 1000, endMS: 5000)
        let first = LearningSegment(sequence: 1, startMS: 1000, endMS: 2500, text: "a", playbackSentence: whole)
        let second = LearningSegment(sequence: 2, startMS: 2500, endMS: 5000, text: "b", playbackSentence: whole)

        XCTAssertEqual(first.playbackStartMS, 1000)
        XCTAssertEqual(first.playbackEndMS, 5000)
        XCTAssertEqual(second.playbackGroupID, first.playbackGroupID)
    }

    func testUniquePlaybackIndicesDedupesSameSentence() {
        let segments = [
            subClause(sequence: 1, group: 1, start: 0, end: 1000),
            subClause(sequence: 2, group: 1, start: 1000, end: 2000),
            subClause(sequence: 3, group: 2, start: 2000, end: 3000)
        ]
        let indices = SentencePlaybackGrouping.uniquePlaybackIndices(of: segments)
        XCTAssertEqual(indices, [0, 2])
    }

    func testPlaybackRangeUsesWholeSentence() throws {
        let segments = [
            subClause(sequence: 1, group: 1, start: 500, end: 1000),
            subClause(sequence: 2, group: 1, start: 1000, end: 1500)
        ]
        // Whole-sentence range comes from playbackSentence (full span of first clause here).
        let range = try XCTUnwrap(SentencePlaybackGrouping.playbackRange(forIndex: 1, in: segments))
        XCTAssertEqual(range.lowerBound, 1.0, accuracy: 0.0001)
        XCTAssertEqual(range.upperBound, 1.5, accuracy: 0.0001)
    }
}

// MARK: - Pipeline version / envelope freshness

final class PipelineVersionAndEnvelopeTests: XCTestCase {
    func testPipelineVersionIsFour() {
        XCTAssertEqual(SubtitlePipelineVersion.current, 4)
        XCTAssertTrue(SubtitlePipelineVersion.isCurrent(4))
        XCTAssertFalse(SubtitlePipelineVersion.isCurrent(3))
        XCTAssertTrue(SubtitlePipelineVersion.isPlayableLegacy(3))
        XCTAssertTrue(SubtitlePipelineVersion.isPlayableLegacy(nil))
        XCTAssertFalse(SubtitlePipelineVersion.isPlayableLegacy(4))
    }

    func testEnvelopeRoundTripsOptionalFreshnessFields() throws {
        let identity = SubtitleArtifactIdentity.youtube(videoID: "abc", target: .simplifiedChinese)
        let segment = LearningSegment(
            sequence: 1,
            startMS: 0,
            endMS: 1000,
            text: "Hello.",
            translation: "你好。",
            playbackSentence: PlaybackSentence(id: 1, text: "Hello.", translation: "你好。", startMS: 0, endMS: 1000),
            timingSource: .wordTimeline
        )
        let profile = TranslationGenerationProfile.current(qualityMode: .quality, timingSource: .wordTimeline)
        let envelope = SubtitleArtifactEnvelope(
            identity: identity,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: [segment],
            pipelineVersion: SubtitlePipelineVersion.current,
            generationProfile: profile
        )

        let data = try envelope.encoded()
        let decoded = try SubtitleArtifactEnvelope.validated(data: data, expected: identity)

        XCTAssertEqual(decoded.pipelineVersion, SubtitlePipelineVersion.current)
        XCTAssertEqual(decoded.generationProfile, profile)
        XCTAssertEqual(decoded.segments.first?.playbackSentence?.id, 1)
        XCTAssertEqual(decoded.segments.first?.timingSource, .wordTimeline)
        XCTAssertEqual(SubtitleArtifactFreshnessPolicy.status(envelope: decoded), .current)
    }

    func testLegacyEnvelopeWithoutFreshnessFieldsDecodes() throws {
        // A v3-era payload has no pipelineVersion / generationProfile keys; it must still decode.
        let json = """
        {
          "schemaVersion": 2,
          "identity": {"contentKind":"youtubeVideo","contentKey":"key","targetLanguage":"zh-Hans"},
          "generatedAt": "2023-11-14T22:13:20Z",
          "segments": [
            {"sequence":1,"startMS":0,"endMS":1000,"text":"Hello.","learningText":"Hello.","translation":"你好。","notes":"","words":[]}
          ],
          "sourceFingerprint": "fingerprint"
        }
        """
        let identity = SubtitleArtifactIdentity(contentKind: .youtubeVideo, contentKey: "key", targetLanguage: "zh-Hans")
        let decoded = try SubtitleArtifactEnvelope.validated(data: Data(json.utf8), expected: identity)

        XCTAssertNil(decoded.pipelineVersion)
        XCTAssertNil(decoded.generationProfile)
        XCTAssertEqual(SubtitleArtifactFreshnessPolicy.status(envelope: decoded), .playableLegacy)
        XCTAssertNil(decoded.segments.first?.playbackSentence)
        XCTAssertNil(decoded.segments.first?.timingSource)
    }
}
