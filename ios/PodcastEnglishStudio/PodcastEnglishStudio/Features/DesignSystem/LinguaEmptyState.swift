import SwiftUI

/// Shared informational/error presentation; actions belong to the owning screen.
struct LinguaEmptyState: View {
    enum Kind { case information, guidance, failure }
    let title: String
    let systemImage: String
    var description: Text? = nil
    var kind: Kind = .information

    init(_ title: String, systemImage: String, description: Text? = nil, kind: Kind = .information) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.kind = kind
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(kind == .failure ? LinguaTheme.danger : LinguaTheme.tertiaryText)
            Text(title)
                .font(titleFont)
                .foregroundStyle(LinguaTheme.primaryText)
                .multilineTextAlignment(.center)
            if let description {
                description
                    .font(descriptionFont)
                    .foregroundStyle(LinguaTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if kind == .failure {
                Text(L10n.string("empty.return_and_retry", fallback: "Return to the previous page and try again."))
                    .font(descriptionFont)
                    .foregroundStyle(LinguaTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        #if os(tvOS)
        .padding(18)
        .frame(maxWidth: 600)
        .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        #endif
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        48
        #else
        34
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .title2.bold()
        #else
        .system(size: 17, weight: .bold)
        #endif
    }
    private var descriptionFont: Font {
        #if os(tvOS)
        .title3
        #else
        .system(size: 12)
        #endif
    }
}
