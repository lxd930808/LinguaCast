import SwiftUI

#if os(tvOS)
struct TVSettingsOption<Value: Hashable>: Identifiable {
    var id: Value { value }
    let value: Value
    let title: String
    let help: String
    let icon: String
}

struct TVSettingsOptionScreen<Value: Hashable>: View {
    let title: String
    let options: [TVSettingsOption<Value>]
    let current: Value
    let onSelect: (Value) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVSettingsScene(
            model: screenModel,
            initialFocusID: optionID(current)
        ) {
            EmptyView()
        } onActivate: { row in
            guard let option = option(for: row.id) else { return }
            onSelect(option.value)
            dismiss()
        }
        .toolbar(.hidden, for: .automatic)
    }

    private var screenModel: TVSettingsScreenModel {
        let marked = options.map { option in
            TVSettingsRowDescriptor(
                id: optionID(option.value),
                title: option.title,
                icon: option.icon,
                help: option.help,
                kind: .action {},
                accessibilityIdentifier: "settings.option.\(optionID(option.value))",
                showsCheckmark: option.value == current
            )
        }
        let currentOption = options.first(where: { $0.value == current })
        return TVSettingsScreenModel(
            title: title,
            defaultIcon: currentOption?.icon ?? "checkmark.circle",
            defaultHelp: currentOption?.help ?? "",
            groups: [TVSettingsGroup(title: nil, rows: marked)]
        )
    }

    private func option(for rowID: String) -> TVSettingsOption<Value>? {
        options.first(where: { optionID($0.value) == rowID })
    }

    private func optionID(_ value: Value) -> String {
        String(describing: value)
    }
}
#endif
