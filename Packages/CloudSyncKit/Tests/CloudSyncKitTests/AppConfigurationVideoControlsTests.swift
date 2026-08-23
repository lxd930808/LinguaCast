import XCTest
@testable import CloudSyncKit

final class AppConfigurationVideoControlsTests: XCTestCase {
    // MARK: - Defaults

    func testDefaults() {
        let config = AppConfiguration()
        XCTAssertEqual(config.videoPlaybackRate, 1.0)
        XCTAssertEqual(config.subtitleDisplayMode, "bilingual")
        XCTAssertEqual(config[.videoPlaybackRate], "1")
        XCTAssertEqual(config[.subtitleDisplayMode], "bilingual")
    }

    // MARK: - Playback rate coercion

    func testValidPlaybackRatesAreAccepted() {
        var config = AppConfiguration()
        for rate in AppConfiguration.videoPlaybackRateOptions {
            config[.videoPlaybackRate] = String(format: "%g", rate)
            XCTAssertEqual(config.videoPlaybackRate, rate)
        }
        config[.videoPlaybackRate] = "1.5"
        XCTAssertEqual(config.videoPlaybackRate, 1.5)
        XCTAssertEqual(config[.videoPlaybackRate], "1.5")
    }

    func testInvalidPlaybackRateCoercesToDefault() {
        var config = AppConfiguration()
        config.videoPlaybackRate = 1.5
        config[.videoPlaybackRate] = "3.0"
        XCTAssertEqual(config.videoPlaybackRate, 1.0)
        config.videoPlaybackRate = 1.5
        config[.videoPlaybackRate] = "not-a-number"
        XCTAssertEqual(config.videoPlaybackRate, 1.0)
        config.videoPlaybackRate = 1.5
        config[.videoPlaybackRate] = ""
        XCTAssertEqual(config.videoPlaybackRate, 1.0)
    }

    // MARK: - Subtitle display mode coercion

    func testValidSubtitleDisplayModesAreAccepted() {
        var config = AppConfiguration()
        for mode in ["bilingual", "englishOnly", "off"] {
            config[.subtitleDisplayMode] = mode
            XCTAssertEqual(config.subtitleDisplayMode, mode)
        }
    }

    func testInvalidSubtitleDisplayModeCoercesToDefault() {
        var config = AppConfiguration()
        config.subtitleDisplayMode = "englishOnly"
        config[.subtitleDisplayMode] = "french"
        XCTAssertEqual(config.subtitleDisplayMode, "bilingual")
        config.subtitleDisplayMode = "englishOnly"
        config[.subtitleDisplayMode] = ""
        XCTAssertEqual(config.subtitleDisplayMode, "bilingual")
    }

    // MARK: - Persistence round-trip

    @MainActor
    func testSettingsStorePersistenceRoundTrip() {
        let keychain = KeychainStore()
        try? keychain.deleteData(account: AppConfigurationKey.videoPlaybackRate.rawValue)
        try? keychain.deleteData(account: AppConfigurationKey.subtitleDisplayMode.rawValue)
        defer {
            try? keychain.deleteData(account: AppConfigurationKey.videoPlaybackRate.rawValue)
            try? keychain.deleteData(account: AppConfigurationKey.subtitleDisplayMode.rawValue)
        }

        let store = SettingsStore(configuration: AppConfiguration())
        store.configuration.videoPlaybackRate = 1.5
        store.configuration.subtitleDisplayMode = "off"
        let changed = store.save()
        XCTAssertNil(store.lastError)
        XCTAssertTrue(changed.contains(.videoPlaybackRate))
        XCTAssertTrue(changed.contains(.subtitleDisplayMode))

        let reloaded = SettingsStore()
        XCTAssertNil(reloaded.lastError)
        XCTAssertEqual(reloaded.configuration.videoPlaybackRate, 1.5)
        XCTAssertEqual(reloaded.configuration.subtitleDisplayMode, "off")
    }

    @MainActor
    func testSettingsStoreLoadCoercesInvalidStoredValues() {
        let keychain = KeychainStore()
        try? keychain.write("3.0", for: .videoPlaybackRate)
        try? keychain.write("weird", for: .subtitleDisplayMode)
        defer {
            try? keychain.deleteData(account: AppConfigurationKey.videoPlaybackRate.rawValue)
            try? keychain.deleteData(account: AppConfigurationKey.subtitleDisplayMode.rawValue)
        }

        let store = SettingsStore()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.configuration.videoPlaybackRate, 1.0)
        XCTAssertEqual(store.configuration.subtitleDisplayMode, "bilingual")
    }
}
