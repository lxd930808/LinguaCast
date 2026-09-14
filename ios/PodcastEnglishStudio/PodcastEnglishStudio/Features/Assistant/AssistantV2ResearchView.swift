import SwiftUI
import SwiftData
import CloudSyncKit
import DomainModels

#if os(iOS)
private enum AssistantV2ResearchPane: Hashable {
    case conversation
    case sources
    case memory
}

private enum AssistantV2PlaybackRoute: Hashable, Identifiable {
    case podcast(episodeID: String)
    case youtube(videoID: String)

    var id: String {
        switch self {
        case .podcast(let episodeID): "podcast-\(episodeID)"
        case .youtube(let videoID): "youtube-\(videoID)"
        }
    }
}

struct AssistantV2ResearchView: View {
    let researchId: String
    var model: AssistantV2ViewModel?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(PipelineRunner.self) private var runner
    @FocusState private var composerFocused: Bool
    @State private var pane: AssistantV2ResearchPane = .conversation
    @State private var pendingSource: AssistantV2DisplayedSource?
    @State private var confirmTranscribe = false
    @State private var markdownCache = AssistantV2MarkdownCache()
    @State private var youtubeService = YTLocalService()
    @State private var playbackRoute: AssistantV2PlaybackRoute?
    @State private var isPreparingPlayback = false
    @State private var playbackError: String?

