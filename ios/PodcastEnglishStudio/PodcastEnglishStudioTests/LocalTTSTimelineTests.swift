import XCTest
@testable import PodcastEnglishStudioCore

final class LocalTTSTimelineTests: XCTestCase {
    func testRefinedRowsSpeakTheWholeTranslationOnlyOnce() throws {
        let sentence = PlaybackSentence(id: 7, text: "Hello world", translation: "你好，世界。", startMS: 1000, endMS: 6000)
        let rows = [
            LearningSegment(sequence: 1, startMS: 1000, endMS: 3000, text: "Hello", translation: "你好", playbackSentence: sentence),
            LearningSegment(sequence: 2, startMS: 3000, endMS: 6000, text: "world", translation: "世界", playbackSentence: sentence)
        ]
        let timeline = try TTSTranscriptSnapshot(episodeID: "episode", targetLanguage: "zh-CN", segments: rows)
        XCTAssertEqual(timeline.segments.count, 1)
        XCTAssertEqual(timeline.segments.first?.text, "你好，世界。")
        XCTAssertEqual(timeline.segment(forDisplaySequence: 2)?.id, "sentence:7")
        XCTAssertEqual(timeline.segment(atOriginalSeconds: 4)?.startMS, 1000)
    }
    func testGapsMissingTranslationAndTailDoNotInventContent() throws {
        let timeline = try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh", segments: [
            LearningSegment(sequence: 1, startMS: 1000, endMS: 3000, text: "one", translation: "一"),
            LearningSegment(sequence: 2, startMS: 5000, endMS: 6000, text: "two"),
            LearningSegment(sequence: 3, startMS: 7000, endMS: 10000, text: "three", translation: "三")
        ])
        XCTAssertEqual(timeline.missingTranslationCount, 1)
        XCTAssertEqual(timeline.segment(atOriginalSeconds: 4)?.id, "segment:2")
        XCTAssertEqual(timeline.segment(atOriginalSeconds: 4, skipMissing: true)?.id, "segment:3")
        XCTAssertEqual(timeline.segment(atOriginalSeconds: -2)?.id, "segment:1")
        XCTAssertNil(timeline.segment(atOriginalSeconds: 10))
        XCTAssertNil(timeline.segment(atOriginalSeconds: .nan))
        XCTAssertEqual(timeline.originalSeconds(segmentID: "segment:3", playedSeconds: 2, totalSeconds: nil), 7)
        XCTAssertEqual(timeline.originalSeconds(segmentID: "segment:3", playedSeconds: 2, totalSeconds: 4), 8.5)
    }

    func testExplicitSkipLandsOnTheNextTranslatedSentenceOrTheTail() throws {
        let timeline = try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh", segments: [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "one", translation: "一"),
            LearningSegment(sequence: 2, startMS: 1000, endMS: 2000, text: "two", translation: "  "),
            LearningSegment(sequence: 3, startMS: 2000, endMS: 3000, text: "three", translation: "三")
        ])
        XCTAssertEqual(timeline.nextReadableIndex(after: 0), 2)
        XCTAssertEqual(timeline.nextReadableIndex(after: -1), 0)
        XCTAssertNil(timeline.nextReadableIndex(after: 2))
        XCTAssertNil(timeline.nextReadableIndex(after: 9))
    }

    func testOnlyDeviceModelAndResourceFailuresEndChineseMode() {
        XCTAssertEqual(TTSSynthesisError.unsupportedDevice.scope, .mode)
        XCTAssertEqual(TTSSynthesisError.modelUnavailable.scope, .mode)
        XCTAssertEqual(TTSSynthesisError.incompatibleResources.scope, .mode)
        // A sentence the frontend cannot voice must not cost the user the whole mode.
        XCTAssertEqual(TTSSynthesisError.synthesisFailed.scope, .sentence)
        XCTAssertEqual(TTSSynthesisError.invalidInput.scope, .sentence)
        XCTAssertEqual(TTSSynthesisError.resourcePressure.scope, .sentence)
    }

    func testRevisionChangesWithTranslationButNotInputOrdering() throws {
        let first = LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "a", translation: "一")
        var second = LearningSegment(sequence: 2, startMS: 1000, endMS: 2000, text: "b", translation: "二")
        let original = try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh-CN", segments: [first, second])
        let reordered = try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh_cn", segments: [second, first])
        XCTAssertEqual(original.revision, reordered.revision)
        second.translation = "两"
        let updated = try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh-CN", segments: [first, second])
        XCTAssertNotEqual(original.revision, updated.revision)
    }

    func testRejectsAmbiguousRangesAndNonChineseTranslation() {
        let first = LearningSegment(sequence: 1, startMS: 0, endMS: 2000, text: "a")
        let overlap = LearningSegment(sequence: 2, startMS: 1000, endMS: 3000, text: "b")
        XCTAssertThrowsError(try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh", segments: [first, overlap]))
        XCTAssertThrowsError(try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh", segments: [first, first]))
        XCTAssertThrowsError(try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "en", segments: [first]))
    }

    func testRenderedTimelineStopsAtMissingTechnicalFragment() throws {
        let snapshot = try TTSTranscriptSnapshot(episodeID: "rendered", targetLanguage: "zh", segments: [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "a", translation: "甲"),
            LearningSegment(sequence: 2, startMS: 2000, endMS: 3000, text: "b", translation: "乙")
        ])
        func fragment(_ segment: Int, _ index: Int, _ count: Int, _ version: String = "natural-v1") -> TTSRenderedFragment {
            TTSRenderedFragment(segment: snapshot.segments[segment], fragmentIndex: index, fragmentCount: count,
                sampleCount: 48000, rhythmVersion: version, audioURL: URL(fileURLWithPath: "/tmp/test.caf"))
        }
        let incomplete = [fragment(0, 0, 2), fragment(1, 0, 1)]
        XCTAssertEqual(TTSRenderedTimeline.continuousPrefix(snapshot: snapshot, fragments: incomplete, version: "natural-v1").count, 1)
        let complete = incomplete + [fragment(0, 1, 2)]
        let prefix = TTSRenderedTimeline.continuousPrefix(snapshot: snapshot, fragments: complete, version: "natural-v1")
        XCTAssertEqual(prefix.map { $0.1 }, [0, 2, 4])
        XCTAssertTrue(TTSRenderedTimeline.continuousPrefix(snapshot: snapshot, fragments: complete, version: "current-v1").isEmpty)
    }

    func testCacheIdentityIncludesRhythmAndNextBoundary() throws {
        let resources = TTSResourceIdentity(model: "m", vocabulary: "v", frontend: "f", voice: "voice")
        func key(_ version: String, _ boundary: String) throws -> String {
            try TTSAudioCacheKey(episodeID: "e", transcriptRevision: "r", segmentID: "s", fragmentIndex: 0,
                text: "甲", resources: resources, rhythmVersion: version, boundaryIdentity: boundary).digest()
        }
        XCTAssertNotEqual(try key("current-v1", "sentence"), try key("natural-v1", "sentence"))
        XCTAssertNotEqual(try key("natural-v1", "sentence"), try key("natural-v1", "speaker"))
        XCTAssertNotEqual(try key("natural-v1", "sentence"), try key("natural-v1", "end"))
    }

}
