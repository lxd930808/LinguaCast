import XCTest
@testable import KokoroPipeline

final class SpeechRhythmTests: XCTestCase {
    func testNaturalPreservesSamplesAndCapsModelAllowance() {
        let raw = Array(repeating: Float(0), count: 24000) + [Float(0.00002), 0.5, 0.00002] + Array(repeating: Float(0), count: 48000)
        let result = SpeechRhythmProcessor.process(raw, allowance: PcmTrimBounds(leadingSamples: 100000, trailingSamples: 100000), rhythm: .natural, boundary: .end)
        XCTAssertLessThanOrEqual(result.removed.leadingSamples, 12000)
        XCTAssertLessThanOrEqual(result.removed.trailingSamples, 28800)
        XCTAssertEqual(result.audio, Array(raw[result.removed.leadingSamples..<(raw.count - result.removed.trailingSamples)]))
        XCTAssertEqual(result.addedPauseSamples, 0)
    }
    func testTargetIncludesExistingTailAndNoFade() {
        let raw = Array(repeating: Float(0), count: 4800) + [Float(0.7)] + Array(repeating: Float(0), count: 4800)
        let result = SpeechRhythmProcessor.process(raw, allowance: .none, rhythm: .natural, boundary: .sentence)
        XCTAssertEqual(result.addedPauseSamples, 2400)
        XCTAssertEqual(Array(result.audio.prefix(raw.count)), raw)
    }
    func testEmptyQuietAndVeryShortClipsAreNotCut() {
        for raw: [Float] in [[], [0], [0.00002], Array(repeating: 0, count: 2400)] {
            let result = SpeechRhythmProcessor.process(raw, allowance: PcmTrimBounds(leadingSamples: 999, trailingSamples: 999), rhythm: .natural, boundary: .end)
            XCTAssertEqual(result.audio, raw)
            XCTAssertEqual(result.removed, .none)
        }
    }
    func testVersionsAndSemanticPauses() {
        XCTAssertNotEqual(SpeechRhythm.current.version, SpeechRhythm.natural.version)
        XCTAssertEqual(SpeechBoundary.speaker.milliseconds, 500)
        XCTAssertEqual(SpeechBoundary.paragraphProxy.milliseconds, 450)
        XCTAssertEqual(SpeechBoundary.punctuation("结束。"), .sentence)
    }
}
