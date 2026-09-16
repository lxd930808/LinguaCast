import SwiftUI
import CloudSyncKit
import DomainModels

#if os(iOS)
private enum AssistantHomeRoute: Hashable {
    case research(String)
}

/// Assistant tab. Since V18 workspace research (assistant V2) is the only assistant API.
struct AssistantHomeView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SettingsNavigation.self) private var settingsNavigation
    @Environment(AccountController.self) private var account
    @State private var model: AssistantV2ViewModel?
    @State private var path: [AssistantHomeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !settings.configuration.isAssistantServiceUsable {
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
                    researchList(model)
                } else {
                    ProgressView()
                        .task { await bootstrap() }
                }
            }
            .navigationTitle(L10n.string("navigation.assistant", fallback: "Assistant"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if settings.configuration.isAssistantServiceUsable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await createResearch() }
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(model == nil)
                        .accessibilityLabel(L10n.string("assistant.new_research", fallback: "New research"))
                        .accessibilityIdentifier("assistant.new-session")
                    }
                }
            }
            .navigationDestination(for: AssistantHomeRoute.self) { route in
                switch route {
                case .research(let researchId):
                    AssistantV2ResearchView(researchId: researchId, model: model)
                }
            }
        }
        .onAppear {
            Task { await bootstrap() }
        }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty {
                Task { await model?.refreshList() }
            }
        }
        .onChange(of: settings.configuration.assistantServiceEnabled) { _, _ in
            Task { await bootstrap() }
        }
        // Reading the account also re-evaluates service availability after sign-in or sign-out.
        .onChange(of: account.accountId) { _, _ in
            Task { await bootstrap() }
        }
    }

    private func researchList(_ model: AssistantV2ViewModel) -> some View {
        List {
            Section(L10n.string("assistant.v2.section", fallback: "Research")) {
                if model.researches.isEmpty {
                    Text(L10n.string("assistant.v2.empty", fallback: "No workspace research yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.researches, id: \.researchId) { research in
                    NavigationLink(value: AssistantHomeRoute.research(research.researchId)) {
                        researchRow(
                            title: research.title,
                            detail: phaseTitle(research),
                            updatedAt: research.updatedAt
                        )
                    }
                    .accessibilityIdentifier("assistant.v2.research.\(research.researchId)")
                }
                .onDelete { indexSet in
                    let researches = model.researches
                    for index in indexSet {
                        let id = researches[index].researchId
                        Task { await model.deleteResearch(id) }
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

    private func researchRow(title: String, detail: String, updatedAt: Date) -> some View {
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
        guard let model else { return }
        let output = settings.configuration.translationTargetLanguage
        let quality = CloudTranslationQuality(
            rawValue: settings.configuration.translationQualityMode
        ) ?? .quality
        if let id = await model.createResearch(
            outputLanguage: output,
            targetLanguage: output,
            quality: quality
        ) {
            path.append(.research(id))
        }
    }

    private func bootstrap() async {
        guard settings.configuration.isAssistantServiceUsable else {
            model = nil
            return
        }
        let tokenProvider: AssistantTokenProviding = AccountServiceAccess.tokenProvider
            ?? KeychainAssistantTokenProvider(store: KeychainStore())
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let gateway = try? AssistantV2Gateway.makeDefault(
            baseURLString: settings.configuration.normalizedAssistantServiceBaseURL,
            tokenProvider: tokenProvider,
            clientVersion: clientVersion
        ) else {
            model = nil
            return
        }
        let viewModel = AssistantV2ViewModel(
            gateway: gateway,
            stream: AssistantV2EventStream(tokenProvider: tokenProvider),
            resolveEventsURL: { turnId, raw in
                if let raw { return gateway.resolveEventsURL(raw) }
                return gateway.eventsURL(turnId: turnId)
            }
        )
        model = viewModel
        await viewModel.refreshList()
    }

    private func phaseTitle(_ research: AssistantV2Research) -> String {
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
