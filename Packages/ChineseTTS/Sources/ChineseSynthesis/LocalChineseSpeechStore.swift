import AVFoundation
import CryptoKit
import Foundation
import KokoroPipeline

public struct LocalChineseAudio: Sendable {
    public let url: URL
    public let duration: Double
    public let wasCached: Bool
}

public enum LocalChineseSpeechError: Error {
    case missingResources, invalidResources, emptyAudio, needsForeground, insufficientStorage
}

/// One actor owns all CoreML models. Only one sentence is generated at a time.
public actor LocalChineseSpeechStore {
    private let resources: URL
    private let cache: URL
    private var engine: ChineseSynthesisEngine?
    private var identity: String?
    private var plans: [String: [String]] = [:]
    private var planOrder: [String] = []
    /// Clips the player may still need. Pruning must not delete the lookahead it just produced.
    private var recentOutputs: [URL] = []
    private var protectedOutputs: Set<URL> = []
    private var retainedOutputs: Set<URL> = []
    private var loadedRetention = false
    public static let maximumAudioBytes = 256 * 1024 * 1024

    public func protect(_ urls: Set<URL>) { protectedOutputs = urls }

    private func loadRetention() {
        guard !loadedRetention else { return }
        loadedRetention = true
        if let data = try? Data(contentsOf: cache.appendingPathComponent("retained.json")),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            retainedOutputs = Set(names.filter { !$0.contains("/") }.map { cache.appendingPathComponent("audio").appendingPathComponent($0) })
        }
    }

    private func retain(_ url: URL) throws {
        loadRetention()
        var updated = retainedOutputs
        updated.insert(url)
        try JSONEncoder().encode(updated.map(\.lastPathComponent).sorted()).write(to: cache.appendingPathComponent("retained.json"), options: .atomic)
        retainedOutputs = updated
    }

    public func retainedBytes() -> Int {
        loadRetention()
        return retainedOutputs.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    public func clearPrepared() throws {
        loadRetention()
        for url in retainedOutputs where !protectedOutputs.contains(url) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
        }
        retainedOutputs.formIntersection(protectedOutputs)
        try JSONEncoder().encode(retainedOutputs.map(\.lastPathComponent)).write(to: cache.appendingPathComponent("retained.json"), options: .atomic)
    }

    private struct AudioIndex: Codable {
        let key: String
        let rhythmVersion: String
        let boundary: String
        let sampleCount: Int
    }

    public init(resources: URL, cache: URL) {
        self.resources = resources
        self.cache = cache
    }

    public func releaseModels() { engine = nil }

    public func fragments(text: String, allowSynthesis: Bool = true) throws -> [String] {
        try Task.checkCancellation()
        if let plan = plans[text] { return plan }
        let identity = try validateResources()
        let digest = SHA256.hash(data: Data((identity + "|" + text).utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = cache.appendingPathComponent("plans", isDirectory: true)
        let planURL = directory.appendingPathComponent(digest + ".json")
        if let data = try? Data(contentsOf: planURL), let saved = try? JSONDecoder().decode([String].self, from: data),
           !saved.isEmpty, saved.allSatisfy({ !$0.isEmpty }), saved.joined() == text {
            cachePlan(saved, for: text)
            return saved
        }
        guard allowSynthesis else { throw LocalChineseSpeechError.needsForeground }
        if engine == nil {
            engine = try ChineseSynthesisEngine(resources: resources,
                cache: cache.appendingPathComponent("compiled"), durationUnits: .cpuOnly)
        }
        guard let engine else { throw LocalChineseSpeechError.missingResources }
        let plan = try engine.plan(text)
        guard !plan.isEmpty, plan.map(\.source).joined() == text else { throw LocalChineseSpeechError.emptyAudio }
        let sources = plan.map(\.source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(sources).write(to: planURL, options: .atomic)
        cachePlan(sources, for: text)
        return sources
    }

    public func audio(text: String, key: String, allowSynthesis: Bool = true, rhythm: SpeechRhythm = .current, boundary: SpeechBoundary? = nil, retainPrepared: Bool = false) throws -> LocalChineseAudio {
        try Task.checkCancellation()
        let identity = try validateResources()
        let digest = SHA256.hash(data: Data((rhythm.version + "|" + (boundary?.rawValue ?? "punctuation") + "|speed=1|" + identity + "|" + key + "|" + text).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = cache.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadRetention()
        let output = directory.appendingPathComponent(digest + ".caf")
        if let result = cachedAudio(output, key: key, version: rhythm.version, boundary: boundary?.rawValue ?? "punctuation") {
            recentOutputs.removeAll { $0 == output }
            recentOutputs.append(output)
            if recentOutputs.count > 8 { recentOutputs.removeFirst(recentOutputs.count - 8) }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
            if retainPrepared { try retain(output) }
            return result
        }
        guard allowSynthesis else { throw LocalChineseSpeechError.needsForeground }
        if engine == nil {
            engine = try ChineseSynthesisEngine(resources: resources,
                cache: cache.appendingPathComponent("compiled"), durationUnits: .cpuOnly)
        }
        guard let engine else { throw LocalChineseSpeechError.missingResources }
        let plan = try engine.plan(text)
        guard !plan.isEmpty, plan.map(\.source).joined() == text else { throw LocalChineseSpeechError.emptyAudio }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        var pieces: [[Float]] = []
        for (pieceIndex, fragment) in plan.enumerated() {
            try Task.checkCancellation()
            let result = try engine.synthesize(fragment)
            try Task.checkCancellation()
            let edge = pieceIndex == plan.count - 1 ? (boundary ?? .punctuation(fragment.source)) : .punctuation(fragment.source)
            pieces.append(SpeechRhythmProcessor.process(result.audio,
                allowance: SpeechFragmentEdges.nonSpeechEdges(inputIds: fragment.prepared.ids,
                    tokenDurationFrames: result.tokenDurationFrames), rhythm: rhythm,
                boundary: rhythm == .current ? .punctuation(fragment.source) : edge).audio)
        }
        let audio = PcmJoiner.join(segments: pieces, crossfadeMs: rhythm == .natural ? 0 : PcmJoiner.defaultCrossfadeMs)
        guard !audio.isEmpty else { throw LocalChineseSpeechError.emptyAudio }
        let protectedBytes = protectedOutputs.union(retainedOutputs).union(recentOutputs).reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard protectedBytes + audio.count * 4 + 4096 <= Self.maximumAudioBytes else {
            throw LocalChineseSpeechError.insufficientStorage
        }
        var file: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
              let channel = buffer.floatChannelData?[0] else { throw LocalChineseSpeechError.emptyAudio }
        buffer.frameLength = buffer.frameCapacity
        audio.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try file?.write(from: buffer)
        file = nil
        try Task.checkCancellation()
        guard let verified = try? AVAudioFile(forReading: temporary), verified.length == audio.count else {
            throw LocalChineseSpeechError.emptyAudio
        }
        // The index is the publication marker: readers require both it and complete audio.
        let index = AudioIndex(key: key, rhythmVersion: rhythm.version,
            boundary: boundary?.rawValue ?? "punctuation", sampleCount: audio.count)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporary, to: output)
        do {
            try JSONEncoder().encode(index).write(to: output.appendingPathExtension("json"), options: .atomic)
            if retainPrepared { try retain(output) }
        } catch {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: output.appendingPathExtension("json"))
            throw error
        }
        recentOutputs.removeAll { $0 == output }
        recentOutputs.append(output)
        if recentOutputs.count > 8 { recentOutputs.removeFirst(recentOutputs.count - 8) }
        pruneAudio(in: directory, keeping: Set(recentOutputs).union(protectedOutputs).union(retainedOutputs))
        guard let result = cachedAudio(output, key: key, version: rhythm.version, boundary: boundary?.rawValue ?? "punctuation") else { throw LocalChineseSpeechError.emptyAudio }
        return LocalChineseAudio(url: result.url, duration: result.duration, wasCached: false)
    }

    /// A lookahead of several sentences must not evict the plan it is about to need,
    /// because a miss costs another duration-model inference.
    private func cachePlan(_ sources: [String], for text: String) {
        if plans[text] == nil {
            planOrder.append(text)
            if planOrder.count > 16, let oldest = planOrder.first {
                planOrder.removeFirst()
                plans[oldest] = nil
            }
        }
        plans[text] = sources
    }

    private func cachedAudio(_ url: URL, key: String, version: String, boundary: String) -> LocalChineseAudio? {
        guard let data = try? Data(contentsOf: url.appendingPathExtension("json")),
              let index = try? JSONDecoder().decode(AudioIndex.self, from: data),
              index.key == key, index.rhythmVersion == version, index.boundary == boundary,
              let file = try? AVAudioFile(forReading: url), file.length > 0, file.length == index.sampleCount,
              file.processingFormat.sampleRate == 24000, file.processingFormat.channelCount == 1 else { return nil }
        return LocalChineseAudio(url: url, duration: Double(file.length) / 24000, wasCached: true)
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable { let path: String; let sha256: String }
        let schemaVersion: Int
        let identity: String
        let resourceFiles: [Entry]
    }

    private func validateResources() throws -> String {
        if let identity { return identity }
        let manifestURL = resources.appendingPathComponent("validation-identity.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw LocalChineseSpeechError.missingResources }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, !manifest.resourceFiles.isEmpty else { throw LocalChineseSpeechError.invalidResources }
        for entry in manifest.resourceFiles {
            try Task.checkCancellation()
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else { throw LocalChineseSpeechError.invalidResources }
            let file = try FileHandle(forReadingFrom: resources.appendingPathComponent(entry.path))
            defer { try? file.close() }
            var hash = SHA256()
            while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
                throw LocalChineseSpeechError.invalidResources
            }
        }
        // Bind audio caches to the actual signed manifest, not a caller-selected version label.
        let sourceIdentity = try Data(contentsOf: resources.appendingPathComponent("synthesis-source.sha256"))
        guard !sourceIdentity.isEmpty else { throw LocalChineseSpeechError.invalidResources }
        let verified = SHA256.hash(data: data + sourceIdentity).map { String(format: "%02x", $0) }.joined()
        identity = verified
        return verified
    }

    private func pruneAudio(in directory: URL, keeping resident: Set<URL>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "caf", let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where bytes > Self.maximumAudioBytes && !resident.contains(url) {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                bytes -= size
                try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
            }
        }
    }
}
