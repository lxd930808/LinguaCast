import Foundation
import Observation
import Security
import PodcastEnglishStudioCore

public enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error: \(status)"
        }
    }
}

public final class KeychainStore {
    // iCloud 回归重点：Keychain service 名保持不变。
    private let service = "PodcastEnglishStudio"

    public struct Item {
        public var value: String
        public var modifiedAt: Date?

        public init(value: String, modifiedAt: Date?) {
            self.value = value
            self.modifiedAt = modifiedAt
        }
    }

    public init() {}

    public func read(_ key: AppConfigurationKey) throws -> String {
        try readItem(key).value
    }

    public func readItem(_ key: AppConfigurationKey) throws -> Item {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return Item(value: "", modifiedAt: nil) }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data
        else { return Item(value: "", modifiedAt: nil) }
        return Item(
            value: String(data: data, encoding: .utf8) ?? "",
            modifiedAt: attributes[kSecAttrModificationDate as String] as? Date
        )
    }

    public func write(_ value: String, for key: AppConfigurationKey) throws {
        try writeData(Data(value.utf8), account: key.rawValue)
    }

    public func readData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return item as? Data
    }

    public func writeData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func deleteData(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

@MainActor
@Observable
public final class SettingsStore {
    /// In-memory draft edited by Settings. Preview surfaces may observe this.
    public var configuration = AppConfiguration()
    public var lastError: String?
    @ObservationIgnored
    private let keychain = KeychainStore()
    @ObservationIgnored public private(set) var fieldModificationDates: [AppConfigurationKey: Date] = [:]
    /// Last successfully persisted configuration. Playback should observe this for subtitle presentation.
    public private(set) var committedConfiguration = AppConfiguration()
    @ObservationIgnored private var translationTargetIsProvisional = false
    @ObservationIgnored public var onSave: ((Set<AppConfigurationKey>, Date) -> Void)?

    public init() {
        load()
    }

    public init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.committedConfiguration = configuration
    }

    /// Keys that differ between the Settings draft and the last successful save.
    public var draftEditedKeys: Set<AppConfigurationKey> {
        Set(AppConfigurationKey.allCases.filter { configuration[$0] != committedConfiguration[$0] })
    }

    /// Draft subtitle presentation preferences (Settings preview).
    public var subtitlePresentationDraft: SubtitlePresentationPreferences {
        get { configuration.subtitlePresentation }
        set { configuration.subtitlePresentation = newValue }
    }

    /// Committed subtitle presentation preferences (players).
    public var committedSubtitlePresentation: SubtitlePresentationPreferences {
        committedConfiguration.subtitlePresentation
    }

    public func load() {
        do {
            var storedValues: [AppConfigurationKey: String] = [:]
            var storedDates: [AppConfigurationKey: Date] = [:]
            for key in AppConfigurationKey.allCases {
                let item = try keychain.readItem(key)
                storedValues[key] = item.value
                storedDates[key] = item.modifiedAt
            }
            configuration.youtubeAPIKey = storedValues[.youtubeAPIKey] ?? ""
            configuration.dashscopeAPIKey = storedValues[.dashscopeAPIKey] ?? ""
            configuration.translationProvider = TranslationProviderPolicy.normalizedProvider(
                storedValues[.translationProvider, default: ""].ifEmpty("dashscope")
            )
            configuration.translationAPIKey = storedValues[.translationAPIKey] ?? ""
            configuration.translationBaseURL = TranslationProviderPolicy.requestBaseURL(
                provider: configuration.translationProvider,
                configuredBaseURL: storedValues[.translationBaseURL] ?? ""
            )
            configuration.translationModelID = TranslationChatRequestPolicy.normalizedModelID(
                storedValues[.translationModelID] ?? "",
                provider: configuration.translationProvider
            )
            configuration.translationReasoningEffort = TranslationChatRequestPolicy.normalizedReasoningEffort(
                storedValues[.translationReasoningEffort] ?? "",
                provider: configuration.translationProvider
            )
            configuration.ossAccessKeyID = storedValues[.ossAccessKeyID] ?? ""
            configuration.ossAccessKeySecret = storedValues[.ossAccessKeySecret] ?? ""
            configuration.ossEndpoint = storedValues[.ossEndpoint] ?? ""
            configuration.ossBucket = storedValues[.ossBucket] ?? ""
            configuration.ossRegion = storedValues[.ossRegion] ?? ""
            configuration.minimaxAPIKey = storedValues[.minimaxAPIKey] ?? ""
            configuration.subtitleFontSize = Self.legacySubtitleFontSize(
                from: storedValues[.subtitleFontSize] ?? ""
            )
            configuration.preferredVideoQuality = storedValues[.preferredVideoQuality] ?? ""
            configuration.videoPlaybackRate = AppConfiguration.videoPlaybackRate(
                from: storedValues[.videoPlaybackRate] ?? ""
            )
            configuration.subtitleDisplayMode = AppConfiguration.subtitleDisplayMode(
                from: storedValues[.subtitleDisplayMode] ?? ""
            )
            configuration.contentFilterEnabled = Self.bool(from: storedValues[.contentFilterEnabled] ?? "")
            configuration.contentFilterKeywords = storedValues[.contentFilterKeywords] ?? ""
            configuration.contentFilterPrompt = storedValues[.contentFilterPrompt] ?? ""
            // Keep-awake defaults to on; only an explicit stored "false" disables it.
            configuration.keepScreenAwake = storedValues[.keepScreenAwake].map { Self.bool(from: $0) } ?? true
            configuration.captionQualityOutlierTolerancePercent =
                AppConfiguration.captionQualityOutlierTolerancePercent(
                    from: storedValues[.captionQualityOutlierTolerancePercent] ?? ""
                )
            configuration.iosYouTubePlaybackMode = IOSYouTubePlaybackMode.normalized(
                storedValues[.iosYouTubePlaybackMode]
            ).rawValue
            if let storedTarget = storedValues[.translationTargetLanguage], !storedTarget.isEmpty {
                configuration.translationTargetLanguage = TranslationTargetPolicy.normalized(storedTarget).rawValue
                translationTargetIsProvisional = false
            } else {
                let hasLegacyConfiguration = storedDates.contains {
                    $0.key != .translationTargetLanguage
                }
                let target: TranslationTarget = hasLegacyConfiguration
                    ? .simplifiedChinese
                    : TranslationTargetPolicy.defaultTarget(preferredLanguageIdentifiers: Locale.preferredLanguages)
                configuration.translationTarget = target
                translationTargetIsProvisional = true
            }
            configuration.translationQualityMode = TranslationQualityMode.normalized(
                storedValues[.translationQualityMode]
            ).rawValue

            try applySubtitlePresentationMigrationIfNeeded(
                storedValues: storedValues,
                storedDates: &storedDates
            )

            fieldModificationDates = storedDates
            committedConfiguration = configuration
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Discards unsaved Settings draft values and restores the last successful save.
    public func discardUnsavedChanges() {
        configuration = committedConfiguration
        lastError = nil
    }

    @discardableResult
    public func save() -> Set<AppConfigurationKey> {
        do {
            let provider = TranslationProviderPolicy.normalizedProvider(configuration.translationProvider)
            configuration.translationProvider = provider
            configuration.translationModelID = TranslationChatRequestPolicy.normalizedModelID(
                configuration.translationModelID,
                provider: provider
            )
            configuration.translationReasoningEffort = TranslationChatRequestPolicy.normalizedReasoningEffort(
                configuration.translationReasoningEffort,
                provider: provider
            )
            configuration.subtitlePresentation = configuration.subtitlePresentation
            configuration.subtitleDisplayMode = AppConfiguration.subtitleDisplayMode(
                from: configuration.subtitleDisplayMode
            )
            configuration.iosYouTubePlaybackMode = IOSYouTubePlaybackMode.normalized(
                configuration.iosYouTubePlaybackMode
            ).rawValue

            var changed = Set(AppConfigurationKey.allCases.filter {
                configuration[$0] != committedConfiguration[$0]
            })
            if changed.contains(.translationProvider) {
                changed.formUnion(AppConfigurationKey.translationGroup)
            }
            guard !changed.isEmpty else {
                lastError = nil
                return []
            }

            let modifiedAt = Date()
            for key in changed {
                try keychain.write(configuration[key], for: key)
                fieldModificationDates[key] = modifiedAt
            }
            if changed.contains(.translationTargetLanguage) {
                translationTargetIsProvisional = false
            }
            committedConfiguration = configuration
            lastError = nil
            onSave?(changed, modifiedAt)
            return changed
        } catch {
            // Keep the draft and leave committedConfiguration unchanged so players stay stable.
            lastError = error.localizedDescription
            return []
        }
    }

    /// Applies remote values with draft-aware merge:
    /// unedited draft fields take the remote value; edited draft fields keep local draft.
    public func applySyncedValues(_ values: [AppConfigurationKey: String]) throws {
        do {
            let dirtyKeys = draftEditedKeys
            for (key, value) in values {
                let shouldForceTranslationTarget =
                    key == .translationTargetLanguage && translationTargetIsProvisional
                if dirtyKeys.contains(key) && !shouldForceTranslationTarget {
                    continue
                }
                if configuration[key] != value || shouldForceTranslationTarget {
                    try keychain.write(value, for: key)
                    configuration[key] = value
                    committedConfiguration[key] = configuration[key]
                }
            }
            if values[.translationTargetLanguage] != nil {
                translationTargetIsProvisional = false
            }
            configuration.translationProvider = TranslationProviderPolicy.normalizedProvider(
                configuration.translationProvider
            )
            configuration.translationBaseURL = TranslationProviderPolicy.requestBaseURL(
                provider: configuration.translationProvider,
                configuredBaseURL: configuration.translationBaseURL
            )
            configuration.translationModelID = TranslationChatRequestPolicy.normalizedModelID(
                configuration.translationModelID,
                provider: configuration.translationProvider
            )
            configuration.translationReasoningEffort = TranslationChatRequestPolicy.normalizedReasoningEffort(
                configuration.translationReasoningEffort,
                provider: configuration.translationProvider
            )
            // Refresh committed non-dirty fields that may have been normalized above.
            for key in AppConfigurationKey.allCases where !dirtyKeys.contains(key) {
                committedConfiguration[key] = configuration[key]
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func promoteProvisionalTranslationTargetIfNeeded() throws {
        guard translationTargetIsProvisional else { return }
        let key = AppConfigurationKey.translationTargetLanguage
        let modifiedAt = Date()
        try keychain.write(configuration[key], for: key)
        fieldModificationDates[key] = modifiedAt
        translationTargetIsProvisional = false
        committedConfiguration = configuration
        onSave?([key], modifiedAt)
    }

    /// One-time migration from legacy `subtitleFontSize` / `off` into V7 fields.
    /// Runs only when `subtitleEnglishSizeLevel` is absent from storage.
    private func applySubtitlePresentationMigrationIfNeeded(
        storedValues: [AppConfigurationKey: String],
        storedDates: inout [AppConfigurationKey: Date]
    ) throws {
        let hasNewLevel = !(storedValues[.subtitleEnglishSizeLevel] ?? "").isEmpty
        if hasNewLevel {
            configuration.subtitleEnglishSizeLevel = SubtitlePresentationPreferences.normalizedEnglishSizeLevel(
                from: storedValues[.subtitleEnglishSizeLevel] ?? ""
            )
            configuration.subtitleTargetScalePercent = SubtitlePresentationPreferences.normalizedTargetScalePercent(
                from: storedValues[.subtitleTargetScalePercent] ?? ""
            )
            configuration.subtitleOrder = SubtitleOrder.normalized(
                storedValues[.subtitleOrder] ?? ""
            ).rawValue
            configuration.subtitleDisplayMode = AppConfiguration.subtitleDisplayMode(
                from: storedValues[.subtitleDisplayMode] ?? ""
            )
            return
        }

        let legacySize = Double(storedValues[.subtitleFontSize] ?? "")
        let migratedLevel = SubtitlePresentationPreferences.englishSizeLevel(
            migratingFromLegacyFontSize: legacySize
        )
        configuration.subtitleEnglishSizeLevel = migratedLevel
        configuration.subtitleTargetScalePercent = SubtitlePresentationPreferences.defaultTargetScalePercent
        configuration.subtitleOrder = SubtitleOrder.default.rawValue
        configuration.subtitleDisplayMode = AppConfiguration.subtitleDisplayMode(
            from: storedValues[.subtitleDisplayMode] ?? ""
        )

        let modifiedAt = Date()
        let migratedKeys: [AppConfigurationKey] = [
            .subtitleEnglishSizeLevel,
            .subtitleTargetScalePercent,
            .subtitleOrder,
            .subtitleDisplayMode
        ]
        for key in migratedKeys {
            try keychain.write(configuration[key], for: key)
            storedDates[key] = modifiedAt
        }
    }

    private static func legacySubtitleFontSize(from value: String) -> Double {
        guard let size = Double(value),
              AppConfiguration.subtitleFontSizeOptions.contains(size)
        else {
            return AppConfiguration.defaultSubtitleFontSize
        }
        return size
    }

    private static func bool(from value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "on": true
        default: false
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
