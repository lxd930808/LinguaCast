import SwiftUI
import CloudSyncKit
import DomainModels

#if os(iOS)
private enum AssistantHomeRoute: Hashable {
    case v1Session(String)
    case v2Research(String)
}

struct AssistantHomeView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SettingsNavigation.self) private var settingsNavigation
    @AppStorage(AssistantV2FeatureFlag.defaultsKey) private var v2Enabled = false
    @State private var model: AssistantViewModel?
    @State private var v2Model: AssistantV2ViewModel?
    @State private var path: [AssistantHomeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !settings.configuration.assistantServiceEnabled {
                    ActionableEmptyStateView(
                        title: L10n.string("assistant.setup_required_title", fallback: "Turn on the assistant service"),
                        systemImage: "sparkles",
                        message: L10n.string("assistant.setup_required_body", fallback: "Enable the assistant service and add its address and token in Settings."),
                        primaryTitle: L10n.string("navigation.settings", fallback: "Settings"),
                        primarySystemImage: "gearshape",
                        primaryAction: { settingsNavigation.open(.root) }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("assistant.setup-required")
                } else if let model {
                    if v2Enabled {
                        splitList(model)
                    } else {
                        sessionList(model)
                    }
                } else {
                    ProgressView()
                        .task { await bootstrap() }
                }
            }
            .navigationTitle(L10n.string("navigation.assistant", fallback: "Assistant"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if settings.configuration.assistantServiceEnabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await createResearch() }
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(model == nil || (v2Enabled && v2Model == nil))
                        .accessibilityLabel(L10n.string("assistant.new_research", fallback: "New research"))
                        .accessibilityIdentifier("assistant.new-session")
                    }
                }
            }
            .navigationDestination(for: AssistantHomeRoute.self) { route in
                switch route {
                case .v1Session(let sessionId):
                    AssistantSessionView(
                        sessionId: sessionId,
                        model: model,
                        isReadOnly: v2Enabled || (model?.isLegacyReadOnly == true)
                    )
                case .v2Research(let researchId):
                    AssistantV2ResearchView(researchId: researchId, model: v2Model)
                }
            }
        }
        .onAppear {
            Task { await bootstrap() }
        }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty {
                Task {
                    await model?.refreshList()
                    if v2Enabled { await v2Model?.refreshList() }
                }
            }
        }
        .onChange(of: settings.configuration.assistantServiceEnabled) { _, _ in
            Task { await bootstrap() }
        }
        .onChange(of: v2Enabled) { _, _ in
            Task { await bootstrap() }
        }
    }

    @ViewBuilder
    private func sessionList(_ model: AssistantViewModel) -> some View {
        List {
            if model.isLegacyReadOnly {
                Section {
                    Text(L10n.string(
                        "assistant.legacy.banner",
                        fallback: "This session is from an earlier assistant version and is read-only."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant.legacy.banner")
                }
            }
            Section(L10n.string("assistant.recent", fallback: "Recent")) {
                if model.sessions.isEmpty {
                    Text(L10n.string("assistant.empty", fallback: "No research sessions yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sessions, id: \.sessionId) { session in
                    NavigationLink(value: AssistantHomeRoute.v1Session(session.sessionId)) {
                        sessionRow(title: session.title, detail: phaseTitle(session.phase), updatedAt: session.updatedAt)
                    }
                    .accessibilityIdentifier("assistant.session.\(session.sessionId)")
                }
                .onDelete { indexSet in
                    guard !model.isLegacyReadOnly else { return }
                    for index in indexSet {
                        let id = model.sessions[index].sessionId
                        Task { await model.deleteSession(id) }
                    }
                }
            }
        }
        .refreshable { await model.refreshList() }
        .overlay {
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func splitList(_ model: AssistantViewModel) -> some View {
        List {
            Section(L10n.string("assistant.v2.section", fallback: "Research")) {
                if v2Model?.researches.isEmpty ?? true {
                    Text(L10n.string("assistant.v2.empty", fallback: "No workspace research yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(v2Model?.researches ?? [], id: \.researchId) { research in
                    NavigationLink(value: AssistantHomeRoute.v2Research(research.researchId)) {
                        sessionRow(
                            title: research.title,
                            detail: v2PhaseTitle(research),
                            updatedAt: research.updatedAt
                        )
                    }
                    .accessibilityIdentifier("assistant.v2.research.\(research.researchId)")
                }
                .onDelete { indexSet in
                    guard let researches = v2Model?.researches else { return }
                    for index in indexSet {
                        let id = researches[index].researchId
                        Task { await v2Model?.deleteResearch(id) }
                    }
                }
            }
            Section(L10n.string("assistant.legacy.section", fallback: "Legacy, read-only")) {
                if model.sessions.isEmpty {
                    Text(L10n.string("assistant.legacy.empty", fallback: "No previous sessions."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sessions, id: \.sessionId) { session in
                    NavigationLink(value: AssistantHomeRoute.v1Session(session.sessionId)) {
                        sessionRow(title: session.title, detail: phaseTitle(session.phase), updatedAt: session.updatedAt)
                    }
                    .accessibilityIdentifier("assistant.session.\(session.sessionId)")
                }
            }
        }
        .refreshable {
            await model.refreshList()
            await v2Model?.refreshList()
        }
        .overlay {
            if let message = v2Model?.errorMessage ?? model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sessionRow(title: String, detail: String, updatedAt: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(AssistantListFormatting.compactAge(since: updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func createResearch() async {
        let output = settings.configuration.translationTargetLanguage
        let quality = CloudTranslationQuality(
            rawValue: settings.configuration.translationQualityMode
        ) ?? .quality
        if v2Enabled {
            guard let v2Model else { return }
            if let id = await v2Model.createResearch(
                outputLanguage: output,
                targetLanguage: output,
                quality: quality
            ) {
                path.append(.v2Research(id))
            }
        } else {
            guard let model else { return }
            if let id = await model.createSession(
                outputLanguage: output,
                targetLanguage: output,
                quality: quality
            ) {
                path.append(.v1Session(id))
            }
        }
    }

    private func bootstrap() async {
        guard settings.configuration.isAssistantServiceUsable else {
            model = nil
            v2Model = nil
            return
        }
        let tokenProvider = KeychainAssistantTokenProvider(store: KeychainStore())
        let baseURL = settings.configuration.normalizedAssistantServiceBaseURL
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let gateway = try? AssistantGateway.makeDefault(
            baseURLString: baseURL,
            tokenProvider: tokenProvider
        ) else { return }
        let viewModel = AssistantViewModel(
            gateway: gateway,
            stream: AssistantEventStream(tokenProvider: tokenProvider)
        )
        model = viewModel
        await viewModel.refreshList()
        if v2Enabled, let v2Gateway = try? AssistantV2Gateway.makeDefault(
            baseURLString: baseURL,
            tokenProvider: tokenProvider,
            clientVersion: clientVersion
        ) {
            let v2 = AssistantV2ViewModel(
                gateway: v2Gateway,
                stream: AssistantV2EventStream(tokenProvider: tokenProvider),
                resolveEventsURL: { turnId, raw in
                    if let raw { return v2Gateway.resolveEventsURL(raw) }
                    return v2Gateway.eventsURL(turnId: turnId)
                }
            )
            v2Model = v2
            await v2.refreshList()
        } else {
            v2Model = nil
        }
    }

    private func phaseTitle(_ phase: AssistantSessionPhase) -> String {
        switch phase {
        case .researching:
            return L10n.string("assistant.working", fallback: "Researching…")
        case .reportReady:
            return L10n.string("assistant.phase.report_ready", fallback: "Report ready")
        case .sourceSelected, .preparingContent:
            return L10n.string("assistant.preparation", fallback: "Preparation")
        case .transcriptReady, .qaReady:
            return L10n.string("assistant.phase.qa_ready", fallback: "Ready to ask")
        case .recoverableError:
            return L10n.string("assistant.phase.error", fallback: "Needs attention")
        default:
            return phase.rawValue
        }
    }

    private func v2PhaseTitle(_ research: AssistantV2Research) -> String {
        if research.status == .degraded {
            return L10n.string("assistant.v2.status.degraded", fallback: "Some sources need attention")
        }
        if research.status == .corrupt {
            return L10n.string("assistant.v2.status.corrupt", fallback: "A source is damaged")
        }
        return research.phase ?? research.status.rawValue
    }
}

enum AssistantListFormatting {
    static func compactAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 3600 {
            return "\(max(1, Int(seconds / 60)))m"
        }
        if seconds < 86_400 {
            return "\(max(1, Int(seconds / 3600)))h"
        }
        return "\(max(1, Int(seconds / 86_400)))d"
    }
}
#endif
