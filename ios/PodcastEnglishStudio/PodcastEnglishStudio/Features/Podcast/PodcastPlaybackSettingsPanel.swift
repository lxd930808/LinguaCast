import SwiftUI
import SwiftData
import DomainModels
import CloudSyncKit
import PodcastEnglishStudioCore

#if os(iOS)
struct PodcastPlaybackSettingsPanel: View {
    let episode: EpisodeRecord
    @Binding var showChinese: Bool
    @Binding var playbackRate: Float
    @Bindable var chinesePlayer: EpisodeChinesePlayback
    let canSelectChinese: Bool
    let onSelectRhythm: (Bool) -> Void
    let onRegenerate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PlaybackSettingsSection(title: L10n.string("episode_detail.play", fallback: "Play")) {
                        PlaybackSettingsRow(title: L10n.string("ytvideo_player.playback_speed", fallback: "Playback speed")) {
                            Picker(L10n.string("episode_detail.speed", fallback: "speed"), selection: $playbackRate) {
                                ForEach([Float(0.75), 1, 1.25], id: \.self) { rate in
                                    Text(verbatim: "\(rate.formatted())×").tag(rate)
                                }
                            }.labelsHidden().pickerStyle(.menu)
                                .accessibilityIdentifier("player.settings.speed")
                        }
                        Divider()
                        PlaybackSettingsRow(title: L10n.string("settings.subtitles", fallback: "Subtitles")) {
                            Picker(L10n.string("settings.subtitles", fallback: "Subtitles"), selection: $showChinese) {
                                Text(L10n.string("subtitles.bilingual", fallback: "Bilingual")).tag(true)
                                Text(L10n.string("subtitles.english_only", fallback: "English Only")).tag(false)
                            }.labelsHidden().pickerStyle(.menu)
                                .accessibilityIdentifier("player.settings.subtitles")
                        }
                        Divider()
                        PlaybackSubtitleSettingsLink()
                    }
                    PlaybackSettingsSection(title: L10n.string("playback.group.chinese", fallback: "Chinese Audio")) {
                        PlaybackSegmentedControl(
                            selection: chinesePlayer.rhythm == .natural,
                            firstTitle: L10n.string("tts.rhythm_current", fallback: "Current rhythm"),
                            secondTitle: L10n.string("tts.rhythm_natural", fallback: "Natural rhythm"),
                            firstIdentifier: "player.rhythm-current", secondIdentifier: "player.rhythm-natural",
                            onSelect: onSelectRhythm
                        )
                        .disabled(!canSelectChinese)
                        Menu {
                            Button(L10n.string("tts.prepare_segment", fallback: "Prepare current segment")) { chinesePlayer.prepareOffline(wholeEpisode: false) }
                            Button(L10n.string("tts.prepare_episode", fallback: "Prepare episode (up to 256 MB)")) { chinesePlayer.prepareOffline(wholeEpisode: true) }
                            Button(L10n.string("tts.cancel_preparation", fallback: "Cancel preparation")) { chinesePlayer.cancelPreparation() }
                            Button(L10n.string("tts.clear_prepared", fallback: "Clear prepared audio")) { chinesePlayer.clearPreparedAudio() }
                        } label: {
                            PlaybackSettingsRow(title: L10n.string("tts.prepare_audio", fallback: "Prepare Chinese audio")) {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                        }
                        .disabled(!chinesePlayer.isSelected)
                        .accessibilityIdentifier("player.prepare-chinese")
                        if !chinesePlayer.preparationProgress.isEmpty {
                            Text(chinesePlayer.preparationProgress).font(.caption)
                        }
                        Text(L10n.format("tts.prepared_storage", fallback: "%d MB / 256 MB · Prepare before locking the screen", chinesePlayer.preparedBytes / 1024 / 1024))
                            .font(.caption).foregroundStyle(LinguaTheme.secondaryText)
                    }
                    PlaybackSettingsSection(title: L10n.string("playback.group.episode", fallback: "This Episode")) {
                        if episode.catalogOrigin == .assistant {
                            AssistantPinHomeToolbarButton(isAssistantOrigin: true, isPinned: episode.pinnedToHome) {
                                AssistantPinHomeToolbarButton.togglePin(on: episode, context: context)
                            }.frame(minHeight: 48)
                        }
                        if let raw = episode.episodeWebsiteURL, let url = URL(string: raw) {
                            Link(L10n.string("podcast.open_episode_website", fallback: "Open episode website"), destination: url)
                                .frame(minHeight: 48)
                                .accessibilityIdentifier("podcast.open-episode-website")
                        }
                        if PodcastClearAndRegeneratePolicy.isAvailable(status: episode.status) {
                            Button(role: .destructive) {
                                dismiss()
                                onRegenerate()
                            } label: {
                                Text(L10n.string("episodes.clear_and_regenerate", fallback: "Clear and regenerate"))
                                    .foregroundStyle(LinguaTheme.danger)
                                    .frame(minHeight: 48)
                            }.accessibilityIdentifier("podcast.clear-and-regenerate")
                        }
                    }
                }
                .padding(20)
            }
            .linguaPage()
            .navigationTitle(L10n.string("playback.settings.title", fallback: "Playback Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.close", fallback: "Close")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("player.settings.close")
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("player.settings.podcast-panel")
    }
}
#endif
