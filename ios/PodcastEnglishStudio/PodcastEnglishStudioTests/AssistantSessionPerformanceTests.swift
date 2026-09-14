#if canImport(PodcastEnglishStudio) && os(iOS)
import XCTest
import DomainModels
@testable import PodcastEnglishStudio

final class AssistantSessionPerformanceTests: XCTestCase {
    func testSnapshotIsNotRefreshedOnTokenDeltasOrToolNoise() {
        XCTAssertFalse(AssistantViewModel.shouldRefreshSnapshot(for: .messageDelta))
        XCTAssertFalse(AssistantViewModel.shouldRefreshSnapshot(for: .toolStarted))
        XCTAssertFalse(AssistantViewModel.shouldRefreshSnapshot(for: .toolCompleted))
        XCTAssertFalse(AssistantViewModel.shouldRefreshSnapshot(for: .heartbeat))
        XCTAssertFalse(AssistantViewModel.shouldRefreshSnapshot(for: .turnStarted))
    }

    func testSnapshotRefreshesOnlyOnCoarseTurnBoundaries() {
        XCTAssertTrue(AssistantViewModel.shouldRefreshSnapshot(for: .turnAccepted))
        XCTAssertTrue(AssistantViewModel.shouldRefreshSnapshot(for: .reportReady))
        XCTAssertTrue(AssistantViewModel.shouldRefreshSnapshot(for: .turnCompleted))
        XCTAssertTrue(AssistantViewModel.shouldRefreshSnapshot(for: .turnFailed))
        XCTAssertTrue(AssistantViewModel.shouldRefreshSnapshot(for: .citationReady))
        XCTAssertTrue(AssistantViewModel.shouldRefreshSnapshot(for: .sessionTitleUpdated))
    }

    func testCompactAgeUsesMinutesHoursDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AssistantListFormatting.compactAge(since: now.addingTimeInterval(-59), now: now), "1m")
        XCTAssertEqual(AssistantListFormatting.compactAge(since: now.addingTimeInterval(-61), now: now), "1m")
        XCTAssertEqual(AssistantListFormatting.compactAge(since: now.addingTimeInterval(-3600), now: now), "1h")
        XCTAssertEqual(AssistantListFormatting.compactAge(since: now.addingTimeInterval(-86_400), now: now), "1d")
        XCTAssertEqual(AssistantListFormatting.compactAge(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }
}
#endif
