import ChineseFrontend
import CoreML
import Foundation
import KokoroPipeline

public enum ChineseSynthesisResourceError: Error { case invalidSourceWeights }

public final class ChineseSynthesisEngine {
    public let provider: CachedModelProvider
    private let frontend: ChineseFrontend
    private let vocab: [String: Int32]
    private let voice: [Float]
    private let weights: Weights
    private let planner: SpeechPlanner
    private struct Weights: Decodable { let linear_weights: [Float]; let linear_bias: Float }

    public init(resources: URL, cache: URL, buckets: [Int] = [7, 15], durationUnits: MLComputeUnits = .cpuAndGPU) throws {
        weights = try JSONDecoder().decode(Weights.self, from: Data(contentsOf: resources.appendingPathComponent("hnsf_weights.json")))
        guard weights.linear_weights.count == 9, weights.linear_weights.allSatisfy(\.isFinite), weights.linear_bias.isFinite else {
            throw ChineseSynthesisResourceError.invalidSourceWeights
        }
        frontend = try ChineseFrontend(lexiconURL: resources.appendingPathComponent("lexicon.json"))
        vocab = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: resources.appendingPathComponent("vocab.json")))
        let bytes = try Data(contentsOf: resources.appendingPathComponent("voice.bin"))
        guard bytes.count > 0, bytes.count % (256 * 4) == 0 else { throw SpeechPlanningError.invalidPrediction }
        voice = bytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
        guard voice.allSatisfy(\.isFinite) else { throw SpeechPlanningError.invalidPrediction }
        planner = try SpeechPlanner(buckets: buckets)
        provider = try CachedModelProvider(root: resources.appendingPathComponent("coreml"), cache: cache,
                                          buckets: buckets, durationUnits: durationUnits)
    }
    public func plan(_ text: String) throws -> [SpeechFragment] {
        try planner.plan(text, prepare: prepare, predict: predict)
    }
    private func prepare(_ text: String) throws -> PreparedSpeech {
        let phones = try frontend.phonemes(for: text)
        guard !phones.isEmpty else { throw SpeechPlanningError.emptyText }
        let ids: [Int32] = try [0] + phones.map {
            guard let token = vocab[String($0)] else { throw ChineseFrontendError.unknownText(String($0)) }
            return token
        } + [0]
        let row = min(phones.count - 1, voice.count / 256 - 1)
        return PreparedSpeech(phonemes: phones, ids: ids, style: Array(voice[(row * 256)..<((row + 1) * 256)]))
    }
    private func predict(_ input: PreparedSpeech) throws -> Int {
        try autoreleasepool {
        let choice = try KokoroPipeline.selectDurationChoice(provider.durationModelChoices(), actualTokens: input.ids.count)
        let model = try provider.durationModel(choice: choice)
        let ids = try MLMultiArray(shape: [1, NSNumber(value: choice.tokenLength)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: choice.tokenLength)], dataType: .int32)
        for index in 0..<choice.tokenLength {
            ids[index] = NSNumber(value: index < input.ids.count ? input.ids[index] : 0)
            mask[index] = NSNumber(value: index < input.ids.count ? 1 : 0)
        }
        let style = try MLMultiArray(shape: [1, 256], dataType: .float32)
        for index in 0..<256 { style[index] = NSNumber(value: input.style[index]) }
        let speed = try MLMultiArray(shape: [1], dataType: .float32); speed[0] = 1
        var features = ["input_ids": MLFeatureValue(multiArray: ids), "ref_s": MLFeatureValue(multiArray: style), "speed": MLFeatureValue(multiArray: speed)]
        if choice.requiresAttentionMask { features["attention_mask"] = MLFeatureValue(multiArray: mask) }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        guard let duration = result.featureValue(for: "pred_dur")?.multiArrayValue else { throw SpeechPlanningError.invalidPrediction }
        let frames = try readDurationFrames(from: duration, validCount: input.ids.count).reduce(0, +)
        guard frames > 0 else { throw SpeechPlanningError.invalidPrediction }
        return frames
        }
    }
    public func synthesize(_ fragment: SpeechFragment) throws -> SynthesisResult {
        let result = try autoreleasepool {
        var dump: TensorDumpWriter? = nil
        return try executeKokoroSynthesis(request: KokoroSynthesisRequest(inputIds: fragment.prepared.ids,
            attentionMask: Array(repeating: 1, count: fragment.prepared.ids.count), refS: fragment.prepared.style),
            modelProvider: provider, linearWeights: weights.linear_weights, linearBias: weights.linear_bias, tensorDump: &dump)
        }
        guard result.predictedDurationFrames == fragment.predictedFrames,
              result.predictedDurationFrames <= result.tFrames,
              result.bucketSeconds == fragment.bucketSeconds,
              !result.audio.isEmpty, result.audio.allSatisfy(\.isFinite) else {
            throw SpeechPlanningError.invalidPrediction
        }
        return result
    }
}
