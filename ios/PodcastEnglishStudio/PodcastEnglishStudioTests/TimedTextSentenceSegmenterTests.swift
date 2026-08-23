import XCTest
@testable import PodcastEnglishStudioCore

final class TimedTextSentenceSegmenterTests: XCTestCase {
    private let profile = TimedTextSegmentationProfile.podcast

    private func word(_ text: String, _ start: Int, _ end: Int, punctuation: String? = nil) -> TranscriptWord {
        TranscriptWord(text: text, startMS: start, endMS: end, punctuation: punctuation)
    }

    // MARK: - Profile

    func testPodcastProfileMatchesPlanDefaults() {
        XCTAssertEqual(profile.softPauseMS, 250)
        XCTAssertEqual(profile.strongPauseMS, 700)
        XCTAssertEqual(profile.targetDurationMS, 4_000)
        XCTAssertEqual(profile.maxDurationMS, 7_000)
        XCTAssertEqual(profile.targetWeightedLength, 60)
        XCTAssertEqual(profile.maxWeightedLength, 75)
        XCTAssertEqual(profile.minimumWordCount, 2)
    }

    // MARK: - Punctuation boundaries

    func testSplitsOnSentenceEndingPunctuation() {
        let words = [
            word("Hello", 0, 300, punctuation: "."),
            word("How", 400, 600),
            word("are", 620, 800),
            word("you", 820, 1000, punctuation: "?")
        ]

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertEqual(segments.map(\.text), ["Hello.", "How are you?"])
        XCTAssertEqual(segments[0].words.map(\.text), ["Hello"])
        XCTAssertEqual(segments[1].words.map(\.text), ["How", "are", "you"])
    }

