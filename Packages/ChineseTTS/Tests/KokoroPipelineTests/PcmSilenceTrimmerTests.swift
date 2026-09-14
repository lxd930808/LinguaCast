import XCTest
@testable import KokoroPipeline

final class PcmSilenceTrimmerTests: XCTestCase {
    private let rate = 24_000

    private func tone(seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(Double(rate) * seconds)
        return (0..<count).map { amplitude * sin(2 * .pi * 200 * Float($0) / Float(rate)) }
    }

    private func milliseconds(_ samples: Int) -> Double { Double(samples) / Double(rate) * 1000 }

    func testLeadingAndTrailingSilenceGoButTheGuardStays() {
        // A punctuation span is not always digital zero; -46 dBFS still counts as padding.
        let audio = tone(seconds: 0.315, amplitude: 0.005) + tone(seconds: 1)
            + PcmSilenceTrimmer.silence(milliseconds: 620)
        let bounds = PcmSilenceTrimmer.silentEdges(audio)
        XCTAssertEqual(milliseconds(bounds.leadingSamples), 300, accuracy: 2)
        XCTAssertEqual(milliseconds(bounds.trailingSamples), 605, accuracy: 2)
        let trimmed = PcmSilenceTrimmer.trimEdges(audio, bounds: bounds)
        XCTAssertEqual(milliseconds(trimmed.count), 1030, accuracy: 4)
    }

    func testInteriorSilenceIsNeverTouched() {
        let interior = PcmSilenceTrimmer.silence(milliseconds: 800)
        let audio = PcmSilenceTrimmer.silence(milliseconds: 300) + tone(seconds: 0.5) + interior + tone(seconds: 0.5)
        let trimmed = PcmSilenceTrimmer.trimEdges(audio, bounds: PcmSilenceTrimmer.silentEdges(audio))
        let zeros = trimmed.reduce(into: 0) { $0 += $1 == 0 ? 1 : 0 }
        XCTAssertGreaterThanOrEqual(zeros, interior.count)
    }

    func testAbsoluteCeilingBoundsTheTrim() {
        let audio = PcmSilenceTrimmer.silence(milliseconds: 2_000) + tone(seconds: 1)
        let bounds = PcmSilenceTrimmer.silentEdges(audio)
        XCTAssertEqual(milliseconds(bounds.leadingSamples), PcmSilenceTrimmer.defaultMaxLeadingMilliseconds, accuracy: 1)
    }

    func testTheModelsOwnPaddingMayRaiseTheCeilingButNeverLowerIt() {
        let audio = PcmSilenceTrimmer.silence(milliseconds: 2_000) + tone(seconds: 1)
        let generous = PcmTrimBounds(leadingSamples: PcmSilenceTrimmer.samples(milliseconds: 1_500), trailingSamples: 0)
        XCTAssertEqual(milliseconds(PcmSilenceTrimmer.silentEdges(audio, allowance: generous).leadingSamples),
                       1_500, accuracy: 1)
        // A model span shorter than the real decay must not block the trim.
        let stingy = PcmTrimBounds(leadingSamples: PcmSilenceTrimmer.samples(milliseconds: 50), trailingSamples: 0)
        XCTAssertEqual(milliseconds(PcmSilenceTrimmer.silentEdges(audio, allowance: stingy).leadingSamples),
                       PcmSilenceTrimmer.defaultMaxLeadingMilliseconds, accuracy: 1)
    }

    func testQuietButAudibleSpeechSurvives() {
        // -22 dBFS is the quietest phrase-final decay in the reference, well above the gate.
        let audio = tone(seconds: 0.2, amplitude: 0.079) + tone(seconds: 0.5)
        XCTAssertEqual(PcmSilenceTrimmer.silentEdges(audio), .none)
    }

    func testAnEntirelyQuietClipIsReturnedIntactSoCallersCanRejectIt() {
        let audio = PcmSilenceTrimmer.silence(milliseconds: 500)
        XCTAssertEqual(PcmSilenceTrimmer.silentEdges(audio), .none)
        XCTAssertEqual(PcmSilenceTrimmer.trimEdges(audio, bounds: .none).count, audio.count)
        XCTAssertTrue(PcmSilenceTrimmer.silentEdges([]) == .none)
    }

