import XCTest
@testable import PodcastEnglishStudioCore

final class LocalTTSPersistenceTests: XCTestCase {
    func testCheckpointRefusesStaleTranscriptAndUnknownSchema() throws {
        let snapshot = try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh", segments: [
            LearningSegment(sequence: 1, startMS: 1000, endMS: 4000, text: "hello", translation: "你好")
        ])
        let point = TTSPlaybackCheckpoint(episodeID: "e", mode: .chinese, transcriptRevision: snapshot.revision,
            segmentID: "segment:1", fragmentIndex: 0, fragmentSeconds: 2)
        XCTAssertTrue(point.canRestore(in: snapshot))
        let changed = try TTSTranscriptSnapshot(episodeID: "e", targetLanguage: "zh", segments: [
            LearningSegment(sequence: 1, startMS: 1000, endMS: 4000, text: "hello", translation: "您好")
        ])
        XCTAssertFalse(point.canRestore(in: changed))
        let data = try JSONEncoder().encode(point)
        let roundTrip = try JSONDecoder().decode(TTSPlaybackCheckpoint.self, from: data)
        XCTAssertTrue(roundTrip.canRestore(in: snapshot))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        let newer = try JSONDecoder().decode(TTSPlaybackCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(newer.canRestore(in: snapshot))
    }
    func testCacheIdentitySeparatesTextVoiceAndModelVersions() throws {
        let resources = TTSResourceIdentity(model: "zh-v1", vocabulary: "v1", frontend: "v1", voice: "zf_001")
        let first = TTSAudioCacheKey(episodeID: "e", transcriptRevision: "r1", segmentID: "s1", fragmentIndex: 0,
            text: "你好", resources: resources)
        let same = TTSAudioCacheKey(episodeID: "e", transcriptRevision: "r1", segmentID: "s1", fragmentIndex: 0,
            text: "你好", resources: resources)
        let newVoice = TTSAudioCacheKey(episodeID: "e", transcriptRevision: "r1", segmentID: "s1", fragmentIndex: 0,
            text: "你好", resources: .init(model: "zh-v1", vocabulary: "v1", frontend: "v1", voice: "zf_002"))
        let newModel = TTSAudioCacheKey(episodeID: "e", transcriptRevision: "r1", segmentID: "s1", fragmentIndex: 0,
            text: "你好", resources: .init(model: "zh-v2", vocabulary: "v1", frontend: "v1", voice: "zf_001"))
        let newText = TTSAudioCacheKey(episodeID: "e", transcriptRevision: "r1", segmentID: "s1", fragmentIndex: 0,
            text: "您好", resources: resources)
        XCTAssertEqual(try first.digest(), try same.digest())
        XCTAssertNotEqual(try first.digest(), try newVoice.digest())
        XCTAssertNotEqual(try first.digest(), try newModel.digest())
        XCTAssertNotEqual(try first.digest(), try newText.digest())
        let invalid = TTSAudioCacheKey(episodeID: "e", transcriptRevision: "r1", segmentID: "s1", fragmentIndex: 0,
            text: "你好", resources: resources, synthesisSpeed: .nan)
        XCTAssertThrowsError(try invalid.digest())
    }

}
