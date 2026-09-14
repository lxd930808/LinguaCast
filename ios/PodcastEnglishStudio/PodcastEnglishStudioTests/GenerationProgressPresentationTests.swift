import XCTest
@testable import PodcastEnglishStudioCore

final class GenerationProgressPresentationTests: XCTestCase {
    private func title(_ step: String? = "translating", progress: Double? = nil,
                       download: Double? = nil, speed: Double? = nil,
                       count: Int? = nil, total: Int? = nil, hidesZero: Bool = false) -> String? {
        GenerationProgressPresentation.title(
            step: step, progress: progress, downloadProgress: download,
            bytesPerSecond: speed, completedCount: count, totalCount: total,
            hidesZeroProgress: hidesZero, localize: { _, fallback in fallback }
        )
    }

    func testExactCountsTakePriorityWithoutEstimatingFromOverallProgress() {
        XCTAssertEqual(title(progress: 0.8, count: 96, total: 210), "Translating Subtitles · 96 / 210")
        XCTAssertEqual(title(progress: 0.8, count: 0, total: 210), "Translating Subtitles · 0 / 210")
        XCTAssertEqual(title(progress: 0.8, count: 211, total: 210), "Translating Subtitles · 80%")
        XCTAssertEqual(title(count: 4, total: 0), "Translating Subtitles")
    }

    func testMissingAndNonFiniteProgressDoesNotCreateFakePercentages() {
        for fraction in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            XCTAssertEqual(title(progress: fraction), "Translating Subtitles")
        }
        XCTAssertEqual(title("transcribing", progress: 0, hidesZero: true), "Transcribing Audio")
        XCTAssertEqual(title("transcribing", progress: 0.46, hidesZero: true), "Transcribing Audio · 46%")
        XCTAssertNil(title(nil))
        XCTAssertEqual(title("unknown"), "Preparing")
    }

    func testDownloadAliasesUseExactDownloadProgressAndOptionalSpeed() {
        for step in ["download", "downloading", "fetching_audio"] {
            XCTAssertEqual(title(step, progress: 0.15, download: 0.62), "Downloading Audio · 62%")
            XCTAssertEqual(title(step, progress: 0.62), "Downloading Audio · 62%")
            XCTAssertTrue(title(step, download: 0.62, speed: 1_400_000)?.hasSuffix("/s") == true)
            XCTAssertEqual(title(step, speed: .infinity), "Downloading Audio")
        }
    }

    func testTerminalAndQueuedStatesDoNotPresentStaleProgress() {
        XCTAssertEqual(title("queued", progress: 0.7), "Queued on the server")
        XCTAssertEqual(title("completed", progress: 1, count: 8, total: 8), "Completed")
        XCTAssertEqual(title(progress: 1), "Translating Subtitles · 100%")
    }

    func testCloudAndLocalStagesShareLocalizationKeys() {
        for (local, cloud) in [("download", "fetching_audio"), ("segment_source", "refining_subtitles"),
                               ("build_learning_pack", "packaging"), ("translate", "translating")] {
            XCTAssertEqual(GenerationProgressPresentation.stage(local).key, GenerationProgressPresentation.stage(cloud).key)
        }
        let text = GenerationProgressPresentation.title(step: "translating", progress: 0.5) { key, _ in key }
        XCTAssertEqual(text, "pipeline.step.translate · 50%")
    }
}
