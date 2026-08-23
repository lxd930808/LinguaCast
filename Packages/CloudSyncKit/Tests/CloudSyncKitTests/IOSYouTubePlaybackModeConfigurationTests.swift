import XCTest
@testable import CloudSyncKit
import PodcastEnglishStudioCore

final class IOSYouTubePlaybackModeConfigurationTests: XCTestCase {
    func testDefaultIsOfficialIFrame() {
        let config = AppConfiguration()
        XCTAssertEqual(config.youTubePlaybackMode, .officialIFrame)
        XCTAssertEqual(config[.iosYouTubePlaybackMode], IOSYouTubePlaybackMode.officialIFrame.rawValue)
    }

    func testSubscriptNormalizesInvalidValues() {
        var config = AppConfiguration()
        config[.iosYouTubePlaybackMode] = "local_service"
        XCTAssertEqual(config.youTubePlaybackMode, .localService)
        config[.iosYouTubePlaybackMode] = "youtubekit"
        XCTAssertEqual(config.youTubePlaybackMode, .officialIFrame)
        config[.iosYouTubePlaybackMode] = ""
        XCTAssertEqual(config.youTubePlaybackMode, .officialIFrame)
        XCTAssertEqual(config[.iosYouTubePlaybackMode], IOSYouTubePlaybackMode.default.rawValue)
    }

    func testTypedAccessorRoundTrips() {
        var config = AppConfiguration()
        config.youTubePlaybackMode = .localService
        XCTAssertEqual(config.iosYouTubePlaybackMode, "local_service")
        config.youTubePlaybackMode = .officialIFrame
        XCTAssertEqual(config.iosYouTubePlaybackMode, "official_iframe")
    }
}

@MainActor
final class SettingsStorePlaybackModeTests: XCTestCase {
    override func tearDown() {
        let keychain = KeychainStore()
        try? keychain.deleteData(account: AppConfigurationKey.iosYouTubePlaybackMode.rawValue)
        super.tearDown()
    }

    func testMissingStoredValueLoadsDefault() {
        let keychain = KeychainStore()
        try? keychain.deleteData(account: AppConfigurationKey.iosYouTubePlaybackMode.rawValue)
        let store = SettingsStore()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.configuration.youTubePlaybackMode, .officialIFrame)
        XCTAssertEqual(store.committedConfiguration.youTubePlaybackMode, .officialIFrame)
    }

    func testInvalidStoredValueFallsBackToDefault() throws {
        let keychain = KeychainStore()
        try keychain.write("hls-native", for: .iosYouTubePlaybackMode)
        let store = SettingsStore()
        XCTAssertEqual(store.configuration.youTubePlaybackMode, .officialIFrame)
    }

    func testSavePersistsAndReloads() throws {
        let keychain = KeychainStore()
        try keychain.deleteData(account: AppConfigurationKey.iosYouTubePlaybackMode.rawValue)
        let store = SettingsStore()
        store.configuration.youTubePlaybackMode = .localService
        XCTAssertTrue(store.save().contains(.iosYouTubePlaybackMode))
        XCTAssertEqual(store.committedConfiguration.youTubePlaybackMode, .localService)
        XCTAssertEqual(try keychain.read(.iosYouTubePlaybackMode), "local_service")

        let reloaded = SettingsStore()
        XCTAssertEqual(reloaded.configuration.youTubePlaybackMode, .localService)
        XCTAssertEqual(reloaded.committedConfiguration.youTubePlaybackMode, .localService)
    }

    func testDiscardUnsavedChangesRestoresCommittedMode() {
        let store = SettingsStore(configuration: AppConfiguration())
        store.configuration.youTubePlaybackMode = .localService
        XCTAssertTrue(store.draftEditedKeys.contains(.iosYouTubePlaybackMode))

        store.discardUnsavedChanges()
        XCTAssertEqual(store.configuration.youTubePlaybackMode, .officialIFrame)
        XCTAssertFalse(store.draftEditedKeys.contains(.iosYouTubePlaybackMode))
        XCTAssertEqual(store.committedConfiguration.youTubePlaybackMode, .officialIFrame)
    }

    func testSyncedValuesMergeAndNormalize() throws {
        let keychain = KeychainStore()
        try keychain.deleteData(account: AppConfigurationKey.iosYouTubePlaybackMode.rawValue)
        let store = SettingsStore()

        try store.applySyncedValues([.iosYouTubePlaybackMode: "local_service"])
        XCTAssertEqual(store.configuration.youTubePlaybackMode, .localService)
        XCTAssertEqual(store.committedConfiguration.youTubePlaybackMode, .localService)
        XCTAssertEqual(try keychain.read(.iosYouTubePlaybackMode), "local_service")

        // Invalid remote values normalize to the default instead of persisting garbage.
        try store.applySyncedValues([.iosYouTubePlaybackMode: "bogus"])
        XCTAssertEqual(store.configuration.youTubePlaybackMode, .officialIFrame)
        XCTAssertEqual(store.committedConfiguration.youTubePlaybackMode, .officialIFrame)
    }
}
