import CoreML
import CryptoKit
import Foundation
import KokoroPipeline

/// Single-threaded model provider for the isolated validation engine.
public final class CachedModelProvider: KokoroModelProvider {
    private let root: URL
    private let cache: URL
    private let buckets: [Int]
    private let durationUnits: MLComputeUnits
    private var loaded: [String: MLModel] = [:]
    private var activeBucket: Int?
    public private(set) var loads: [[String: Any]] = []

    public init(root: URL, cache: URL, buckets: [Int], durationUnits: MLComputeUnits) throws {
        self.root = root; self.cache = cache; self.buckets = buckets.sorted(); self.durationUnits = durationUnits
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for bucket in buckets {
            guard let frames = PipelineConstants.tFramesForBucket[bucket] else { throw SpeechPlanningError.invalidBuckets }
            for name in ["kokoro_f0ntrain_t\(frames)", "kokoro_decoder_pre_\(bucket)s", "kokoro_decoder_har_post_\(bucket)s"] {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".mlpackage/Manifest.json").path) else {
                    throw PipelineError.modelNotLoaded(name)
                }
            }
        }
        guard !durationModelChoices().isEmpty else { throw PipelineError.modelNotLoaded("duration") }
    }
    public func durationModelChoices() -> [DurationModelChoice] {
        KokoroPipeline.discoverDurationChoices(modelsDirectory: root, maxDurationTokenLength: 128)
    }
    public func availableBucketSeconds() -> [Int] { buckets }
    public func prepareForBucket(bucketSec: Int, tFrames: Int) throws {
        guard buckets.contains(bucketSec), PipelineConstants.tFramesForBucket[bucketSec] == tFrames else {
            throw SpeechPlanningError.invalidBuckets
        }
        if activeBucket != bucketSec {
            // Keep duration resident, but do not retain multiple large vocoder graphs on a phone.
            loaded = loaded.filter { $0.key.hasPrefix("kokoro_duration_") }
            activeBucket = bucketSec
        }
    }
    public func durationModel(choice: DurationModelChoice) throws -> MLModel {
        try load(choice.packageURL, units: durationUnits)
    }
    public func f0ntrainModel(tFrames: Int) throws -> MLModel {
        try load(root.appendingPathComponent("kokoro_f0ntrain_t\(tFrames).mlpackage"), units: .cpuAndGPU)
    }
    public func decoderPreModel(bucketSec: Int) throws -> MLModel {
        try load(root.appendingPathComponent("kokoro_decoder_pre_\(bucketSec)s.mlpackage"), units: .cpuAndNeuralEngine)
    }
    public func generatorModel(bucketSec: Int) throws -> MLModel {
        try load(root.appendingPathComponent("kokoro_decoder_har_post_\(bucketSec)s.mlpackage"), units: .cpuAndGPU)
    }
    private func load(_ source: URL, units: MLComputeUnits) throws -> MLModel {
        let identity = source.lastPathComponent + "-\(units.rawValue)"
        if let model = loaded[identity] { return model }
        let start = ProcessInfo.processInfo.systemUptime
        let digest = try Self.fingerprint(source)
        let compiled = cache.appendingPathComponent(digest + ".mlmodelc", isDirectory: true)
        let initiallyPresent = FileManager.default.fileExists(atPath: compiled.path)
        var reused = initiallyPresent
        var rebuiltCorruptCache = false
        func compile() throws {
            let temporary = try MLModel.compileModel(at: source)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let staging = cache.appendingPathComponent(UUID().uuidString + ".mlmodelc")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: temporary, to: staging)
            try FileManager.default.moveItem(at: staging, to: compiled)
        }
        if !reused { try compile() }
        let config = MLModelConfiguration()
        config.computeUnits = units
        let model: MLModel
        do { model = try MLModel(contentsOf: compiled, configuration: config) }
        catch {
            guard reused else { throw error }
            reused = false
            rebuiltCorruptCache = true
            try FileManager.default.removeItem(at: compiled)
            try compile()
            model = try MLModel(contentsOf: compiled, configuration: config)
        }
        loaded[identity] = model
        loads.append(["model": source.lastPathComponent, "computeUnits": units.rawValue,
            "reusedCompiledArtifact": reused, "cacheInitiallyPresent": initiallyPresent, "rebuiltCorruptCache": rebuiltCorruptCache, "seconds": ProcessInfo.processInfo.systemUptime - start, "fingerprint": digest])
        return model
    }
    /// Hashes contents and relative names so changed resources or OS builds cannot reuse stale artifacts.
    public static func fingerprint(_ directory: URL) throws -> String {
        let fm = FileManager.default
        guard let iterator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw PipelineError.modelNotLoaded(directory.lastPathComponent)
        }
        let paths = try iterator.compactMap { $0 as? URL }.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted { $0.path < $1.path }
        guard !paths.isEmpty else { throw PipelineError.modelNotLoaded(directory.lastPathComponent) }
        var hasher = SHA256()
        hasher.update(data: Data(("v16-compiled-1\0" + ProcessInfo.processInfo.operatingSystemVersionString).utf8))
        for path in paths {
            hasher.update(data: Data((String(path.path.dropFirst(directory.path.count)) + "\0").utf8))
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
