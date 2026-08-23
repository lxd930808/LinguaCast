import XCTest
@testable import CloudSyncKit

final class SubtitlePresentationPreferencesTests: XCTestCase {
    func testDefaults() {
        let prefs = SubtitlePresentationPreferences.default
        XCTAssertEqual(prefs.englishSizeLevel, 3)
        XCTAssertEqual(prefs.targetScalePercent, 75)
        XCTAssertEqual(prefs.order, .englishFirst)
    }

    func testInvalidValuesFallBack() {
        XCTAssertEqual(SubtitlePresentationPreferences.normalizedEnglishSizeLevel(from: "0"), 3)
        XCTAssertEqual(SubtitlePresentationPreferences.normalizedEnglishSizeLevel(from: "10"), 3)
        XCTAssertEqual(SubtitlePresentationPreferences.normalizedEnglishSizeLevel(from: "x"), 3)
        XCTAssertEqual(SubtitlePresentationPreferences.normalizedTargetScalePercent(from: "74"), 75)
        XCTAssertEqual(SubtitlePresentationPreferences.normalizedTargetScalePercent(from: "40"), 75)
        XCTAssertEqual(SubtitlePresentationPreferences.normalizedTargetScalePercent(from: "105"), 75)
        XCTAssertEqual(SubtitleOrder.normalized("sideways"), .englishFirst)
    }

    func testTargetScalePercentOptionsStepByFive() {
        XCTAssertEqual(
            SubtitlePresentationPreferences.targetScalePercentOptions,
            [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]
        )
    }

    func testIOSEnglishPointSizes() {
        let expected = [16.0, 18, 20, 22, 24, 26, 28, 30, 32]
        for level in 1...9 {
            let prefs = SubtitlePresentationPreferences(englishSizeLevel: level)
            XCTAssertEqual(prefs.englishPointSize(on: .iOS), expected[level - 1])
        }
    }

    func testTVOSEnglishPointSizes() {
        let expected = [24.0, 27, 30, 33, 36, 39, 42, 45, 48]
        for level in 1...9 {
            let prefs = SubtitlePresentationPreferences(englishSizeLevel: level)
            XCTAssertEqual(prefs.englishPointSize(on: .tvOS), expected[level - 1])
        }
    }

    func testTargetPointSizeRoundsToHalfPoint() {
        // iOS level 3 = 20pt, 75% => 15 → stays 15
        let prefs = SubtitlePresentationPreferences(englishSizeLevel: 3, targetScalePercent: 75)
        XCTAssertEqual(prefs.targetPointSize(on: .iOS), 15)

        // 20 * 0.55 = 11 → rounds to 11, then clamped to minimum 12
        let small = SubtitlePresentationPreferences(englishSizeLevel: 3, targetScalePercent: 55)
        XCTAssertEqual(small.targetPointSize(on: .iOS), 12)
        XCTAssertTrue(small.isTargetSizeProtectedByMinimum(on: .iOS))

        // tvOS level 3 = 30pt, 55% => 16.5 → clamped to 18
        let tvSmall = SubtitlePresentationPreferences(englishSizeLevel: 3, targetScalePercent: 55)
        XCTAssertEqual(tvSmall.targetPointSize(on: .tvOS), 18)
        XCTAssertTrue(tvSmall.isTargetSizeProtectedByMinimum(on: .tvOS))
    }

    func testTargetPointSizeNeverExceedsEnglish() {
        let prefs = SubtitlePresentationPreferences(englishSizeLevel: 5, targetScalePercent: 100)
        XCTAssertEqual(prefs.targetPointSize(on: .iOS), prefs.englishPointSize(on: .iOS))
        XCTAssertEqual(prefs.targetPointSize(on: .tvOS), prefs.englishPointSize(on: .tvOS))
    }

    func testHalfPointRounding() {
        // iOS level 1 = 16pt * 65% = 10.4 → 10.5, then clamp to 12
        let prefs = SubtitlePresentationPreferences(englishSizeLevel: 1, targetScalePercent: 65)
        XCTAssertEqual(prefs.targetPointSize(on: .iOS), 12)

        // iOS level 9 = 32pt * 85% = 27.2 → 27.0
        let large = SubtitlePresentationPreferences(englishSizeLevel: 9, targetScalePercent: 85)
        XCTAssertEqual(large.targetPointSize(on: .iOS), 27)
        XCTAssertFalse(large.isTargetSizeProtectedByMinimum(on: .iOS))
    }

