import SwiftUI
import CloudSyncKit

#if os(iOS)
struct PlaybackSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LinguaTheme.secondaryText)
            LinguaCard(padding: 12) {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PlaybackSettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(LinguaTheme.primaryText)
            Spacer(minLength: 8)
            content()
                .font(.system(size: 15))
                .foregroundStyle(LinguaTheme.secondaryText)
        }
        .frame(minHeight: 48)
    }
}

struct PlaybackSubtitleSettingsLink: View {
    var body: some View {
        NavigationLink {
            PlaybackSubtitleSettingsScreen()
        } label: {
            PlaybackSettingsRow(title: L10n.string("playback.subtitle.presentation", fallback: "Subtitle Size and Order")) {
                Image(systemName: "chevron.right")
            }
        }
        .accessibilityIdentifier("player.settings.subtitle-presentation")
    }
}

struct PlaybackSubtitleSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            SubtitlePresentationSettingsSection(settings: settings)
        }
        .navigationTitle(L10n.string("playback.subtitle.presentation", fallback: "Subtitle Size and Order"))
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: settings.configuration.subtitlePresentation) { _, _ in
            settings.save()
        }
    }
}
/// Two mutually exclusive choices with explicit, accessible 44-point hit regions.
struct PlaybackSegmentedControl: View {
    let selection: Bool
    let firstTitle: String
    let secondTitle: String
    let firstIdentifier: String
    let secondIdentifier: String
    let onSelect: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(false, title: firstTitle, identifier: firstIdentifier)
            segment(true, title: secondTitle, identifier: secondIdentifier)
        }
        .padding(3)
        .background(LinguaTheme.surfaceElevated, in: Capsule())
    }

    private func segment(_ value: Bool, title: String, identifier: String) -> some View {
        Button { onSelect(value) } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selection == value ? Color.white : LinguaTheme.secondaryText)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selection == value ? LinguaTheme.accent : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(selection == value ? "selected" : "unselected")
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
#endif
