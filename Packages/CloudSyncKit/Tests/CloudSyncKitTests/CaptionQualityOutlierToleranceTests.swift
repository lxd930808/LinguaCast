import XCTest
@testable import CloudSyncKit

final class CaptionQualityOutlierToleranceTests: XCTestCase {
    func testDefaultIsOnePercent() {
        let config = AppConfiguration()
        XCTAssertEqual(config.captionQualityOutlierTolerancePercent, 1.0)
        XCTAssertEqual(config[.captionQualityOutlierTolerancePercent], "1")
        XCTAssertEqual(
            AppConfiguration.captionQualityOutlierTolerancePercent(from: ""),
            1.0
        )
    }

    func testBoundaryValuesAreAccepted() {
        var config = AppConfiguration()
        config[.captionQualityOutlierTolerancePercent] = "0"
        XCTAssertEqual(config.captionQualityOutlierTolerancePercent, 0)
        config[.captionQualityOutlierTolerancePercent] = "5"
        XCTAssertEqual(config.captionQualityOutlierTolerancePercent, 5)
        config[.captionQualityOutlierTolerancePercent] = "1.5"
        XCTAssertEqual(config.captionQualityOutlierTolerancePercent, 1.5)
        XCTAssertEqual(config[.captionQualityOutlierTolerancePercent], "1.5")
    }

    func testOutOfRangeAndInvalidValuesAreNormalized() {
        XCTAssertEqual(
            AppConfiguration.captionQualityOutlierTolerancePercent(from: "-1"),
            0
        )
        XCTAssertEqual(
            AppConfiguration.captionQualityOutlierTolerancePercent(from: "9"),
            5
        )
        XCTAssertEqual(
            AppConfiguration.captionQualityOutlierTolerancePercent(from: "not-a-number"),
            1.0
        )
        XCTAssertEqual(
            AppConfiguration.captionQualityOutlierTolerancePercent(from: "nan"),
            1.0
        )

        var config = AppConfiguration()
        config.captionQualityOutlierTolerancePercent = 2
        config[.captionQualityOutlierTolerancePercent] = "12"
        XCTAssertEqual(config.captionQualityOutlierTolerancePercent, 5)
        config.captionQualityOutlierTolerancePercent = 2
        config[.captionQualityOutlierTolerancePercent] = ""
        XCTAssertEqual(config.captionQualityOutlierTolerancePercent, 1.0)
    }

    @MainActor
    func testSettingsStorePersistenceRoundTrip() {
        let keychain = KeychainStore()
        try? keychain.deleteData(account: AppConfigurationKey.captionQualityOutlierTolerancePercent.rawValue)
        defer {
            try? keychain.deleteData(account: AppConfigurationKey.captionQualityOutlierTolerancePercent.rawValue)
        }

        let store = SettingsStore(configuration: AppConfiguration())
        store.configuration.captionQualityOutlierTolerancePercent = 2.5
        let changed = store.save()
        XCTAssertNil(store.lastError)
        XCTAssertTrue(changed.contains(.captionQualityOutlierTolerancePercent))

        let reloaded = SettingsStore()
        XCTAssertNil(reloaded.lastError)
        XCTAssertEqual(reloaded.configuration.captionQualityOutlierTolerancePercent, 2.5)
    }

    @MainActor
    func testSettingsStoreLoadDefaultsMissingValueAndClampsStoredOutliers() {
        let keychain = KeychainStore()
        try? keychain.deleteData(account: AppConfigurationKey.captionQualityOutlierTolerancePercent.rawValue)
        defer {
            try? keychain.deleteData(account: AppConfigurationKey.captionQualityOutlierTolerancePercent.rawValue)
        }

        let missing = SettingsStore()
        XCTAssertEqual(missing.configuration.captionQualityOutlierTolerancePercent, 1.0)

        try? keychain.write("8", for: .captionQualityOutlierTolerancePercent)
        let clamped = SettingsStore()
        XCTAssertEqual(clamped.configuration.captionQualityOutlierTolerancePercent, 5)
    }

    @MainActor
    func testApplySyncedValuesRoundTrip() throws {
        let store = SettingsStore(configuration: AppConfiguration())
        _ = store.save()

        try store.applySyncedValues([
            .captionQualityOutlierTolerancePercent: "0"
        ])
        XCTAssertEqual(store.configuration.captionQualityOutlierTolerancePercent, 0)
        XCTAssertEqual(store.committedConfiguration.captionQualityOutlierTolerancePercent, 0)

        try store.applySyncedValues([
            .captionQualityOutlierTolerancePercent: "3.25"
        ])
        XCTAssertEqual(store.configuration.captionQualityOutlierTolerancePercent, 3.25)
        XCTAssertEqual(store.committedConfiguration.captionQualityOutlierTolerancePercent, 3.25)
    }
}
