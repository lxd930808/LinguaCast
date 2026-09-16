import SwiftData
import SwiftUI
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(PipelineRunner.self) private var runner
    @Query(sort: \PodcastSubscription.updatedAt, order: .reverse) private var podcastSubscriptions: [PodcastSubscription]
    @Query(sort: \YTChannelRecord.updatedAt, order: .reverse) private var youtubeChannels: [YTChannelRecord]

    @Binding var selectedTab: AppTab
    @State private var selectedSource: SubscriptionSource = .podcast
    @State private var subscriptionInput = ""
    @State private var displayName = ""
    @State private var localService = YTLocalService()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var presentedSheet: SubscriptionSheet?

    init(selectedTab: Binding<AppTab> = .constant(.subscriptions)) {
        _selectedTab = selectedTab
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                let readiness = ConfigurationReadiness(configuration: settings.configuration)
                if !readiness.summary.isComplete {
                    LinguaCard {
                        LinguaSectionHeader(
                            title: L10n.string("subscriptions.configuration_check", fallback: "Configuration check")
                        )
                        Divider()
                        SetupChecklistView(readiness: readiness) {
                            selectedTab = .settings
                        }
                    }
                }

                subscriptionSummary

                if let errorMessage {
                    LinguaCard {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LinguaTheme.danger)
                    }
                }
                if let statusMessage {
                    LinguaCard {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(LinguaTheme.success)
                    }
                }

                #if os(tvOS)
                HStack(alignment: .top, spacing: 28) {
                    selectedSubscriptionSection
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .focusSection()
                    tvOSActions
                        .frame(width: 560)
                        .focusSection()
                }
                #else
                addSubscriptionButton
                selectedSubscriptionSection
                #endif
            }
            .linguaContentWidth()
        }
        .linguaPage()
        .accessibilityIdentifier("screen.subscriptions")
        .navigationTitle(L10n.string("subscriptions.subscriptions", fallback: "Subscriptions"))
        .toolbar {
            #if os(tvOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    presentedSheet = .mobileSetup
                } label: {
                    Label(L10n.string("common.scan_code_with_mobile_phone", fallback: "Scan code with mobile phone"), systemImage: "qrcode")
                }
            }
            #endif
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .add:
                addSubscriptionSheet
            case .mobileSetup:
                MobileSetupView()
            }
        }
    }

    private var subscriptionSummary: some View {
        LinguaCard {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("subscriptions.subscriptions", fallback: "Subscriptions"))
                        .font(.title2.bold())
                    Text("\(podcastSubscriptions.count + youtubeChannels.count)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(LinguaTheme.accent)
                }
                Spacer()
                Image(systemName: selectedSource.icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(LinguaTheme.accent)
                    .padding(16)
                    .background(LinguaTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
            }

            Picker(L10n.string("common.source", fallback: "Source"), selection: $selectedSource) {
                ForEach(SubscriptionSource.allCases, id: \.self) { source in
                    Label(source.title, systemImage: source.icon)
                        .tag(source)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var addSubscriptionButton: some View {
        Button {
            presentedSheet = .add
        } label: {
            Label(L10n.string("common.add_subscription", fallback: "Add subscription"), systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(LinguaTheme.accent)
        .accessibilityIdentifier("subscriptions.add")
    }

    @ViewBuilder
    private var selectedSubscriptionSection: some View {
        switch selectedSource {
        case .podcast:
            PodcastSubscriptionsSection(
                subscriptions: visiblePodcastSubscriptions,
                onDelete: deletePodcastSubscription
            )
        case .youtube:
            YouTubeSubscriptionsSection(
                channels: visibleYouTubeChannels,
                isLoading: isLoading,
                onDelete: deleteYouTubeChannel
            )
        }
    }

    #if os(tvOS)
    private var tvOSActions: some View {
        Button {
            presentedSheet = .mobileSetup
        } label: {
            LinguaCard {
                HStack(spacing: 20) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 48, weight: .medium))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("common.scan_code_with_mobile_phone", fallback: "Scan code with mobile phone"))
                            .font(.title3.bold())
                        Text(
                            L10n.string(
                                "mobile_setup.scan_instructions",
                                fallback: "Scan with the iPhone camera, then configure APIs, Podcast subscriptions, or YouTube channels in Safari."
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(LinguaFocusableCardStyle())
        .accessibilityIdentifier("subscriptions.mobile-setup")
    }
    #endif

    private var addSubscriptionSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker(L10n.string("common.source", fallback: "Source"), selection: $selectedSource) {
                        ForEach(SubscriptionSource.allCases, id: \.self) { source in
                            Label(source.title, systemImage: source.icon)
                                .tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    LinguaCard {
                        Text(sourceInputHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField(sourceInputPlaceholder, text: $subscriptionInput)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #if os(iOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        TextField(
                            L10n.string("common.display_name_can_be_left_blank", fallback: "Display name, can be left blank"),
                            text: $displayName
                        )
                        #if os(iOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                    }

                    Button {
                        Task { await addSubscription() }
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView()
                            } else {
                                Label(L10n.string("common.add", fallback: "Add"), systemImage: "plus")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LinguaTheme.accent)
                    .disabled(subscriptionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LinguaTheme.danger)
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .linguaPage()
            .navigationTitle(L10n.string("common.add_subscription", fallback: "Add subscription"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close", fallback: "Close")) {
                        presentedSheet = nil
                    }
                }
            }
        }
        .accessibilityIdentifier("screen.add-subscription")
    }

    private func addSubscription() async {
        let input = subscriptionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        if SubscriptionSource.detect(input) == .youtube {
            await addYouTube(input: input, displayName: name)
        } else {
            await addPodcast(input: input, displayName: name)
        }
    }

    private func addPodcast(input: String, displayName: String) async {
        isLoading = true
        defer { isLoading = false }
        let subscription = PodcastSubscription(
            showURL: input,
            displayName: displayName.isEmpty ? input : displayName
        )
        if let url = URL(string: input),
           PodcastSubscriptionURLInspector.isUnsupportedAppleChannel(url) {
            subscription.lastError = PodcastFeedError.unsupportedAppleChannel.localizedDescription
        }
        modelContext.insert(subscription)
        try? modelContext.save()
        CloudSyncCoordinator.shared.upsertPodcast(subscription)
        await runner.refresh(
            subscription: subscription,
            context: modelContext,
            mode: .recent(limit: 50)
        )
        selectedSource = .podcast
        errorMessage = subscription.lastError
        statusMessage = if subscription.lastError == nil {
            L10n.string(
                "subscriptions.podcast_added_latest_fetched",
                fallback: "Podcast subscription added. The latest 50 episodes were fetched."
            )
        } else {
            L10n.string(
                "mobile_setup.podcast_subscription_added",
                fallback: "Podcast subscription added"
            )
        }
        clearAddForm()
        presentedSheet = nil
    }

    private func addYouTube(input: String, displayName: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let channel = try await localService.addChannel(
                input: input,
                displayName: displayName.isEmpty ? nil : displayName,
                configuration: settings.configuration,
                context: modelContext
            )
            await localService.refreshChannel(
                channel,
                configuration: settings.configuration,
                context: modelContext
            )
            selectedSource = .youtube
            errorMessage = channel.lastError
            statusMessage = L10n.string("subscriptions.youtube_channel_has_been_added", fallback: "YouTube Channel has been added.")
            clearAddForm()
            presentedSheet = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private func clearAddForm() {
        subscriptionInput = ""
        displayName = ""
    }

    private var sourceInputHint: String {
        switch selectedSource {
        case .podcast:
            return L10n.string("subscriptions.supports_apple_podcasts_individual_program_links_or_standard_rss", fallback: "Supports Apple Podcasts individual program links or standard RSS addresses.")
        case .youtube:
            return L10n.string("youtube.channel_input_help", fallback: "Supports YouTube channel URLs, channel IDs, RSS URLs, or @handles.")
        }
    }

    private var sourceInputPlaceholder: String {
        switch selectedSource {
        case .podcast:
            return L10n.string("subscriptions.apple_podcasts_program_link_or_rss_address", fallback: "Apple Podcasts program link or RSS address")
        case .youtube:
            return L10n.string("youtube.channel_input_short", fallback: "YouTube URL, channel ID, or @handle")
        }
    }

    private func deletePodcastSubscription(_ subscription: PodcastSubscription) {
        CloudSyncCoordinator.shared.deletePodcast(subscription)
        modelContext.delete(subscription)
        try? modelContext.save()
    }

    private func deleteYouTubeChannel(_ channel: YTChannelRecord) {
        do {
            try localService.deleteChannel(channel, context: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var visiblePodcastSubscriptions: [PodcastSubscription] {
        podcastSubscriptions
    }

    private var visibleYouTubeChannels: [YTChannelRecord] {
        youtubeChannels
    }

}

private enum SubscriptionSheet: String, Identifiable {
    case add
    case mobileSetup

    var id: String { rawValue }
}

private enum SubscriptionSource: CaseIterable {
    case podcast
    case youtube

    var title: String {
        switch self {
        case .podcast: L10n.string("common.podcast", fallback: "Podcast")
        case .youtube: L10n.string("common.youtube", fallback: "YouTube")
        }
    }

    var icon: String {
        switch self {
        case .podcast: "dot.radiowaves.left.and.right"
        case .youtube: "play.rectangle"
        }
    }

    static func detect(_ value: String) -> SubscriptionSource {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("@")
            || normalized.hasPrefix("uc")
            || normalized.contains("youtube.com")
            || normalized.contains("youtu.be") {
            return .youtube
        }
        return .podcast
    }
}

private struct PodcastSubscriptionsSection: View {
    var subscriptions: [PodcastSubscription]
    var onDelete: (PodcastSubscription) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinguaSectionHeader(
                title: L10n.string("common.podcast", fallback: "Podcast")
            )
            if subscriptions.isEmpty {
                LinguaCard {
                    LinguaEmptyState(
                        L10n.string("common.no_podcast_subscriptions_yet", fallback: "No Podcast subscriptions yet"),
                        systemImage: "dot.radiowaves.left.and.right",
                        kind: .guidance
                    )
                }
            } else {
                ForEach(subscriptions) { subscription in
                    LinguaCard {
                        PodcastSubscriptionRow(subscription: subscription)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(subscription)
                        } label: {
                            Label(L10n.string("common.delete", fallback: "Delete"), systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

private struct PodcastSubscriptionRow: View {
    var subscription: PodcastSubscription

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SubscriptionTitle(
                title: subscription.displayName,
                subtitle: subscription.showURL,
                icon: "dot.radiowaves.left.and.right"
            )
            SubscriptionEnabledStatus(isEnabled: subscription.isEnabled)
            if let error = subscription.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
            }
            if let checked = subscription.lastCheckedAt {
                Label {
                    Text(checked, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct YouTubeSubscriptionsSection: View {
    var channels: [YTChannelRecord]
    var isLoading: Bool
    var onDelete: (YTChannelRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinguaSectionHeader(
                title: L10n.string("common.youtube", fallback: "YouTube")
            )
            if isLoading && channels.isEmpty {
                LinguaCard {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if channels.isEmpty {
                LinguaCard {
                    LinguaEmptyState(
                        L10n.string("common.there_is_no_youtube_channel_yet", fallback: "There is no YouTube channel yet"),
                        systemImage: "play.rectangle",
                        kind: .guidance
                    )
                }
            } else {
                ForEach(channels) { channel in
                    LinguaCard {
                        YouTubeSubscriptionRow(channel: channel)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(channel)
                        } label: {
                            Label(L10n.string("common.delete", fallback: "Delete"), systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

private struct YouTubeSubscriptionRow: View {
    var channel: YTChannelRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SubscriptionTitle(
                title: channel.displayName,
                subtitle: channel.url,
                icon: "play.rectangle"
            )
            SubscriptionEnabledStatus(isEnabled: channel.isEnabled)
            if let error = channel.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
            }
            HStack {
                Label(L10n.plural("youtube.video_count", fallback: "%lld videos", count: channel.videoCount), systemImage: "play.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let checked = channel.lastCheckedAt {
                    Text(checked, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SubscriptionTitle: View {
    var title: String
    var subtitle: String
    var icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct SubscriptionEnabledStatus: View {
    let isEnabled: Bool

    var body: some View {
        Label(
            isEnabled ? L10n.string("common.on", fallback: "On") : L10n.string("common.off", fallback: "Off"),
            systemImage: isEnabled ? "checkmark.circle.fill" : "pause.circle"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(isEnabled ? LinguaTheme.success : LinguaTheme.secondaryText)
    }
}