    var body: some View {
        VStack(spacing: 0) {
            panePicker
            switch pane {
            case .conversation:
                conversationPane
            case .sources:
                sourcesPane
            case .memory:
                memoryPane
            }
        }
        .background(LinguaTheme.background)
        .overlay {
            if isPreparingPlayback {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("assistant.v2.playback.preparing")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if pane == .conversation {
                AssistantV2ComposerView(model: model, composerFocused: $composerFocused)
            }
        }
        .onChange(of: pane) { _, newPane in
            if newPane != .conversation { composerFocused = false }
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
            await model?.openResearch(researchId)
            if isEmptyConversation {
                composerFocused = true
            }
        }
        .onChange(of: researchId) { _, _ in
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
            L10n.string("assistant.v2.transcribe_confirm_title", fallback: "Start transcription?"),
            isPresented: $confirmTranscribe,
            titleVisibility: .visible
        ) {
            Button(L10n.string("assistant.v2.transcribe_confirm_action", fallback: "Transcribe and translate")) {
                if let pendingSource, let sourceId = pendingSource.transcribeSourceId {
                    Task {
                        await model?.confirmTranscription(
                            sourceId: sourceId,
                            targetLanguage: model?.snapshot?.targetLanguage ?? settings.configuration.translationTargetLanguage,
                            quality: model?.snapshot?.translationQuality
                                ?? CloudTranslationQuality(rawValue: settings.configuration.translationQualityMode)
                                ?? .quality
                        )
                    }
                }
            }
            Button(L10n.string("assistant.dismiss", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "assistant.v2.transcribe_confirm_body",
                fallback: "This starts a full cloud transcription and translation job. It does not download media on this device."
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

    /// Opens the player for a source whose transcription has finished — mirrors the V1 research
    /// assistant's "Play" button (`AssistantSessionView.playSource`), reusing the same install
    /// pipeline (`AssistantPlaybackPreparer`) via the V10 job id carried on the transcript job.
    private func playSource(_ source: AssistantV2DisplayedSource) async {
        guard !isPreparingPlayback else { return }
        guard let sourceId = source.transcribeSourceId,
              let job = model?.transcriptJobs[sourceId],
              job.status == .ready
        else { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        do {
            let preparer = AssistantPlaybackPreparer(runner: runner, youtube: youtubeService)
            let prepared = try await preparer.prepare(
                job: job,
                source: source,
                targetLanguage: model?.snapshot?.targetLanguage ?? settings.configuration.translationTargetLanguage,
                configuration: settings.configuration,
                context: modelContext
            )
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

    private var panePicker: some View {
        Picker(L10n.string("assistant.tab.conversation", fallback: "Conversation"), selection: $pane) {
            Text(L10n.string("assistant.tab.conversation", fallback: "Conversation"))
                .tag(AssistantV2ResearchPane.conversation)
            Text(L10n.string("assistant.tab.sources", fallback: "Sources"))
                .tag(AssistantV2ResearchPane.sources)
            Text(L10n.string("assistant.v2.tab.memory", fallback: "Memory"))
                .tag(AssistantV2ResearchPane.memory)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("assistant.v2.pane")
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
                        emptyState
                    } else {
                        statusBanner
                        AssistantV2ProposalStack(model: model)
                        AssistantV2ConversationView(model: model, cache: markdownCache)
                        AssistantV2StreamTailView(model: model)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("assistant.v2.bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollToken) { _, _ in
                proxy.scrollTo("assistant.v2.bottom", anchor: .bottom)
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
                } else if (model?.displayedSources.isEmpty ?? true) {
                    LinguaEmptyState(L10n.string("assistant.sources.empty", fallback: "No sources yet"), systemImage: "doc.text.magnifyingglass")
                        .accessibilityIdentifier("assistant.v2.sources.empty")
                } else {
                    ForEach(model?.displayedSources ?? []) { source in
                        AssistantV2SourceCard(
                            source: source,
                            job: source.transcribeSourceId.flatMap { model?.transcriptJobs[$0] },
                            transcriptionError: source.transcribeSourceId.flatMap { model?.transcriptionErrors[$0] },
                            onTranscribe: {
                                pendingSource = source
                                confirmTranscribe = true
                            },
                            onPlay: {
                                Task { await playSource(source) }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var memoryPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                AssistantV2ProposalStack(model: model)
                if model?.researchMemoryEntries.isEmpty ?? true, model?.pendingMemoryProposals.isEmpty ?? true {
                    LinguaEmptyState(L10n.string("assistant.v2.memory_empty", fallback: "No research notes yet."), systemImage: "note.text")
                        .font(.body)
                        .foregroundStyle(LinguaTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 72)
                } else {
                    ForEach(model?.researchMemoryEntries ?? [], id: \.memoryEntryId) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.type)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LinguaTheme.secondaryText)
                            Text(entry.content)
                                .font(.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if model?.snapshot?.status == .degraded {
            Text(L10n.string("assistant.v2.status.degraded", fallback: "Some sources need attention"))
                .font(.caption)
                .foregroundStyle(LinguaTheme.secondaryText)
        } else if model?.snapshot?.status == .corrupt {
            Text(L10n.string("assistant.v2.status.corrupt", fallback: "A source is damaged"))
                .font(.caption)
                .foregroundStyle(LinguaTheme.danger)
        }
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
                "assistant.v2.greeting_body",
                fallback: "Ask a question or describe a topic. I'll search the web, YouTube, and podcasts."
            ))
            .font(.subheadline)
            .foregroundStyle(LinguaTheme.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
        .padding(.horizontal, 24)
    }

    private var isEmptyConversation: Bool {
        (model?.snapshot?.messages.isEmpty ?? true)
            && model?.pendingUserText == nil
            && model?.reportText == nil
            && model?.errorMessage == nil
            && !isWorking
    }

    private var isWorking: Bool {
        model?.isStreaming == true || model?.snapshot?.activeTurn?.status.isTerminal == false
    }

    private var scrollToken: String {
        [
            model?.snapshot?.messages.last?.messageId ?? "",
            model?.pendingUserText ?? "",
            isWorking ? "1" : "0",
            model?.snapshot?.latestReportArtifactId ?? ""
        ].joined(separator: "|")
    }
}

private struct AssistantV2ConversationView: View {
    let model: AssistantV2ViewModel?
    let cache: AssistantV2MarkdownCache
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        ForEach(model?.snapshot?.messages ?? [], id: \.messageId) { message in
            AssistantV2MessageRow(message: message, cache: cache, openURL: openURL)
            if message.role == .user, let work = finishedTurnWork(for: message.turnId) {
                AssistantV2TurnWorkGroup(work: work, isRunning: false, thinkingStartedAt: nil)
            }
        }
        if let pending = pendingUserBubbleText {
            HStack {
                Spacer(minLength: 48)
                Text(pending)
                    .font(.body)
                    .foregroundStyle(LinguaTheme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(userBubbleFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        if let report = displayedReportText {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("assistant.v2.report", fallback: "Report"))
                    .font(.headline)
                AssistantV2MarkdownView(
                    markdown: report,
                    cache: cache,
                    cacheKey: model?.snapshot?.latestReportArtifactId
                )
            }
            .padding(.trailing, 12)
        }
    }

    private var displayedReportText: String? {
        guard let report = model?.reportText, !report.isEmpty, !isWorking else { return nil }
        let alreadyInConversation = model?.snapshot?.messages.contains {
            $0.role == .assistant && $0.markdown == report
        } == true
        return alreadyInConversation ? nil : report
    }

    private var pendingUserBubbleText: String? {
        guard let pending = model?.pendingUserText, !pending.isEmpty else { return nil }
        let alreadyShown = model?.snapshot?.messages.contains { $0.role == .user && $0.markdown == pending } == true
        return alreadyShown ? nil : pending
    }

    /// The turn currently streaming renders its work group in `AssistantV2StreamTailView` instead,
    /// right below wherever its user bubble ends up — this only supplies turns that are done.
    private func finishedTurnWork(for turnId: String) -> AssistantV2TurnWork? {
        guard turnId != liveTurnId else { return nil }
        return model?.turnWork[turnId]
    }

    private var liveTurnId: String? {
        model?.liveTurnId ?? model?.snapshot?.activeTurn?.turnId
    }

    private var isWorking: Bool {
        model?.isStreaming == true || model?.snapshot?.activeTurn?.status.isTerminal == false
    }

    private var userBubbleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(white: 0.93)
    }
}

private struct AssistantV2MessageRow: View {
    let message: AssistantV2Message
    let cache: AssistantV2MarkdownCache
    let openURL: OpenURLAction
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if message.role == .user {
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
                AssistantV2MarkdownView(
                    markdown: message.markdown,
                    cache: cache,
                    cacheKey: message.messageId
                )
                ForEach(message.citations ?? [], id: \.citationId) { citation in
                    AssistantV2CitationButton(citation: citation, openURL: openURL)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 28)
        }
    }

    private var userBubbleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(white: 0.93)
    }
}

private struct AssistantV2CitationButton: View {
    let citation: AssistantV2Citation
    let openURL: OpenURLAction

    var body: some View {
        Button {
            if let contentKey = citation.contentKey, let start = citation.startMilliseconds {
                _ = PlaybackDeepLinkCoordinator.shared.handle(
                    target: AssistantPlayerTarget(
                        contentKey: contentKey,
                        startMs: start,
                        endMs: citation.endMilliseconds ?? start
                    )
                )
            } else if let raw = citation.sourceURL, let url = URL(string: raw) {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(citation.label)
                    .font(.caption.weight(.semibold))
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
        .accessibilityIdentifier("assistant.v2.citation.\(citation.citationId)")
    }
}

private struct AssistantV2StreamTailView: View {
    let model: AssistantV2ViewModel?

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
            AssistantV2TurnWorkGroup(
                work: model?.liveTurnWork,
                isRunning: true,
                thinkingStartedAt: liveTurnId.flatMap { model?.thinkingStartedAt[$0] }
            )
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

    private var liveTurnId: String? {
        model?.liveTurnId ?? model?.snapshot?.activeTurn?.turnId
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

private struct AssistantV2ComposerView: View {
    let model: AssistantV2ViewModel?
    var composerFocused: FocusState<Bool>.Binding

    var body: some View {
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
            .accessibilityIdentifier("assistant.v2.composer")
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
                .accessibilityIdentifier("assistant.v2.cancel")
            } else {
                Button {
                    composerFocused.wrappedValue = false
                    Task { await model?.submit() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? LinguaTheme.primaryText : LinguaTheme.tertiaryText.opacity(0.45), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel(L10n.string("assistant.send", fallback: "Send"))
                .accessibilityIdentifier("assistant.v2.send")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
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

final class AssistantV2MarkdownCache {
    private var blockCache: [String: [AssistantMarkdownBlock]] = [:]
    private var inlineCache: [String: AttributedString] = [:]

    /// Parsed, block-structured markdown for a report or assistant message. Cached by the caller's
    /// stable key (artifact/message id) plus a content hash so a re-streamed body reparses.
    func blocks(_ raw: String, key: String?) -> [AssistantMarkdownBlock] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = key.map { "\($0):\(trimmed.hashValue)" } ?? String(trimmed.hashValue)
        if let cached = blockCache[cacheKey] { return cached }
        let parsed = parseMarkdownBlocks(trimmed)
        blockCache[cacheKey] = parsed
        return parsed
    }

    /// Inline-styled attributed text for one block fragment, tinting `[cN]` citation markers.
    func inline(_ text: String) -> AttributedString {
        if let cached = inlineCache[text] { return cached }
        let parsed = inlineMarkdownAttributed(text)
        inlineCache[text] = parsed
        return parsed
    }
}
#endif
