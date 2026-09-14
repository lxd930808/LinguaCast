import XCTest
@testable import CloudSyncKit

@MainActor
final class OpenRouterConfigurationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let keychain = KeychainStore()
        for key in AppConfigurationKey.allCases {
            try? keychain.write("", for: key)
        }
    }

    func testOpenRouterConfigurationSurvivesSaveAndReload() {
        let store = SettingsStore(configuration: AppConfiguration())
        _ = store.save()
        store.configuration.translationProvider = "openrouter"
        store.configuration.translationBaseURL = "https://openrouter.ai/api/v1"
        store.configuration.translationModelID = "~openai/gpt-latest"
        store.configuration.translationReasoningEffort = "xhigh"
        store.configuration.translationAPIKey = "test-openrouter-key"
        let changed = store.save()

        XCTAssertEqual(store.lastError, nil)
        XCTAssertTrue(changed.contains(.translationProvider))

        let reloaded = SettingsStore()
        XCTAssertEqual(reloaded.configuration.translationProvider, "openrouter")
        XCTAssertEqual(reloaded.configuration.translationBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(reloaded.configuration.translationModelID, "~openai/gpt-latest")
        XCTAssertEqual(reloaded.configuration.translationReasoningEffort, "xhigh")
        XCTAssertEqual(reloaded.configuration.translationAPIKey, "test-openrouter-key")
    }

    func testSavingProviderChangeMarksWholeTranslationGroup() {
        let store = SettingsStore(configuration: AppConfiguration())
        _ = store.save()
        store.configuration.translationProvider = "openrouter"
        store.save()
        store.configuration.translationProvider = "deepseek"
        let changed = store.save()

        XCTAssertEqual(store.lastError, nil)
        XCTAssertTrue(changed.isSuperset(of: AppConfigurationKey.translationGroup))
    }

    func testSyncedOpenRouterValuesAreNormalizedIntoCommittedConfiguration() throws {
        let store = SettingsStore(configuration: AppConfiguration())
        _ = store.save()
        try store.applySyncedValues([
            .translationProvider: " OpenRouter ",
            .translationBaseURL: "",
            .translationModelID: "",
            .translationReasoningEffort: "unsupported"
        ])

        XCTAssertEqual(store.lastError, nil)
        XCTAssertEqual(store.configuration.translationProvider, "openrouter")
        XCTAssertEqual(store.configuration.translationBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(store.configuration.translationModelID, "~openai/gpt-latest")
        XCTAssertEqual(store.configuration.translationReasoningEffort, "medium")
        XCTAssertEqual(store.committedConfiguration.translationProvider, "openrouter")
        XCTAssertEqual(store.committedConfiguration.translationReasoningEffort, "medium")
    }

    func testDraftTranslationValuesAreNotOverwrittenByUnrelatedRemoteFields() throws {
        let store = SettingsStore(configuration: AppConfiguration())
        _ = store.save()
        store.configuration.translationProvider = "openrouter"
        store.configuration.translationBaseURL = "https://proxy.example.com/openrouter/v1"

        try store.applySyncedValues([
            .preferredVideoQuality: "1080p",
            .translationProvider: "deepseek",
            .translationBaseURL: "https://api.deepseek.com"
        ])

        XCTAssertEqual(store.lastError, nil)
        XCTAssertEqual(store.configuration.translationProvider, "openrouter")
        XCTAssertEqual(store.configuration.translationBaseURL, "https://proxy.example.com/openrouter/v1")
        XCTAssertEqual(store.configuration.preferredVideoQuality, "1080p")
    }

    func testTranslationAPIKeyStaysSecretForOpenRouter() {
        XCTAssertTrue(AppConfigurationKey.translationAPIKey.isSecret)
        XCTAssertFalse(AppConfigurationKey.translationProvider.isSecret)
        XCTAssertFalse(AppConfigurationKey.translationReasoningEffort.isSecret)
    }
}
