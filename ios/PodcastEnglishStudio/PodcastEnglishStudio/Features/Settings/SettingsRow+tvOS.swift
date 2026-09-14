import SwiftUI

#if os(tvOS)
struct TVSettingsRowView: View {
    let row: TVSettingsRowDescriptor
    let action: () -> Void

    var body: some View {
        if row.isFocusable {
            Button(action: action) {
                rowContent(isInfo: false)
            }
            .buttonStyle(TVSettingsRowButtonStyle(isDestructive: row.isDestructive))
            .accessibilityIdentifier(row.accessibilityIdentifier ?? row.id)
        } else {
            rowContent(isInfo: true)
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background {
                    RoundedRectangle(cornerRadius: LinguaTheme.compactRadius, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                }
                .accessibilityIdentifier(row.accessibilityIdentifier ?? row.id)
                .accessibilityElement(children: .combine)
        }
    }

    private func rowContent(isInfo: Bool) -> some View {
        HStack(spacing: 16) {
            Text(row.title)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let accessory = row.accessory, !accessory.isEmpty {
                Text(accessory)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if row.showsCheckmark {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
            }
            if row.kind.showsChevron {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
    }
}

private extension TVSettingsRowKind {
    var showsChevron: Bool {
        switch self {
        case .disclosure, .value: true
        case .action, .toggle, .info: false
        }
    }
}
#endif
