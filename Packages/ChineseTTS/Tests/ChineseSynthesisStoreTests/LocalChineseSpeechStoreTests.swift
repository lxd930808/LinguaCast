import XCTest
import CryptoKit
import AVFoundation
import KokoroPipeline
@testable import ChineseSynthesis

final class LocalChineseSpeechStoreTests: XCTestCase {
    func testMissingResourcesNeverCreateAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalChineseSpeechStore(resources: root, cache: root.appendingPathComponent("cache"))
        do { _ = try await store.audio(text: "你好", key: "episode"); XCTFail("Expected missing resources") }
        catch LocalChineseSpeechError.missingResources { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testChangedResourceIsRejectedBeforeInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([2]).write(to: root.appendingPathComponent("voice.bin"))
        let hash = SHA256.hash(data: Data([1])).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["schemaVersion": 1, "identity": "fixture", "resourceFiles": [["path": "voice.bin", "sha256": hash]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("validation-identity.json"))
        let store = LocalChineseSpeechStore(resources: root, cache: root.appendingPathComponent("cache"))
        do { _ = try await store.audio(text: "你好", key: "episode"); XCTFail("Expected invalid resources") }
        catch LocalChineseSpeechError.invalidResources { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/audio").path))
    }

    func testCancellationStopsBeforeLoadingResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalChineseSpeechStore(resources: root, cache: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.audio(text: "你好", key: "episode")
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
    private func fixture() throws -> (URL, URL, LocalChineseSpeechStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("audio"), withIntermediateDirectories: true)
        let resource = Data([1])
        try resource.write(to: root.appendingPathComponent("voice.bin"))
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let manifest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "identity": "test", "resourceFiles": [["path": "voice.bin", "sha256": hash(resource)]]])
        try manifest.write(to: root.appendingPathComponent("validation-identity.json"))
        let source = Data("source-v1".utf8)
        try source.write(to: root.appendingPathComponent("synthesis-source.sha256"))
        let digest = hash(Data(("natural-v1|sentence|speed=1|" + hash(manifest + source) + "|key|你好").utf8))
        let output = cache.appendingPathComponent("audio/" + digest + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        buffer.frameLength = 2400
        for i in 0..<2400 { buffer.floatChannelData![0][i] = 0.1 }
        try AVAudioFile(forWriting: output, settings: format.settings).write(from: buffer)
        try JSONSerialization.data(withJSONObject: ["key": "key", "rhythmVersion": "natural-v1", "boundary": "sentence", "sampleCount": 2400])
            .write(to: output.appendingPathExtension("json"))
        return (root, output, LocalChineseSpeechStore(resources: root, cache: cache))
    }

    func testPreparedCacheSurvivesStoreRestartAndClearProtectsPlayback() async throws {
        let (root, output, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try await store.audio(text: "你好", key: "key", allowSynthesis: false,
            rhythm: .natural, boundary: .sentence, retainPrepared: true)
        XCTAssertTrue(audio.wasCached)
        let restarted = LocalChineseSpeechStore(resources: root, cache: root.appendingPathComponent("cache"))
        let bytes = await restarted.retainedBytes()
        XCTAssertGreaterThan(bytes, 0)
        await restarted.protect([output])
        try await restarted.clearPrepared()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        await restarted.protect([])
        try await restarted.clearPrepared()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testBoundaryMismatchAndIncompletePublicationCannotPlay() async throws {
        let (root, output, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await store.audio(text: "你好", key: "key", allowSynthesis: false, rhythm: .natural, boundary: .speaker)
            XCTFail("Different boundary must not reuse cached pause")
        } catch LocalChineseSpeechError.needsForeground { }
        try Data("{}".utf8).write(to: output.appendingPathExtension("json"))
        do {
            _ = try await store.audio(text: "你好", key: "key", allowSynthesis: false, rhythm: .natural, boundary: .sentence)
            XCTFail("Invalid index must not publish audio")
        } catch LocalChineseSpeechError.needsForeground { }
    }

}
