import XCTest
@testable import CloudSyncKit
import PodcastEnglishStudioCore

@MainActor
final class OpenSourceConfigurationTests: XCTestCase {
    func testMissingContainerDisablesCloudSyncWithoutRegisteringForNotifications() async {
        let suiteName = "CloudSyncKit.OpenSourceConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = CloudSyncCoordinator(
            defaults: defaults,
            containerIdentifier: nil
        )
        var notificationRegistrationCount = 0
        coordinator.remoteNotificationRegistrar = {
            notificationRegistrationCount += 1
        }

        XCTAssertEqual(coordinator.phase, .disabled)
        let syncPhase = await coordinator.syncNow()
        XCTAssertEqual(syncPhase, .disabled)
        XCTAssertEqual(notificationRegistrationCount, 0)

        let lookup = await coordinator.lookup(identity: SubtitleArtifactIdentity(
            contentKind: .youtubeVideo,
            contentKey: "missing-local-artifact",
            targetLanguage: "zh-Hans"
        ))
        XCTAssertEqual(lookup, .notFound)
    }

    func testContainerIdentifierIsTrimmedAndEnablesCloudSync() {
        let suiteName = "CloudSyncKit.OpenSourceConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = CloudSyncCoordinator(
            defaults: defaults,
            containerIdentifier: "  iCloud.com.example.LinguaCast  "
        )

        XCTAssertEqual(coordinator.containerIdentifier, "iCloud.com.example.LinguaCast")
        XCTAssertEqual(coordinator.phase, .starting)
    }

    func testMobileSetupAllowlistNeverContainsSecretConfigurationKeys() {
        XCTAssertTrue(AppConfigurationKey.mobileSetupAllowedKeys.isDisjoint(with: [
            .youtubeAPIKey,
            .dashscopeAPIKey,
            .translationAPIKey,
            .ossAccessKeyID,
            .ossAccessKeySecret,
            .minimaxAPIKey
        ]))
        XCTAssertEqual(
            AppConfigurationKey.mobileSetupAllowedKeys,
            [
                .translationProvider,
                .translationBaseURL,
                .translationModelID,
                .translationReasoningEffort,
                .ossEndpoint,
                .ossBucket,
                .ossRegion
            ]
        )
    }
}
