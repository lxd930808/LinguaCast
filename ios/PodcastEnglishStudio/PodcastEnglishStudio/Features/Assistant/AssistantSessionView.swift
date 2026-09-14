import SwiftUI
import SwiftData
import CloudSyncKit
import DomainModels

#if os(iOS)
private enum AssistantSessionPane: Hashable {
    case conversation
    case sources
}

private enum AssistantPlaybackRoute: Hashable, Identifiable {
    case podcast(episodeID: String)
    case youtube(videoID: String)

    var id: String {
        switch self {
        case .podcast(let episodeID): "podcast-\(episodeID)"
        case .youtube(let videoID): "youtube-\(videoID)"
        }
    }
}

struct AssistantSessionView: View {
    let sessionId: String
    var model: AssistantViewModel?
    var isReadOnly = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(PipelineRunner.self) private var runner
    @FocusState private var composerFocused: Bool
    @State private var pane: AssistantSessionPane = .conversation
    @State private var pendingSource: AssistantSearchResult?
    @State private var confirmPrepare = false
    @State private var markdownCache = AssistantMarkdownCache()
    @State private var playbackRoute: AssistantPlaybackRoute?
    @State private var isPreparingPlayback = false
    @State private var playbackError: String?
    @State private var youtubeService = YTLocalService()

