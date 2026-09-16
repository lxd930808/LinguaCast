import Foundation
import Observation

enum SettingsDestination: String, Hashable, CaseIterable {
    case root
    case account
    case iCloudSync
    case setupProgress
    case cloudService
    case translation
    case subtitles
    case localMedia
    case advanced
    case about
}

@MainActor
@Observable
final class SettingsNavigation {
    var pendingDestination: SettingsDestination?
    var pathResetID = 0

    func open(_ destination: SettingsDestination) {
        pendingDestination = destination
    }

    func consumePendingDestination() -> SettingsDestination? {
        let destination = pendingDestination
        pendingDestination = nil
        return destination
    }

    func resetPathOnLeavingSettings() {
        pathResetID += 1
        pendingDestination = nil
    }
}
