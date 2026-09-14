import SwiftData
import SwiftUI
import DomainModels
import CloudSyncKit

struct YTSubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings

    @State private var localService = YTLocalService()
    @State private var channels: [YTChannelRecord] = []
    @State private var channelURL = ""
    @State private var displayName = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingMobileSetup = false
    @State private var contentFilter = ContentFilterService()

    var body: some View {
        listContent
        #if os(tvOS)
        .navigationDestination(for: YTChannelNavigationRoute.self) { route in
            if let channel = channel(for: route.channelID) {
                YTChannelDetailView(channel: channel)
            } else {
                LinguaEmptyState(L10n.string("common.channel_does_not_exist", fallback: "Channel does not exist"), systemImage: "play.rectangle", kind: .failure)
            }
        }
        #endif
    }

    private var listContent: some View {
        List {
            Section(L10n.string("ytsubscriptions.add_channel", fallback: "Add channel")) {
                TextField(L10n.string("youtube.channel_input", fallback: "YouTube channel URL, RSS URL, channel ID, or @handle"), text: $channelURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField(L10n.string("common.display_name_can_be_left_blank", fallback: "Display name, can be left blank"), text: $displayName)
                Button {
                    Task { await addChannel() }
                } label: {
                    Label(L10n.string("common.add", fallback: "Add"), systemImage: "plus")
                }
                .disabled(channelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(LinguaTheme.danger)
                }
            }

            Section(L10n.string("ytsubscriptions.channels", fallback: "Channels")) {
                if isLoading && channels.isEmpty {
                    ProgressView()
                }
                if channels.isEmpty && !isLoading {
                    LinguaEmptyState(L10n.string("common.there_is_no_youtube_channel_yet", fallback: "There is no YouTube channel yet"), systemImage: "play.rectangle", kind: .guidance)
                }
                ForEach(visibleChannels) { channel in
                    #if os(tvOS)
                    NavigationLink(value: YTChannelNavigationRoute(channelID: channel.id)) {
                        YTChannelRow(channel: channel)
                    }
                    #else
                    NavigationLink {
                        YTChannelDetailView(channel: channel)
                    } label: {
                        YTChannelRow(channel: channel)
                    }
                    #endif
                }
                .onDelete { indexes in
                    deleteChannels(at: indexes)
                }
            }
        }
        .navigationTitle(L10n.string("common.youtube", fallback: "YouTube"))
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    YTAccountView()
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
            #else
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingMobileSetup = true
                } label: {
                    Label(L10n.string("common.scan_code_with_mobile_phone", fallback: "Scan code with mobile phone"), systemImage: "qrcode")
                }
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || channels.isEmpty)
            }
        }
        .refreshable {
            await refreshAll()
        }
        .sheet(isPresented: $showingMobileSetup) {
            MobileSetupView()
        }
        .task {
            contentFilter.update(configuration: settings.configuration)
            prefetchContentFilterVerdicts()
            refreshChannels()
        }
        .onChange(of: settings.configuration) { _, configuration in
            contentFilter.update(configuration: configuration)
            prefetchContentFilterVerdicts()
        }
        .onChange(of: channels.map(\.id)) { _, _ in
            prefetchContentFilterVerdicts()
        }
    }

    private var visibleChannels: [YTChannelRecord] {
        channels.filter {
            !contentFilter.isFilteredOut(id: $0.id, title: $0.displayName, channel: $0.displayName)
        }
    }

    private func prefetchContentFilterVerdicts() {
        contentFilter.prefetchAgentVerdicts(channels.map {
            ContentFilterService.Item(id: $0.id, title: $0.displayName, channel: $0.displayName)
        })
    }

    private func channel(for channelID: String) -> YTChannelRecord? {
        channels.first { $0.id == channelID }
    }

    private func addChannel() async {
        let url = channelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let channel = try await localService.addChannel(
                input: url,
                displayName: name.isEmpty ? nil : name,
                configuration: settings.configuration,
                context: modelContext
            )
            try reloadChannels()
            guard channels.contains(where: { $0.id == channel.id }) else {
                throw YTLocalServiceError.channelNotPersisted
            }
            channelURL = ""
            displayName = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteChannels(at indexes: IndexSet) {
        do {
            for index in indexes {
                try localService.deleteChannel(visibleChannels[index], context: modelContext)
            }
            try reloadChannels()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        for channel in channels where channel.isEnabled {
            await localService.refreshChannel(channel, configuration: settings.configuration, context: modelContext)
        }
        refreshChannels()
    }

    private func reloadChannels() throws {
        channels = try modelContext.fetch(FetchDescriptor<YTChannelRecord>())
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func refreshChannels() {
        do {
            try reloadChannels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if os(tvOS)
private struct YTChannelNavigationRoute: Hashable {
    var channelID: String
}
#endif

private struct YTChannelRow: View {
    var channel: YTChannelRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(channel.displayName)
                .font(.headline)
            Text(channel.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Label(L10n.plural("youtube.video_count", fallback: "%lld videos", count: channel.videoCount), systemImage: "play.rectangle")
                if let lastCheckedAt = channel.lastCheckedAt {
                    Text(lastCheckedAt, style: .date)
                }
                if let lastError = channel.lastError, !lastError.isEmpty {
                    Label(L10n.string("ytsubscriptions.there_is_an_error", fallback: "There is an error"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(LinguaTheme.danger)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
