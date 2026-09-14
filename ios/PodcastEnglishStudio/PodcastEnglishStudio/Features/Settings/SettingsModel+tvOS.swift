import SwiftUI

#if os(tvOS)
enum TVSettingsRoute: Hashable {
    case category(SettingsDestination)
    case generationBackend
    case translationQuality
    case englishSize
    case targetScale
    case subtitleOrder
    case localMediaMode
    case localMediaHeight
}

struct TVSettingsRowDescriptor: Identifiable {
    let id: String
    let title: String
    let icon: String
    let help: String
    let kind: TVSettingsRowKind
    var accessory: String? = nil
    var accessibilityIdentifier: String? = nil
    var isEnabled: Bool = true
    var disabledReason: String? = nil
    var isDestructive: Bool = false
    var isFocusable: Bool = true
    var showsCheckmark: Bool = false
}

enum TVSettingsRowKind {
    case disclosure(TVSettingsRoute)
    case value(TVSettingsRoute)
    case toggle(isOn: Bool, set: (Bool) -> Void)
    case action(() -> Void)
    case info
}

struct TVSettingsGroup {
    var title: String?
    var rows: [TVSettingsRowDescriptor]
}

struct TVSettingsScreenModel {
    var title: String
    var defaultIcon: String
    var defaultHelp: String
    var groups: [TVSettingsGroup]
    var showsSubtitlePreview: Bool = false

    var rows: [TVSettingsRowDescriptor] {
        groups.flatMap(\.rows)
    }

    var firstFocusableID: String? {
        rows.first(where: \.isFocusable)?.id
    }

    func row(id: String?) -> TVSettingsRowDescriptor? {
        guard let id else { return nil }
        return rows.first(where: { $0.id == id })
    }
}
#endif