    var body: some View {
        VStack(spacing: 0) {
            panePicker
            if pane == .conversation {
                conversationPane
            } else {
                sourcesPane
            }
        }
        .background(LinguaTheme.background)
        .overlay(alignment: .topLeading) {
            #if DEBUG
            AssistantFrameDropProbe()
            #endif
        }
        .overlay {
            if isPreparingPlayback {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("assistant.playback.preparing")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if pane == .conversation && !isEffectivelyReadOnly {
                AssistantComposerView(model: model, composerFocused: $composerFocused)
            }
        }
        .navigationTitle(model?.snapshot?.title ?? L10n.string("navigation.assistant", fallback: "Assistant"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $playbackRoute) { route in
            switch route {
            case .podcast(let episodeID):
                EpisodeDetailRouteView(episodeID: episodeID)
            case .youtube(let videoID):
                YTVideoPlayerRouteView(videoID: videoID)
            }
        }
        .task {
            await model?.openSession(sessionId)
            if isEmptyConversation && !isEffectivelyReadOnly {
                composerFocused = true
            }
            await consumePendingPlayback()
        }
        .onChange(of: sessionId) { _, _ in
            pane = .conversation
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model?.handleBackground()
            } else if phase == .active {
                Task { await model?.handleForeground() }
            }
        }
        .confirmationDialog(
            L10n.string("assistant.prepare_confirm_title", fallback: "Start deep research?"),
            isPresented: $confirmPrepare,
            titleVisibility: .visible
        ) {
            Button(L10n.string("assistant.prepare_confirm_action", fallback: "Transcribe and translate")) {
                if let pendingSource, let snapshot = model?.snapshot {
                    Task {
                        await model?.bindSource(
                            pendingSource.searchResultId,
                            targetLanguage: snapshot.targetLanguage ?? "zh-Hans",
                            quality: snapshot.translationQuality ?? .quality
                        )
                    }
                }
            }
            Button(L10n.string("assistant.dismiss", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "assistant.prepare_confirm_body",
                fallback: "This uses the cloud transcription and translation service. It does not download media on this device."
            ))
        }
        .alert(
            L10n.string("assistant.playback.error_title", fallback: "Could not open player"),
            isPresented: Binding(
                get: { playbackError != nil },
                set: { if !$0 { playbackError = nil } }
            )
        ) {
            Button(L10n.string("assistant.dismiss", fallback: "Cancel"), role: .cancel) {
                playbackError = nil
            }
        } message: {
            Text(playbackError ?? "")
        }
    }

    private func playSource(_ source: AssistantSearchResult) async {
        guard let binding = model?.snapshot?.binding,
              binding.searchResultId == source.searchResultId
        else {
            playbackError = AssistantPlaybackPrepareError.missingJob.localizedDescription
            return
        }
        await openPreparedPlayback(binding: binding, source: source, startMs: nil)
    }

    private func consumePendingPlayback() async {
        guard let link = PlaybackDeepLinkCoordinator.shared.consumePending() else { return }
        guard let binding = model?.snapshot?.binding,
              let source = model?.snapshot?.searchResults.first(where: {
                  $0.searchResultId == binding.searchResultId
              })
        else { return }
        guard binding.contentKey == link.contentKey else { return }
        await openPreparedPlayback(binding: binding, source: source, startMs: link.startMs)
    }

    private func playCitation(_ target: AssistantPlayerTarget) async {
        _ = PlaybackDeepLinkCoordinator.shared.handle(target: target)
        await consumePendingPlayback()
    }

    private func openPreparedPlayback(
        binding: AssistantContentBinding,
        source: AssistantSearchResult,
        startMs: Int?
    ) async {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        do {
            let preparer = AssistantPlaybackPreparer(runner: runner, youtube: youtubeService)
            let prepared = try await preparer.prepare(
                binding: binding,
                source: source,
                configuration: settings.configuration,
                context: modelContext
            )
            if let startMs {
                applyStartPosition(prepared, startMs: startMs)
            }
            switch prepared {
            case .podcast(let episodeID):
                playbackRoute = .podcast(episodeID: episodeID)
            case .youtube(let videoID):
                playbackRoute = .youtube(videoID: videoID)
            }
        } catch {
            playbackError = error.localizedDescription
        }
    }

    private func applyStartPosition(_ prepared: AssistantPreparedPlayback, startMs: Int) {
        let seconds = max(0, Double(startMs) / 1000)
        switch prepared {
        case .podcast(let episodeID):
            let episodes = (try? modelContext.fetch(FetchDescriptor<EpisodeRecord>())) ?? []
            if let episode = episodes.first(where: { $0.id == episodeID }) {
                episode.playbackPositionSeconds = seconds
                episode.playbackUpdatedAt = Date()
                try? modelContext.save()
            }
        case .youtube(let videoID):
            let videos = (try? modelContext.fetch(FetchDescriptor<YTVideoRecord>())) ?? []
            if let video = videos.first(where: { $0.id == videoID }) {
                video.playbackPositionSeconds = seconds
                video.playbackUpdatedAt = Date()
                try? modelContext.save()
            }
        }
    }

    private var panePicker: some View {
        Picker(L10n.string("assistant.tab.conversation", fallback: "Conversation"), selection: $pane) {
            Text(L10n.string("assistant.tab.conversation", fallback: "Conversation"))
                .tag(AssistantSessionPane.conversation)
            Text(L10n.string("assistant.tab.sources", fallback: "Sources"))
                .tag(AssistantSessionPane.sources)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("assistant.pane")
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var conversationPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model?.snapshot == nil && model?.errorMessage == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if isEmptyConversation {
                        if isEffectivelyReadOnly {
                            Text(L10n.string(
                                "assistant.legacy.banner",
                                fallback: "This session is from an earlier assistant version and is read-only."
                            ))
                            .font(.caption)
                            .foregroundStyle(LinguaTheme.secondaryText)
                            .accessibilityIdentifier("assistant.legacy.banner")
                            .padding(.top, 24)
                        }
                        emptyState
                    } else {
                        if isEffectivelyReadOnly {
                            Text(L10n.string(
                                "assistant.legacy.banner",
                                fallback: "This session is from an earlier assistant version and is read-only."
                            ))
                            .font(.caption)
                            .foregroundStyle(LinguaTheme.secondaryText)
                            .accessibilityIdentifier("assistant.legacy.banner")
                        }
                        AssistantConversationView(
                            model: model,
                            cache: markdownCache,
                            onPlayCitation: { target in
                                Task { await playCitation(target) }
                            }
                        )
                        AssistantStreamTailView(model: model)
                        AssistantBindingCardView(model: model)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("assistant.bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            // Keep the stream anchored to the bottom without interrupting manual scrolling.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollToken) { _, _ in
                if isWorking {
                    proxy.scrollTo("assistant.bottom", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo("assistant.bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var sourcesPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model?.snapshot == nil && model?.errorMessage == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else {
                    AssistantSourcesView(
                        model: model,
                        mutationsEnabled: !isEffectivelyReadOnly,
                        onSelectSource: { source in
                            guard !isEffectivelyReadOnly else { return }
                            pendingSource = source
                            confirmPrepare = true
                        },
                        onPlaySource: { source in
                            Task { await playSource(source) }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(LinguaTheme.accent)
            Text(L10n.string("assistant.greeting", fallback: "What would you like to research?"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(LinguaTheme.primaryText)
            Text(L10n.string(
                "assistant.greeting_body",
                fallback: "Ask a question or describe a topic. I'll search YouTube and Apple Podcasts."
            ))
            .font(.subheadline)
            .foregroundStyle(LinguaTheme.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
        .padding(.horizontal, 24)
    }

    private var pendingUserBubbleText: String? {
        guard let pending = model?.pendingUserText, !pending.isEmpty else { return nil }
        let alreadyShown = model?.snapshot?.messages.contains { $0.role == "user" && $0.markdown == pending } == true
        return alreadyShown ? nil : pending
    }

    private var isEmptyConversation: Bool {
        (model?.snapshot?.messages.isEmpty ?? true)
            && pendingUserBubbleText == nil
            && model?.snapshot?.report == nil
            && model?.errorMessage == nil
            && !isWorking
    }

    private var isWorking: Bool {
        model?.isStreaming == true || model?.snapshot?.activeTurn?.status.isTerminal == false
    }

    private var isEffectivelyReadOnly: Bool {
        isReadOnly || model?.isLegacyReadOnly == true
    }

    /// Scroll only for discrete conversation events; defaultScrollAnchor handles streaming growth.
    private var scrollToken: String {
        [
            model?.snapshot?.messages.last?.messageId ?? "",
            pendingUserBubbleText ?? "",
            isWorking ? "1" : "0",
            model?.snapshot?.report?.title ?? ""
        ].joined(separator: "|")
    }
}

/// Renders the persisted conversation (messages, pending bubble, report prose).
/// Reads only snapshot/pendingUserText so streaming drafts and composer typing
/// never invalidate the (expensive) message list. Recommended sources live on
/// the Sources pane so later rounds cannot overwrite them.
private struct AssistantConversationView: View {
    let model: AssistantViewModel?
    let cache: AssistantMarkdownCache
    var onPlayCitation: ((AssistantPlayerTarget) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Equatable rows preserve unchanged markdown when conversation state changes.
        ForEach(model?.snapshot?.messages ?? [], id: \.messageId) { message in
            AssistantMessageRowView(message: message, cache: cache, onPlayCitation: onPlayCitation)
        }
        if let pending = pendingUserBubbleText {
            userBubble(pending)
        }
        if let report = model?.snapshot?.report, !isWorking, !hasAssistantMessage {
            reportCard(report)
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .foregroundStyle(LinguaTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(userBubbleFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    private func reportCard(_ report: AssistantReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title)
                .font(.headline)
            markdownBody(
                report.markdown?.isEmpty == false ? (report.markdown ?? report.summary) : report.summary,
                cacheKey: "report:\(report.title)"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }

    private func markdownBody(_ raw: String, cacheKey: String? = nil) -> some View {
        Text(cache.attributed(raw, key: cacheKey))
            .font(.body)
            .foregroundStyle(LinguaTheme.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pendingUserBubbleText: String? {
        guard let pending = model?.pendingUserText, !pending.isEmpty else { return nil }
        let alreadyShown = model?.snapshot?.messages.contains { $0.role == "user" && $0.markdown == pending } == true
        return alreadyShown ? nil : pending
    }

    private var hasAssistantMessage: Bool {
        model?.snapshot?.messages.contains { $0.role == "assistant" } == true
    }

    private var isWorking: Bool {
        model?.isStreaming == true || model?.snapshot?.activeTurn?.status.isTerminal == false
    }

    private var userBubbleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(white: 0.93)
    }
}

private struct AssistantSourcesView: View {
    let model: AssistantViewModel?
    var mutationsEnabled: Bool = true
    let onSelectSource: (AssistantSearchResult) -> Void
    var onPlaySource: ((AssistantSearchResult) -> Void)? = nil
    @State private var expandedShowId: String?

    var body: some View {
        let groups = model?.snapshot?.resolvedSourceGroups ?? []
        let results = model?.snapshot?.searchResults ?? []
        if let warning = searchStatusWarning {
            Text(warning)
                .font(.caption)
                .foregroundStyle(LinguaTheme.secondaryText)
        }
        if groups.isEmpty {
            VStack(spacing: 8) {
                Text(L10n.string("assistant.sources.empty", fallback: "No sources yet"))
                    .font(.body)
                    .foregroundStyle(LinguaTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72)
                    .accessibilityIdentifier("assistant.sources.empty")
            }
        } else {
            ForEach(groups, id: \.reportId) { group in
                sourceGroup(group, results: results)
            }
        }
    }

    @ViewBuilder
    private func sourceGroup(_ group: AssistantSourceGroup, results: [AssistantSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                if let createdAt = group.createdAt {
                    Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(LinguaTheme.secondaryText)
                }
            }
            ForEach(group.sources, id: \.searchResultId) { source in
                if let result = results.first(where: { $0.searchResultId == source.searchResultId }) {
                    AssistantSearchResultCard(
                        result: result,
                        binding: model?.snapshot?.binding,
                        mutationsEnabled: mutationsEnabled,
                        onSelect: onSelectSource,
                        onPlay: onPlaySource,
                        onViewEpisodes: { show in
                            expandedShowId = expandedShowId == show.searchResultId ? nil : show.searchResultId
                        }
                    )
                    if expandedShowId == result.searchResultId {
                        ForEach(episodes(for: result, in: results), id: \.searchResultId) { episode in
                            AssistantSearchResultCard(
                                result: episode,
                                binding: model?.snapshot?.binding,
                                mutationsEnabled: mutationsEnabled,
                                onSelect: onSelectSource,
                                onPlay: onPlaySource
                            )
                                .padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("assistant.sources.group.\(group.reportId)")
    }

    private func episodes(for show: AssistantSearchResult, in results: [AssistantSearchResult]) -> [AssistantSearchResult] {
        results.filter { candidate in
            candidate.sourceType == .podcastEpisode &&
                ((candidate.feedURL == show.feedURL && show.feedURL != nil) ||
                 (candidate.itunesId == show.itunesId && show.itunesId != nil))
        }
    }

    private var searchStatusWarning: String? {
        let statuses = (model?.snapshot?.searchRuns ?? []).flatMap { $0.providerStatus ?? [] }
        if statuses.contains(where: { $0.status == "partial" || $0.status == "unavailable" }) {
            return L10n.string("assistant.status.partial", fallback: "Some sources could not be searched. Showing the results that succeeded.")
        }
        if statuses.contains(where: { $0.status == "rate_limited" }) {
            return L10n.string("assistant.status.rate_limited", fallback: "A search source is rate-limited. Try again later.")
        }
        if statuses.contains(where: { $0.status == "misconfigured" }) {
            return L10n.string("assistant.status.misconfigured", fallback: "A search source is not configured.")
        }
        if (model?.snapshot?.searchRuns ?? []).contains(where: { $0.status == "empty" }) {
            return L10n.string("assistant.status.filtered_empty", fallback: "No results matched the current filters.")
        }
        return nil
    }
}

/// Equatable message row isolates history from streaming, typing and status updates.
private struct AssistantMessageRowView: View, Equatable {
    let message: AssistantMessage
    let cache: AssistantMarkdownCache
    var onPlayCitation: ((AssistantPlayerTarget) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
    }

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(message.markdown)
                    .font(.body)
                    .foregroundStyle(LinguaTheme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(userBubbleFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                markdownBody(message.markdown, cacheKey: message.messageId)
                if let citations = message.citations, !citations.isEmpty {
                    ForEach(citations, id: \.citationId) { citation in
                        Button {
                            onPlayCitation?(citation.playerTarget)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(timeCode(citation.startMs))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                Text(citation.quote)
                                    .font(.caption)
                                    .lineLimit(3)
                                    .foregroundStyle(LinguaTheme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("assistant.citation.\(citation.citationId)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 28)
        }
    }

    private func markdownBody(_ raw: String, cacheKey: String? = nil) -> some View {
        Text(cache.attributed(raw, key: cacheKey))
            .font(.body)
            .foregroundStyle(LinguaTheme.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userBubbleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(white: 0.93)
    }

    private func timeCode(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Renders the volatile tail of the conversation: streaming draft, thinking
/// indicator and errors. Isolated so the ~80ms streaming flushes only
/// re-render this small section instead of the whole transcript.
private struct AssistantStreamTailView: View {
    let model: AssistantViewModel?

    var body: some View {
        if let draft = model?.streamingDraft, !draft.isEmpty {
            Text(draft)
                .font(.body)
                .foregroundStyle(LinguaTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 28)
        }
        if isWorking {
            HStack(spacing: 10) {
                AssistantThinkingDots()
                Text(model?.activityLabel ?? L10n.string("assistant.thinking", fallback: "Thinking"))
                    .font(.subheadline)
                    .foregroundStyle(LinguaTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model?.activityLabel ?? L10n.string("assistant.thinking", fallback: "Thinking"))
            .id("assistant.thinking")
        }
        if let error = turnErrorText {
            errorRow(error)
        } else if let message = model?.errorMessage, !isWorking {
            errorRow(message)
        }
    }

    private var isWorking: Bool {
        model?.isStreaming == true || model?.snapshot?.activeTurn?.status.isTerminal == false
    }

    private var turnErrorText: String? {
        guard model?.snapshot?.activeTurn?.status == .failed else { return nil }
        return model?.snapshot?.activeTurn?.error?.message
    }

    private func errorRow(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(LinguaTheme.danger)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LinguaTheme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AssistantBindingCardView: View {
    let model: AssistantViewModel?

    var body: some View {
        if let binding = model?.snapshot?.binding {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("assistant.preparation", fallback: "Preparation"))
                    .font(.subheadline.weight(.semibold))
                Text(binding.stage ?? binding.status)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.secondaryText)
                LinguaProgressBar(value: binding.progress ?? 0)
            }
            .padding(12)
            .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Composer isolated from the transcript: every keystroke only re-renders
/// this bar, not the message list above it.
private struct AssistantComposerView: View {
    let model: AssistantViewModel?
    var composerFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    L10n.string("assistant.prompt_placeholder", fallback: "Ask or research a topic"),
                    text: Binding(
                        get: { model?.draft ?? "" },
                        set: { model?.draft = $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused(composerFocused)
                .accessibilityIdentifier("assistant.composer")
                .padding(.leading, 6)
                .padding(.vertical, 8)

                if isWorking {
                    Button {
                        Task { await model?.cancelActiveTurn() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .background(LinguaTheme.primaryText, in: Circle())
                    }
                    .accessibilityLabel(L10n.string("assistant.stop", fallback: "Stop"))
                    .accessibilityIdentifier("assistant.cancel")
                } else {
                    Button {
                        composerFocused.wrappedValue = false
                        Task {
                            let kind: AssistantTurnKind = model?.snapshot?.phase == .qaReady ? .qa : .research
                            await model?.submit(kind: kind)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .background(canSend ? LinguaTheme.primaryText : LinguaTheme.tertiaryText.opacity(0.45), in: Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(L10n.string("assistant.send", fallback: "Send"))
                    .accessibilityIdentifier("assistant.send")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(LinguaTheme.border.opacity(0.7), lineWidth: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(LinguaTheme.background.ignoresSafeArea())
    }

    private var isWorking: Bool {
        model?.isStreaming == true || model?.snapshot?.activeTurn?.status.isTerminal == false
    }

    private var canSend: Bool {
        !(model?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

private final class AssistantMarkdownCache {
    private var stored: [String: AttributedString] = [:]

    func attributed(_ raw: String, key: String?) -> AttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = key.map { "\($0):\(trimmed.hashValue)" } ?? trimmed
        if let cached = stored[cacheKey] { return cached }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        let parsed = (try? AttributedString(markdown: trimmed, options: options)) ?? AttributedString(trimmed)
        stored[cacheKey] = parsed
        return parsed
    }
}

#if DEBUG
/// DEBUG-only frame-drop probe. CADisplayLink counts frames whose vsync
/// interval exceeds ~1.9x the expected frame duration; a timer publishes a
/// summary every 0.5s so the display-link ticks themselves don't re-render
/// the view. Read `assistant.perf.frames` accessibilityValue after scripted
/// scrolls: "dropped=N,total=M".
private final class AssistantFrameDropCounter: NSObject, ObservableObject {
    @Published private(set) var summary = "dropped=0,total=0"
    private var displayLink: CADisplayLink?
    private var publishTimer: Timer?
    private var lastTimestamp: CFTimeInterval = 0
    private var dropped = 0
    private var total = 0

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        publishTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.summary = "dropped=\(self.dropped),total=\(self.total)"
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 {
            total += 1
            if link.timestamp - lastTimestamp > link.duration * 1.9 {
                dropped += 1
            }
        }
        lastTimestamp = link.timestamp
    }

    deinit {
        displayLink?.invalidate()
        publishTimer?.invalidate()
    }
}

private struct AssistantFrameDropProbe: View {
    @StateObject private var counter = AssistantFrameDropCounter()

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("assistant.perf.frames")
            .accessibilityValue(counter.summary)
            .onAppear { counter.start() }
    }
}
#endif

private struct AssistantThinkingDots: View {
    @State private var bouncing = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(LinguaTheme.secondaryText)
                    .frame(width: 7, height: 7)
                    .offset(y: bouncing ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.36)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: bouncing
                    )
            }
        }
        .onAppear { bouncing = true }
    }
}
#endif