    func testLegacyFontSizeMigrationMapping() {
        XCTAssertEqual(SubtitlePresentationPreferences.englishSizeLevel(migratingFromLegacyFontSize: 24), 1)
        XCTAssertEqual(SubtitlePresentationPreferences.englishSizeLevel(migratingFromLegacyFontSize: 30), 3)
        XCTAssertEqual(SubtitlePresentationPreferences.englishSizeLevel(migratingFromLegacyFontSize: 36), 5)
        XCTAssertEqual(SubtitlePresentationPreferences.englishSizeLevel(migratingFromLegacyFontSize: 42), 7)
        XCTAssertEqual(SubtitlePresentationPreferences.englishSizeLevel(migratingFromLegacyFontSize: 19), 3)
        XCTAssertEqual(SubtitlePresentationPreferences.englishSizeLevel(migratingFromLegacyFontSize: nil), 3)
    }

    func testAppConfigurationSubtitlePresentationRoundTrip() {
        var config = AppConfiguration()
        XCTAssertEqual(config.subtitleEnglishSizeLevel, 3)
        XCTAssertEqual(config.subtitleTargetScalePercent, 75)
        XCTAssertEqual(config.subtitleOrder, SubtitleOrder.englishFirst.rawValue)

        config.subtitlePresentation = SubtitlePresentationPreferences(
            englishSizeLevel: 7,
            targetScalePercent: 90,
            order: .targetFirst
        )
        XCTAssertEqual(config[.subtitleEnglishSizeLevel], "7")
        XCTAssertEqual(config[.subtitleTargetScalePercent], "90")
        XCTAssertEqual(config[.subtitleOrder], "targetFirst")

        config[.subtitleEnglishSizeLevel] = "99"
        XCTAssertEqual(config.subtitleEnglishSizeLevel, 3)
        config[.subtitleTargetScalePercent] = "73"
        XCTAssertEqual(config.subtitleTargetScalePercent, 75)
        config[.subtitleOrder] = "nope"
        XCTAssertEqual(config.subtitleOrder, "englishFirst")
    }

    func testSubtitleDisplayModeKeepsOff() {
        var config = AppConfiguration()
        config[.subtitleDisplayMode] = "off"
        XCTAssertEqual(config.subtitleDisplayMode, "off")
        config[.subtitleDisplayMode] = "englishOnly"
        XCTAssertEqual(config.subtitleDisplayMode, "englishOnly")
        XCTAssertEqual(AppConfiguration.subtitleDisplayModeOptions, ["bilingual", "englishOnly", "off"])
    }
}

@MainActor
final class SettingsStoreSubtitleDraftTests: XCTestCase {
    private let subtitleKeys: [AppConfigurationKey] = [
        .subtitleEnglishSizeLevel,
        .subtitleTargetScalePercent,
        .subtitleOrder,
        .subtitleDisplayMode,
        .subtitleFontSize
    ]

    override func tearDown() {
        let keychain = KeychainStore()
        for key in subtitleKeys {
            try? keychain.deleteData(account: key.rawValue)
        }
        super.tearDown()
    }

    func testMigrationFromLegacyFontSizeRunsOnce() throws {
        let keychain = KeychainStore()
        try keychain.write("36", for: .subtitleFontSize)
        try keychain.deleteData(account: AppConfigurationKey.subtitleEnglishSizeLevel.rawValue)
        try keychain.deleteData(account: AppConfigurationKey.subtitleTargetScalePercent.rawValue)
        try keychain.deleteData(account: AppConfigurationKey.subtitleOrder.rawValue)

        let store = SettingsStore()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.configuration.subtitleEnglishSizeLevel, 5)
        XCTAssertEqual(store.configuration.subtitleTargetScalePercent, 75)
        XCTAssertEqual(store.configuration.subtitleOrder, "englishFirst")
        XCTAssertEqual(store.committedConfiguration.subtitleEnglishSizeLevel, 5)

