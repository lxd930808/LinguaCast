import SwiftUI

#if os(tvOS)
struct TVSettingsDetailPane<Preview: View>: View {
    let icon: String
    let title: String
    let help: String
    var status: String? = nil
    var iconColor: Color = LinguaTheme.accent
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: icon)
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(iconColor)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(help)
                    .font(.body)
                    .foregroundStyle(LinguaTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let status, !status.isEmpty {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(LinguaTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            preview()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.18), value: title)
        .animation(.easeInOut(duration: 0.18), value: help)
    }
}
#endif
