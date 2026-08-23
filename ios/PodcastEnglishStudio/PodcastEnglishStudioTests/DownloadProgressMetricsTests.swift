import XCTest
@testable import PodcastEnglishStudioCore

final class DownloadProgressMetricsTests: XCTestCase {
    func testFractionUsesExpectedByteCount() {
        XCTAssertEqual(
            DownloadProgressMetrics.fraction(completedBytes: 25, expectedBytes: 100),
            0.25
        )
    }

    func testFractionIsUnavailableWhenServerOmitsExpectedByteCount() {
        XCTAssertNil(
            DownloadProgressMetrics.fraction(
                completedBytes: 25,
                expectedBytes: NSURLSessionTransferSizeUnknown
            )
        )
    }

    func testFractionIsClampedToCompletedRange() {
        XCTAssertEqual(
            DownloadProgressMetrics.fraction(completedBytes: 125, expectedBytes: 100),
            1
        )
    }

    func testBytesPerSecondUsesByteDeltaOverElapsedTime() {
        XCTAssertEqual(
            DownloadProgressMetrics.bytesPerSecond(bytesDelta: 1_048_576, elapsedSeconds: 2),
            524_288
        )
    }

    func testSpeedSmoothingReducesSingleSampleJitter() {
        XCTAssertEqual(
            DownloadProgressMetrics.smoothedBytesPerSecond(
                previous: 1_000,
                sample: 3_000,
                sampleWeight: 0.25
            ),
            1_500
        )
    }

    func testFailedGenerationClearsPersistedProgress() {
        XCTAssertTrue(
            SourceGenerationStateRecoveryPolicy.shouldClear(
                step: "downloading",
                subtitleStatus: "failed"
            )
        )
    }

    func testReadyGenerationClearsPersistedProgress() {
        XCTAssertTrue(
            SourceGenerationStateRecoveryPolicy.shouldClear(
                step: "translating",
                subtitleStatus: "ready"
            )
        )
    }

    func testRunningGenerationKeepsPersistedProgress() {
        XCTAssertFalse(
            SourceGenerationStateRecoveryPolicy.shouldClear(
                step: "downloading",
                subtitleStatus: "running"
            )
        )
    }

    func testMissingGenerationStepNeedsNoRecovery() {
        XCTAssertFalse(
            SourceGenerationStateRecoveryPolicy.shouldClear(
                step: nil,
                subtitleStatus: "failed"
            )
        )
    }
}
