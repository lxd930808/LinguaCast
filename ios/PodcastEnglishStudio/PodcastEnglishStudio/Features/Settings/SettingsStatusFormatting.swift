import SwiftUI
import CloudSyncKit

enum SettingsStatusFormatting {
    static func subtitleCacheSummary(count: Int, byteCount: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return "\(count) · \(size)"
    }

    static func syncStatusIcon(phase: CloudSyncPhase) -> String {
        switch phase {
        case .synced: "checkmark.icloud"
        case .syncing, .starting: "icloud.and.arrow.up"
        case .noAccount: "icloud.slash"
        case .awaitingAccountConfirmation: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.icloud"
        }
    }

    static func syncStatusColor(phase: CloudSyncPhase) -> Color {
        switch phase {
        case .synced: LinguaTheme.success
        case .failed, .awaitingAccountConfirmation: LinguaTheme.warning
        default: LinguaTheme.secondaryText
        }
    }

    static func cloudServiceStatusTitle(configuration: AppConfiguration) -> String {
        guard configuration.contentServiceEnabled else {
            return L10n.string("settings.cloud_status_disabled", fallback: "Disabled")
        }
        guard !configuration.contentServiceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.string("settings.cloud_status_missing_token", fallback: "Access token not configured")
        }
        return L10n.string("settings.cloud_status_ready", fallback: "Ready")
    }

    static func maskedCloudTokenTitle(token: String) -> String {
        let masked = CloudTokenMasking.masked(token)
        return masked.isEmpty
            ? L10n.string("settings.cloud_token_not_set", fallback: "Not set")
            : masked
    }

    static func onOff(_ isOn: Bool) -> String {
        isOn
            ? L10n.string("common.on", fallback: "On")
            : L10n.string("common.off", fallback: "Off")
    }
}
