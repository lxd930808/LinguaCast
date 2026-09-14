import Foundation

public enum SpeechRhythm: String, Codable, CaseIterable, Sendable {
    case current, natural
    public var version: String { self == .current ? "current-v1" : "natural-v1" }
}

/// Boundary identity is part of the file cache key because the pause is baked in.
public enum SpeechBoundary: String, Codable, Sendable {
    case clause, sentence, paragraphProxy, speaker, end
    public var milliseconds: Double {
        switch self {
        case .clause: return 150
        case .sentence: return 300
        case .paragraphProxy: return 450
        case .speaker: return 500
        case .end: return 0
        }
    }
    public static func punctuation(_ text: String) -> Self {
        SpeechPause.trailingMilliseconds(after: text) == 300 ? .sentence : .clause
    }
}

public struct SpeechRhythmResult: Sendable {
    public let audio: [Float]
    public let removed: PcmTrimBounds
    public let addedPauseSamples: Int
}

public enum SpeechRhythmProcessor {
    public static func process(_ raw: [Float], allowance: PcmTrimBounds,
                               rhythm: SpeechRhythm, boundary: SpeechBoundary,
                               sampleRate: Int = PipelineConstants.sampleRate) -> SpeechRhythmResult {
        if rhythm == .current {
            let bounds = PcmSilenceTrimmer.silentEdges(raw, sampleRate: sampleRate, allowance: allowance)
            let speech = PcmSilenceTrimmer.trimEdges(raw, bounds: bounds, sampleRate: sampleRate)
            let pause = PcmSilenceTrimmer.silence(milliseconds: boundary == .sentence ? 300 : 150, sampleRate: sampleRate)
            return SpeechRhythmResult(audio: speech + pause, removed: bounds, addedPauseSamples: pause.count)
        }
        guard !raw.isEmpty, sampleRate > 0 else {
            return SpeechRhythmResult(audio: raw, removed: .none, addedPauseSamples: 0)
        }
        let measured = PcmSilenceTrimmer.silentEdges(raw, sampleRate: sampleRate, threshold: 0.00001,
            guardMilliseconds: 80, maxLeadingMilliseconds: 500, maxTrailingMilliseconds: 1200)
        let safe = PcmTrimBounds(leadingSamples: min(measured.leadingSamples, allowance.leadingSamples),
            trailingSamples: min(measured.trailingSamples, allowance.trailingSamples))
        let speech = Array(raw[safe.leadingSamples..<(raw.count - safe.trailingSamples)])
        let tail = PcmSilenceTrimmer.silentEdges(speech, sampleRate: sampleRate, threshold: 0.00001,
            guardMilliseconds: 0, maxLeadingMilliseconds: 0, maxTrailingMilliseconds: 1200).trailingSamples
        let additional = max(0, PcmSilenceTrimmer.samples(milliseconds: boundary.milliseconds, sampleRate: sampleRate) - tail)
        return SpeechRhythmResult(audio: speech + Array(repeating: 0, count: additional),
            removed: safe, addedPauseSamples: additional)
    }
}