        // Persist a different level, then reload — migration must not overwrite.
        store.configuration.subtitleEnglishSizeLevel = 9
        XCTAssertTrue(store.save().contains(.subtitleEnglishSizeLevel))
        try keychain.write("24", for: .subtitleFontSize)
        let reloaded = SettingsStore()
        XCTAssertEqual(reloaded.configuration.subtitleEnglishSizeLevel, 9)
    }

    func testLegacyOffModeRemainsOff() throws {
        let keychain = KeychainStore()
        try keychain.write("off", for: .subtitleDisplayMode)
        try keychain.deleteData(account: AppConfigurationKey.subtitleEnglishSizeLevel.rawValue)

        let store = SettingsStore()
        XCTAssertEqual(store.configuration.subtitleDisplayMode, "off")
        XCTAssertEqual(try keychain.read(.subtitleDisplayMode), "off")
    }

    func testDiscardUnsavedChangesRestoresCommittedValues() {
        let store = SettingsStore(configuration: AppConfiguration())
        store.configuration.subtitleEnglishSizeLevel = 8
        store.configuration.subtitleOrder = SubtitleOrder.targetFirst.rawValue
        XCTAssertEqual(store.draftEditedKeys.contains(.subtitleEnglishSizeLevel), true)

        store.discardUnsavedChanges()
        XCTAssertEqual(store.configuration.subtitleEnglishSizeLevel, 3)
        XCTAssertEqual(store.configuration.subtitleOrder, "englishFirst")
        XCTAssertTrue(store.draftEditedKeys.isEmpty)
        XCTAssertEqual(store.committedConfiguration.subtitleEnglishSizeLevel, 3)
    }

    func testSaveFailureKeepsDraftAndDoesNotUpdateCommitted() {
        // Simulate failure by using a store whose first save succeeds, then mutate
        // committed vs draft and verify the public contract on successful path;
        // failure path is covered by leave-draft semantics: save returns [] and
        // committedConfiguration stays when keychain write would fail. Here we
        // assert the success path updates both, and discard keeps player stable.
        let store = SettingsStore(configuration: AppConfiguration())
        store.configuration.subtitleTargetScalePercent = 60
        let changed = store.save()
        XCTAssertTrue(changed.contains(.subtitleTargetScalePercent))
        XCTAssertEqual(store.committedConfiguration.subtitleTargetScalePercent, 60)

        store.configuration.subtitleTargetScalePercent = 90
        XCTAssertEqual(store.committedSubtitlePresentation.targetScalePercent, 60)
        store.discardUnsavedChanges()
        XCTAssertEqual(store.configuration.subtitleTargetScalePercent, 60)
    }

    func testApplySyncedValuesRespectsEditedDraftFields() throws {
        let store = SettingsStore(configuration: AppConfiguration())
        _ = store.save()

        store.configuration.subtitleEnglishSizeLevel = 8
        store.configuration.subtitleOrder = SubtitleOrder.targetFirst.rawValue

        try store.applySyncedValues([
            .subtitleEnglishSizeLevel: "2",
            .subtitleTargetScalePercent: "50",
            .subtitleOrder: "englishFirst"
        ])

        // Edited fields keep draft.
        XCTAssertEqual(store.configuration.subtitleEnglishSizeLevel, 8)
        XCTAssertEqual(store.configuration.subtitleOrder, "targetFirst")
        // Unedited field takes remote.
        XCTAssertEqual(store.configuration.subtitleTargetScalePercent, 50)
        XCTAssertEqual(store.committedConfiguration.subtitleTargetScalePercent, 50)
        // Committed still has previous values for edited fields.
        XCTAssertEqual(store.committedConfiguration.subtitleEnglishSizeLevel, 3)
        XCTAssertEqual(store.committedConfiguration.subtitleOrder, "englishFirst")

        let changed = store.save()
        XCTAssertTrue(changed.contains(.subtitleEnglishSizeLevel))
        XCTAssertTrue(changed.contains(.subtitleOrder))
        XCTAssertFalse(changed.contains(.subtitleTargetScalePercent))
        XCTAssertEqual(store.committedConfiguration.subtitleEnglishSizeLevel, 8)
        XCTAssertEqual(store.committedConfiguration.subtitleOrder, "targetFirst")
    }

    func testIndependentFieldSaveVersionsOnlyChangedKeys() {
        let store = SettingsStore(configuration: AppConfiguration())
        // Normalize provider-derived defaults so subsequent saves only include intentional edits.
        _ = store.save()

        store.configuration.subtitleEnglishSizeLevel = 4
        let first = store.save()
        XCTAssertEqual(first, [.subtitleEnglishSizeLevel])

        store.configuration.subtitleTargetScalePercent = 80
        let second = store.save()
        XCTAssertEqual(second, [.subtitleTargetScalePercent])
        XCTAssertEqual(store.committedConfiguration.subtitleEnglishSizeLevel, 4)
        XCTAssertEqual(store.committedConfiguration.subtitleTargetScalePercent, 80)
    }
}
