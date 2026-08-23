import SwiftUI

enum LinguaTheme {
    static let background = Color("LinguaBackground")
    static let backgroundRaised = Color("LinguaBackgroundRaised")
    static let surface = Color("LinguaSurface")
    static let surfaceElevated = Color("LinguaSurfaceElevated")
    static let border = Color("LinguaBorder")
    static let primaryText = Color("LinguaPrimaryText")
    static let secondaryText = Color("LinguaSecondaryText")
    static let tertiaryText = Color("LinguaTertiaryText")
    static let progressTrack = Color("LinguaProgressTrack")
    static let accent = Color(red: 0.184, green: 0.549, blue: 1)
    static let success = Color("LinguaSuccess")
    static let warning = Color("LinguaWarning")
    static let danger = Color("LinguaDanger")

    static let compactRadius: CGFloat = 12
    static let cardRadius: CGFloat = 18
    static let heroRadius: CGFloat = 24

    static let pageHorizontalPadding: CGFloat = {
        #if os(tvOS)
        72
        #else
        16
        #endif
    }()

    static let contentMaxWidth: CGFloat = {
        #if os(tvOS)
        1_760
        #else
        1_180
        #endif
    }()

    static func cardShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? Color.black.opacity(0.08) : .clear
    }
}

struct LinguaScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinguaTheme.background
            RadialGradient(
                colors: [
                    LinguaTheme.accent.opacity(colorScheme == .light ? 0.055 : 0.12),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 760
            )
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color.clear,
                        LinguaTheme.backgroundRaised.opacity(0.7)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct LinguaCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = LinguaTheme.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(LinguaTheme.surface)
                        }
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinguaTheme.surface)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LinguaTheme.border, lineWidth: 1)
            }
            .shadow(
                color: LinguaTheme.cardShadow(for: colorScheme),
                radius: colorScheme == .light ? 12 : 0,
                y: colorScheme == .light ? 4 : 0
            )
    }
}

struct LinguaSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

struct LinguaStatusChip: View {
    enum Tone {
        case neutral
        case accent
        case success
        case warning
        case danger

        var color: Color {
            switch self {
            case .neutral: LinguaTheme.secondaryText
            case .accent: LinguaTheme.accent
            case .success: LinguaTheme.success
            case .warning: LinguaTheme.warning
            case .danger: LinguaTheme.danger
            }
        }
    }

    let title: String
    var systemImage: String?
    var tone: Tone = .neutral

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tone.color.opacity(0.13), in: Capsule())
    }
}

struct LinguaProgressBar: View {
    let value: Double
    var tint: Color = LinguaTheme.accent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinguaTheme.progressTrack)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(value.formatted(.percent.precision(.fractionLength(0)))))
    }
}

struct LinguaMediaPlaceholder: View {
    var systemImage: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    LinguaTheme.accent.opacity(0.28),
                    LinguaTheme.backgroundRaised
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LinguaTheme.primaryText.opacity(0.72))
        }
    }
}

struct LinguaFocusableCardStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    /// Match YouTube TV focus language: a clear scale-up plus a single accent rim.
    private let focusedScale: CGFloat = 1.07

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? focusedScale : configuration.isPressed ? 0.98 : 1)
            .shadow(
                color: isFocused ? LinguaTheme.accent.opacity(0.55) : .clear,
                radius: isFocused ? 26 : 0,
                y: isFocused ? 10 : 0
            )
            .overlay {
                RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous)
                    .stroke(
                        isFocused ? LinguaTheme.accent : Color.clear,
                        lineWidth: isFocused ? 3.5 : 0
                    )
            }
            .zIndex(isFocused ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func linguaPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinguaScreenBackground())
            .foregroundStyle(LinguaTheme.primaryText)
            .tint(LinguaTheme.accent)
    }

    func linguaContentWidth() -> some View {
        frame(maxWidth: LinguaTheme.contentMaxWidth)
            .frame(maxWidth: .infinity)
    }
}