    func testSplitsOnClausePunctuationWhenPackingLongRun() {
        // A long run that exceeds the hard max, with a comma as the natural cut.
        var words: [TranscriptWord] = []
        var cursor = 0
        let tokens = [
            ("We", nil), ("discussed", nil), ("several", nil), ("important", nil),
            ("topics", ","), ("including", nil), ("budget", nil), ("planning", nil),
            ("timeline", nil), ("risks", nil), ("and", nil), ("staffing", nil),
            ("changes", nil), ("across", nil), ("teams", nil), ("worldwide", ".")
        ]
        for (text, punct) in tokens {
            words.append(word(text, cursor, cursor + 500, punctuation: punct))
            cursor += 520 // ~8.3s total → over 7s max
        }

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.contains { $0.text.hasSuffix(",") || $0.text.contains("topics,") })
        assertWordPreservation(original: words, segments: segments)
    }

    // MARK: - Pause boundaries

    func testSplitsOnStrongPause700ms() {
        let words = [
            word("First", 0, 400),
            word("part", 420, 800),
            // 800ms gap ≥ strong pause
            word("Second", 1600, 2000),
            word("part", 2020, 2400)
        ]

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First part")
        XCTAssertEqual(segments[1].text, "Second part")
        XCTAssertEqual(segments[1].startMS, 1600)
    }

    func testSoftPause250msPreferredOverZeroGapWhenForced() {
        // Over max duration; only soft pause is a natural boundary.
        var words: [TranscriptWord] = []
        var cursor = 0
        for index in 0..<8 {
            words.append(word("alpha\(index)", cursor, cursor + 900))
            cursor += 920
        }
        // Insert a 300ms soft pause in the middle.
        let mid = 4
        let pauseBoost = 300
        for index in mid..<words.count {
            words[index].startMS += pauseBoost
            words[index].endMS += pauseBoost
        }

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertGreaterThan(segments.count, 1)
        // Cut should land at the soft-pause boundary (before word 4).
        XCTAssertEqual(segments[0].words.count, mid)
        assertWordPreservation(original: words, segments: segments)
    }

    // MARK: - Caps & force split

    func testForceSplitsWhenExceedingMaxDuration() {
        var words: [TranscriptWord] = []
        var cursor = 0
        for index in 0..<20 {
            words.append(word("word\(index)", cursor, cursor + 400))
            cursor += 420 // ~8.4s
        }

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments where segment.words.count > 1 {
            XCTAssertLessThanOrEqual(segment.endMS - segment.startMS, profile.maxDurationMS)
        }
        assertWordPreservation(original: words, segments: segments)
    }

    func testForceSplitsWhenExceedingMaxWeightedLength() {
        // Short timings but very long tokens → weighted length over 75.
        let words = (0..<12).map { index in
            word(String(repeating: "x", count: 10) + "\(index)", index * 50, index * 50 + 40)
        }

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments where segment.words.count > 1 {
            XCTAssertLessThanOrEqual(
                SubtitleWeightedLength.calculate(segment.text),
                profile.maxWeightedLength
            )
        }
        assertWordPreservation(original: words, segments: segments)
    }

    func testSingleOversizedWordIsKeptUnsplittable() {
        let words = [word(String(repeating: "supercalifragilistic", count: 6), 0, 500)]

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].words.count, 1)
        XCTAssertGreaterThan(SubtitleWeightedLength.calculate(segments[0].text), profile.maxWeightedLength)
    }

    // MARK: - Anomalous timings

    func testContinuousZeroPauseInputStillSegments() {
        let words = (0..<16).map { index in
            word("token\(index)", index * 500, (index + 1) * 500)
        }

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertGreaterThan(segments.count, 1)
        assertMonotonic(segments)
        assertWordPreservation(original: words, segments: segments)
    }

    func testOverlappingTimestampsTreatGapAsZero() {
        let words = [
            word("One", 0, 1000),
            word("two", 800, 1600),   // overlaps previous
            word("three", 1500, 2200),
            word("four", 2100, 3000),
            word("five", 2900, 4000),
            word("six", 3900, 5000),
            word("seven", 4900, 6000),
            word("eight", 5900, 7500),
            word("nine", 7400, 8500),
            word("ten", 8400, 9500)
        ]

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertFalse(segments.isEmpty)
        assertWordPreservation(original: words, segments: segments)
        assertMonotonic(segments)
    }

    func testEmptyWordStreamReturnsEmpty() {
        XCTAssertTrue(TimedTextSentenceSegmenter.segments(from: [], profile: profile).isEmpty)
        XCTAssertNil(TimedTextSentenceSegmenter.bestBinarySplit([], profile: profile))
    }

    // MARK: - Determinism & function words

    func testDeterministicTieBreakIsStable() {
        let words = (0..<10).map { index in
            word("even\(index)", index * 800, index * 800 + 700)
        }

        let first = TimedTextSentenceSegmenter.segments(from: words, profile: profile)
        let second = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        XCTAssertEqual(first.map(\.text), second.map(\.text))
        XCTAssertEqual(first.map(\.startMS), second.map(\.startMS))
    }

    func testAvoidsBreakingAfterEnglishFunctionWordsWhenPossible() {
        // Force a split; prefer cutting after "changes" rather than after "the"/"of".
        var words: [TranscriptWord] = []
        var cursor = 0
        let tokens = [
            "Discussing", "major", "organizational", "changes",
            "the", "board", "approved", "yesterday",
            "after", "careful", "review", "process",
            "completed", "last", "quarter", "finally"
        ]
        for text in tokens {
            words.append(word(text, cursor, cursor + 500))
            cursor += 520
        }

        let cut = TimedTextSentenceSegmenter.bestBinarySplit(words, profile: profile)

        XCTAssertNotNil(cut)
        if let cut {
            let leftLast = words[cut - 1].text.lowercased()
            XCTAssertFalse(["the", "of", "a", "an", "and", "or", "to", "for"].contains(leftLast))
        }
    }

    // MARK: - bestBinarySplit

    func testBestBinarySplitPrefersSentenceEnd() {
        let words = [
            word("Hello", 0, 400, punctuation: "."),
            word("Friends", 500, 900),
            word("gather", 920, 1300),
            word("here", 1320, 1700)
        ]

        let cut = TimedTextSentenceSegmenter.bestBinarySplit(words, profile: profile)

        XCTAssertEqual(cut, 1)
    }

    func testBestBinarySplitPrefersStrongPause() {
        let words = [
            word("Left", 0, 400),
            word("side", 420, 800),
            // 900ms strong pause
            word("Right", 1700, 2100),
            word("side", 2120, 2500)
        ]

        let cut = TimedTextSentenceSegmenter.bestBinarySplit(words, profile: profile)

        XCTAssertEqual(cut, 2)
    }

    func testBestBinarySplitReturnsNilForSingleWord() {
        XCTAssertNil(TimedTextSentenceSegmenter.bestBinarySplit([word("Only", 0, 300)], profile: profile))
    }

    // MARK: - Metadata / timeline / PlaybackSentence contract helpers

    func testPreservesAllWordsOnceWithMonotonicTimeline() {
        var words: [TranscriptWord] = []
        var cursor = 0
        for index in 0..<24 {
            let punct: String? = index == 7 || index == 15 ? "." : nil
            words.append(word("w\(index)", cursor, cursor + 280, punctuation: punct))
            cursor += index == 7 ? 900 : 300
        }

        let segments = TimedTextSentenceSegmenter.segments(from: words, profile: profile)

        assertWordPreservation(original: words, segments: segments)
        assertMonotonic(segments)
        XCTAssertEqual(segments.first?.startMS, words.first?.startMS)
        XCTAssertEqual(segments.last?.endMS, words.last?.endMS)
        for segment in segments {
            XCTAssertEqual(segment.timingSource, .wordTimeline)
            XCTAssertFalse(segment.text.isEmpty)
            XCTAssertEqual(segment.learningText, segment.text)
        }
    }

    func testBinarySplitPiecesShareOriginalPlaybackSentenceRange() throws {
        let words = [
            word("This", 100, 300),
            word("long", 320, 500),
            word("sentence", 520, 900),
            word("continues", 920, 1300),
            word("further", 1320, 1700, punctuation: ".")
        ]
        let cut = try XCTUnwrap(TimedTextSentenceSegmenter.bestBinarySplit(words, profile: profile))
        let left = Array(words[..<cut])
        let right = Array(words[cut...])
        let leftSeg = LearningSegment(
            sequence: 1,
            startMS: left.first!.startMS,
            endMS: left.last!.endMS,
            text: TimedTextSentenceSegmenter.renderText(left),
            words: left,
            playbackSentence: PlaybackSentence(
                id: 1,
                text: TimedTextSentenceSegmenter.renderText(words),
                translation: "整句译文",
                startMS: words.first!.startMS,
                endMS: words.last!.endMS
            ),
            timingSource: .wordTimeline
        )
        let rightSeg = LearningSegment(
            sequence: 2,
            startMS: right.first!.startMS,
            endMS: right.last!.endMS,
            text: TimedTextSentenceSegmenter.renderText(right),
            words: right,
            playbackSentence: leftSeg.playbackSentence,
            timingSource: .wordTimeline
        )

        XCTAssertEqual(leftSeg.playbackGroupID, rightSeg.playbackGroupID)
        XCTAssertEqual(leftSeg.playbackStartMS, 100)
        XCTAssertEqual(rightSeg.playbackEndMS, 1700)
        XCTAssertEqual(
            SentencePlaybackGrouping.uniquePlaybackIndices(of: [leftSeg, rightSeg]),
            [0]
        )
    }

    // MARK: - Pipeline seam (no LLM)

    func testResegmentLearningSegmentsIsPurelyLocalAndNeedsNoTranslationKey() {
        // Simulates ASR output that would previously wait on LLM [br] insertion.
        let asr = [
            LearningSegment(
                sequence: 1,
                startMS: 0,
                endMS: 2400,
                text: "Hello. How are you?",
                speaker: "host",
                words: [
                    word("Hello", 0, 300, punctuation: "."),
                    word("How", 400, 600),
                    word("are", 620, 800),
                    word("you", 820, 1000, punctuation: "?")
                ],
                timingSource: .wordTimeline
            ),
            LearningSegment(
                sequence: 2,
                startMS: 3000,
                endMS: 3500,
                text: "Legacy sentence without words",
                speaker: "guest",
                timingSource: .legacy
            )
        ]

        let resegmented = TimedTextSentenceSegmenter.resegmentLearningSegments(asr, profile: profile)

        // Local split happened for the word-bearing sentence.
        XCTAssertEqual(resegmented.count, 3)
        XCTAssertEqual(resegmented[0].text, "Hello.")
        XCTAssertEqual(resegmented[1].text, "How are you?")
        // Missing word stream keeps the original sentence (ASR parse still usable without a translation key).
        XCTAssertEqual(resegmented[2].text, "Legacy sentence without words")
        XCTAssertEqual(resegmented[2].speaker, "guest")
        // Speaker / metadata preserved on split pieces.
        XCTAssertEqual(resegmented[0].speaker, "host")
        XCTAssertEqual(resegmented[1].speaker, "host")
        XCTAssertTrue(resegmented.allSatisfy { $0.translation.isEmpty })
        XCTAssertEqual(resegmented.map(\.sequence), [1, 2, 3])
    }

    func testResegmentLearningSegmentsKeepsUnchangedInputIdentityWhenNoSplitNeeded() {
        let words = [word("Short", 0, 200), word("one", 220, 400, punctuation: ".")]
        let original = [
            LearningSegment(
                sequence: 1,
                startMS: 0,
                endMS: 400,
                text: "Short one.",
                words: words,
                timingSource: .wordTimeline
            )
        ]

        let resegmented = TimedTextSentenceSegmenter.resegmentLearningSegments(original, profile: profile)

        XCTAssertEqual(resegmented, original)
    }

    func testDisplayBinarySplitDoesNotRequireBreakMarkerAPI() {
        // Display refinement seam: English boundary is chosen locally; only translation
        // split would still call the model (covered by production Refiner, not here).
        let words = [
            word("This", 0, 300),
            word("overflowing", 320, 800),
            word("display", 820, 1200),
            word("line", 1220, 1600),
            word("continues", 1620, 2200),
            word("further", 2220, 2800, punctuation: ".")
        ]
        let cut = TimedTextSentenceSegmenter.bestBinarySplit(words, profile: profile)
        XCTAssertNotNil(cut)
        XCTAssertGreaterThan(cut!, 0)
        XCTAssertLessThan(cut!, words.count)
        let left = TimedTextSentenceSegmenter.renderText(Array(words[..<cut!]))
        let right = TimedTextSentenceSegmenter.renderText(Array(words[cut!...]))
        XCTAssertFalse(left.isEmpty)
        XCTAssertFalse(right.isEmpty)
        XCTAssertEqual(left + " " + right, TimedTextSentenceSegmenter.renderText(words))
    }

    // MARK: - Helpers

    private func assertWordPreservation(original: [TranscriptWord], segments: [LearningSegment], file: StaticString = #filePath, line: UInt = #line) {
        let rebuilt = segments.flatMap(\.words)
        XCTAssertEqual(rebuilt.map(\.text), original.map(\.text), file: file, line: line)
        XCTAssertEqual(rebuilt.map(\.startMS), original.map(\.startMS), file: file, line: line)
        XCTAssertEqual(rebuilt.map(\.endMS), original.map(\.endMS), file: file, line: line)
        XCTAssertEqual(rebuilt.map(\.punctuation), original.map(\.punctuation), file: file, line: line)
    }

    private func assertMonotonic(_ segments: [LearningSegment], file: StaticString = #filePath, line: UInt = #line) {
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.startMS, segment.endMS, file: file, line: line)
        }
        for (left, right) in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(left.endMS, right.endMS, file: file, line: line)
        }
    }
}
