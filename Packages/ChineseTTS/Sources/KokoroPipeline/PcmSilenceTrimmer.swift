/// Edge trimming for cached playback audio.
///
/// The duration model allocates real time to the leading BOS token and to
/// sentence-final punctuation, and ``suppressPunctuationTokenAudio`` renders
/// those spans as silence. Measured on 142 clips synthesized on an iPhone 15
/// Pro: 306 ms of leading silence (median, max 348 ms) and 622 ms of trailing
/// silence (median, max 747 ms) — 18.7% of everything the listener hears.
/// Played sentence after sentence that reads as a blank between every line.
///
/// Trimming happens where audio is cached for playback, never inside the
/// parity-validated synthesis pipeline: the waveform is unchanged, only the
/// start and end of the stored file move.

import Foundation

public struct PcmTrimBounds: Equatable, Sendable {
    public let leadingSamples: Int
    public let trailingSamples: Int

    public static let none = PcmTrimBounds(leadingSamples: 0, trailingSamples: 0)

    public init(leadingSamples: Int, trailingSamples: Int) {
        self.leadingSamples = max(0, leadingSamples)
        self.trailingSamples = max(0, trailingSamples)
    }
}

public enum PcmSilenceTrimmer {
    /// -38 dBFS: the loudest the PyTorch reference ever renders a punctuation
    /// span, while phrase-final speech decay stays at -11 to -22 dBFS (measured
    /// 2026-07-14, see ``suppressPunctuationTokenAudio``). The gate sits in that
    /// gap, and the model's own non-speech span caps it besides.
    public static let defaultThreshold: Float = 0.0126
    /// A single stray sample must not make a span count as speech.
    public static let defaultWindowMilliseconds = 1.0
    /// Silence kept before the first audible sample, so a soft onset survives.
    public static let defaultGuardMilliseconds = 15.0
    public static let defaultFadeMilliseconds = 3.0
    /// Absolute ceilings. Measured padding is 306 ms of head and up to 747 ms of
    /// tail, so these bound a misjudgement without binding normal clips.
    public static let defaultMaxLeadingMilliseconds = 500.0
    public static let defaultMaxTrailingMilliseconds = 1200.0

    public static func samples(milliseconds: Double, sampleRate: Int = PipelineConstants.sampleRate) -> Int {
        guard milliseconds > 0, sampleRate > 0 else { return 0 }
        return Int((Double(sampleRate) * milliseconds / 1000).rounded())
    }

    public static func silence(milliseconds: Double, sampleRate: Int = PipelineConstants.sampleRate) -> [Float] {
        Array(repeating: 0, count: samples(milliseconds: milliseconds, sampleRate: sampleRate))
    }

    /// Measures silence at both edges, bounded by the absolute ceilings.
    /// `allowance` — the span the duration model itself marked as non-speech —
    /// may raise a ceiling, never lower it: the model accounts for the pause it
    /// wrote into the timing, but the generator's own decay tail runs past it.
    public static func silentEdges(
        _ audio: [Float],
        sampleRate: Int = PipelineConstants.sampleRate,
        threshold: Float = defaultThreshold,
        windowMilliseconds: Double = defaultWindowMilliseconds,
        guardMilliseconds: Double = defaultGuardMilliseconds,
        maxLeadingMilliseconds: Double = defaultMaxLeadingMilliseconds,
        maxTrailingMilliseconds: Double = defaultMaxTrailingMilliseconds,
        allowance: PcmTrimBounds? = nil
    ) -> PcmTrimBounds {
        guard !audio.isEmpty, sampleRate > 0 else { return .none }
        let window = max(1, samples(milliseconds: windowMilliseconds, sampleRate: sampleRate))
        let keep = samples(milliseconds: guardMilliseconds, sampleRate: sampleRate)

        var leading = 0
        while leading + window <= audio.count, isSilent(audio, from: leading, count: window, threshold: threshold) {
            leading += window
        }
        // Nothing audible anywhere: leave the clip alone so callers can still reject it as empty.
        guard leading + window <= audio.count else { return .none }
        var trailing = 0
        while trailing + window <= audio.count - leading,
              isSilent(audio, from: audio.count - trailing - window, count: window, threshold: threshold) {
            trailing += window
        }

        let ceiling = PcmTrimBounds(
            leadingSamples: max(samples(milliseconds: maxLeadingMilliseconds, sampleRate: sampleRate),
                                allowance?.leadingSamples ?? 0),
            trailingSamples: max(samples(milliseconds: maxTrailingMilliseconds, sampleRate: sampleRate),
                                 allowance?.trailingSamples ?? 0))
        let bounds = PcmTrimBounds(
            leadingSamples: min(leading - keep, ceiling.leadingSamples),
            trailingSamples: min(trailing - keep, ceiling.trailingSamples))
        // An entirely quiet clip stays intact so callers can still reject it as empty.
        guard bounds.leadingSamples + bounds.trailingSamples < audio.count else { return .none }
        return bounds
    }

