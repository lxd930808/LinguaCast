import SwiftUI

#if os(tvOS)
struct TVSettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.02 : 1)
            .background {
                RoundedRectangle(cornerRadius: LinguaTheme.compactRadius, style: .continuous)
                    .fill(isFocused ? Color.white : rowFill)
            }
            .foregroundStyle(isFocused ? Color.black : (isDestructive ? LinguaTheme.danger : LinguaTheme.primaryText))
            .shadow(
                color: isFocused ? Color.black.opacity(0.28) : .clear,
                radius: isFocused ? 12 : 0,
                y: isFocused ? 6 : 0
            )
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var rowFill: Color {
        Color.white.opacity(0.12)
    }
}
#endif