    func testCutEdgesAreFadedSoTheyCannotClick() {
        let audio = PcmSilenceTrimmer.silence(milliseconds: 300) + Array(repeating: Float(0.8), count: rate)
            + PcmSilenceTrimmer.silence(milliseconds: 300)
        let trimmed = PcmSilenceTrimmer.trimEdges(audio, bounds: PcmTrimBounds(
            leadingSamples: PcmSilenceTrimmer.samples(milliseconds: 300),
            trailingSamples: PcmSilenceTrimmer.samples(milliseconds: 300)))
        XCTAssertEqual(trimmed.first ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(trimmed.last ?? 1, 0, accuracy: 0.001)
        let fade = PcmSilenceTrimmer.samples(milliseconds: PcmSilenceTrimmer.defaultFadeMilliseconds)
        XCTAssertEqual(trimmed[fade + 10], 0.8, accuracy: 0.0001)
        for index in 1..<fade { XCTAssertGreaterThanOrEqual(trimmed[index], trimmed[index - 1]) }
    }

    func testNonSpeechEdgesFollowTheDurationModel() {
        // BOS, two phonemes, ".", EOS
        let ids: [Int32] = [0, 60, 61, 4, 0]
        let frames = [25, 10, 12, 30, 20]
        let edges = SpeechFragmentEdges.nonSpeechEdges(inputIds: ids, tokenDurationFrames: frames)
        XCTAssertEqual(edges.leadingSamples, 25 * PipelineConstants.samplesPerDurationFrame)
        XCTAssertEqual(edges.trailingSamples, 50 * PipelineConstants.samplesPerDurationFrame)
    }

    func testNonSpeechEdgesToleratesRaggedInputAndAllPaddingTokens() {
        // Frames that stop before the phonemes prove nothing about the edges: trim nothing.
        XCTAssertEqual(SpeechFragmentEdges.nonSpeechEdges(inputIds: [0, 60, 0], tokenDurationFrames: [5]), .none)
        XCTAssertEqual(SpeechFragmentEdges.nonSpeechEdges(inputIds: [0, 4, 0], tokenDurationFrames: [5, 5, 5]), .none)
        XCTAssertEqual(SpeechFragmentEdges.nonSpeechEdges(inputIds: [], tokenDurationFrames: []), .none)
    }

    func testWhitespaceIsSpeechNotPadding() {
        // Whitespace spans carry word onsets, so they must not be trimmed away.
        let ids: [Int32] = [0, KokoroVocabulary.whitespaceTokenId, 60, 0]
        let edges = SpeechFragmentEdges.nonSpeechEdges(inputIds: ids, tokenDurationFrames: [8, 40, 10, 8])
        XCTAssertEqual(edges.leadingSamples, 8 * PipelineConstants.samplesPerDurationFrame)
    }

    func testPauseLengthFollowsTheFinalPunctuation() {
        XCTAssertEqual(SpeechPause.trailingMilliseconds(after: "我在窗口里用它。"), SpeechPause.sentenceMilliseconds)
        XCTAssertEqual(SpeechPause.trailingMilliseconds(after: "真的吗？"), SpeechPause.sentenceMilliseconds)
        XCTAssertEqual(SpeechPause.trailingMilliseconds(after: "太好了！ "), SpeechPause.sentenceMilliseconds)
        XCTAssertEqual(SpeechPause.trailingMilliseconds(after: "在过去两年中，"), SpeechPause.clauseMilliseconds)
        XCTAssertEqual(SpeechPause.trailingMilliseconds(after: "他和团队学到的一切"), SpeechPause.clauseMilliseconds)
        XCTAssertEqual(SpeechPause.trailingMilliseconds(after: ""), SpeechPause.clauseMilliseconds)
    }

    func testSilenceLengthIsExact() {
        XCTAssertEqual(PcmSilenceTrimmer.silence(milliseconds: 300).count, 7_200)
        XCTAssertTrue(PcmSilenceTrimmer.silence(milliseconds: 0).isEmpty)
    }
}