    /// Removes the measured edges and fades the new boundaries so the cut cannot click.
    /// Interior silence is never touched.
    public static func trimEdges(
        _ audio: [Float],
        bounds: PcmTrimBounds,
        sampleRate: Int = PipelineConstants.sampleRate,
        fadeMilliseconds: Double = defaultFadeMilliseconds
    ) -> [Float] {
        let removed = bounds.leadingSamples + bounds.trailingSamples
        guard removed > 0, removed < audio.count else { return audio }
        var result = Array(audio[bounds.leadingSamples..<(audio.count - bounds.trailingSamples)])
        let fade = min(samples(milliseconds: fadeMilliseconds, sampleRate: sampleRate), result.count / 2)
        guard fade > 0 else { return result }
        if bounds.leadingSamples > 0 {
            for index in 0..<fade { result[index] *= Float(index) / Float(fade) }
        }
        if bounds.trailingSamples > 0 {
            for index in 0..<fade { result[result.count - 1 - index] *= Float(index) / Float(fade) }
        }
        return result
    }

    private static func isSilent(_ audio: [Float], from start: Int, count: Int, threshold: Float) -> Bool {
        for index in start..<(start + count) where abs(audio[index]) > threshold { return false }
        return true
    }
}

public enum SpeechFragmentEdges {
    /// The samples the duration model gave to non-speech tokens at each edge:
    /// the BOS/EOS padding and any run of pause punctuation next to it.
    /// Whitespace is excluded on purpose — those spans carry word onsets and
    /// phrase-final decays (see ``suppressPunctuationTokenAudio``).
    public static func nonSpeechEdges(
        inputIds: [Int32],
        tokenDurationFrames: [Int],
        samplesPerDurationFrame: Int = PipelineConstants.samplesPerDurationFrame
    ) -> PcmTrimBounds {
        let count = min(inputIds.count, tokenDurationFrames.count)
        guard count > 0, samplesPerDurationFrame > 0 else { return .none }
        var first = 0
        var leadingFrames = 0
        while first < count, isNonSpeech(inputIds[first]) {
            leadingFrames += max(0, tokenDurationFrames[first])
            first += 1
        }
        // Nothing but padding and punctuation: leave the decision to the caller.
        guard first < count else { return .none }
        var last = count - 1
        var trailingFrames = 0
        while last > first, isNonSpeech(inputIds[last]) {
            trailingFrames += max(0, tokenDurationFrames[last])
            last -= 1
        }
        return PcmTrimBounds(
            leadingSamples: leadingFrames * samplesPerDurationFrame,
            trailingSamples: trailingFrames * samplesPerDurationFrame)
    }

    private static func isNonSpeech(_ id: Int32) -> Bool {
        id == KokoroVocabulary.bosEosTokenId || KokoroVocabulary.silentPunctuationTokenIds.contains(id)
    }
}

public enum SpeechPause {
    /// A full stop gets a breath; a clause break gets a beat. Measured against
    /// the corpus: 49% of translated lines end in 。, 12% in ，and 30% have no
    /// final punctuation at all because they continue into the next line.
    public static let sentenceMilliseconds = 300.0
    public static let clauseMilliseconds = 150.0

    public static func trailingMilliseconds(after text: String) -> Double {
        guard let last = text.reversed().first(where: { !$0.isWhitespace }) else { return clauseMilliseconds }
        return "。．.！!？?…".contains(last) ? sentenceMilliseconds : clauseMilliseconds
    }
}
