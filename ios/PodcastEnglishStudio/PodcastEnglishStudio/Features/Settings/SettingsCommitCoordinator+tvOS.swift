import SwiftUI
import PodcastEnglishStudioCore
import CloudSyncKit

#if os(tvOS)
@MainActor
@Observable
final class TVSettingsCommitCoordinator {
    private let settings: SettingsStore
    private var pendingTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func requestSave() {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            _ = settings.save()
        }
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        _ = settings.save()
    }
}

@MainActor
@Observable
final class TVSettingsLocalMediaModel {
    var enabled: Bool
    var baseURL: String
    var token: String
    var mode: YTLocalMediaMode
    var preferredHeight: Int

    init() {
        let stored = YTLocalMediaServiceConfig.loadUserDefaults()
        enabled = stored.enabled
        baseURL = stored.baseURLString
        token = stored.token
        mode = stored.mode
        preferredHeight = stored.preferredHeight
    }

    var maskedToken: String {
        SettingsStatusFormatting.maskedCloudTokenTitle(token: token)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        persist()
    }

    func setMode(_ value: YTLocalMediaMode) {
        mode = value
        persist()
    }

    func setPreferredHeight(_ value: Int) {
        preferredHeight = value
        persist()
    }

    private func persist() {
        YTLocalMediaServiceConfig.saveUserDefaults(
            enabled: enabled,
            baseURLString: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            preferredHeight: preferredHeight
        )
        YTPlaybackBackend.resetLocalResolverCache()
    }
}
#endif
