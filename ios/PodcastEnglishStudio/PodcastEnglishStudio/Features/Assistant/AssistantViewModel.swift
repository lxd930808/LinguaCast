import Foundation
import Observation
import DomainModels
import CloudSyncKit

@MainActor
@Observable
final class AssistantViewModel {
    var sessions: [AssistantSessionSummary] = []
    var snapshot: AssistantSessionSnapshot?
    var draft = ""
    var errorMessage: String?
    var isLoading = false
    var isStreaming = false
    var pendingUserText: String?
    var streamingDraft = ""
    var activityLabel: String?
    var isLegacyReadOnly = false

    private let gateway: AssistantGatewaying
    private var stream: AssistantEventStream?
    private var suppressStreamAfterReport = false
    private var draftBuffer = ""
    private var draftFlushTask: Task<Void, Never>?

    init(gateway: AssistantGatewaying, stream: AssistantEventStream? = nil) {
        self.gateway = gateway
        self.stream = stream
    }

    func refreshList() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await gateway.listSessions(cursor: nil, limit: 20).sessions
            errorMessage = nil
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSession(outputLanguage: String, targetLanguage: String, quality: CloudTranslationQuality) async -> String? {
        do {
            let created = try await gateway.createSession(
                AssistantSessionCreateRequest(
                    outputLanguage: outputLanguage,
                    storefront: "US",
                    targetLanguage: targetLanguage,
                    translationQuality: quality
                ),
                idempotencyKey: UUID().uuidString
            )
            await refreshList()
            return created.sessionId
        } catch let error as AssistantGatewayError {
            if Self.isLegacyReadOnly(error) {
                isLegacyReadOnly = true
            }
            errorMessage = Self.describe(error)
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openSession(_ sessionId: String) async {
        do {
            snapshot = try await gateway.getSession(id: sessionId)
            errorMessage = nil
            clearPendingIfAcked()
            if let turn = snapshot?.activeTurn, !turn.status.isTerminal {
                await reconnect(turnId: turn.turnId)
            }
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit(kind: AssistantTurnKind) async {
        guard let sessionId = snapshot?.sessionId else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        pendingUserText = text
        streamingDraft = ""
        draftBuffer = ""
        draftFlushTask?.cancel()
        draftFlushTask = nil
        suppressStreamAfterReport = false
        activityLabel = L10n.string("assistant.thinking", fallback: "Thinking")
        isStreaming = true
        errorMessage = nil
        do {
            let accepted = try await gateway.createTurn(
                sessionId: sessionId,
                request: AssistantTurnCreateRequest(kind: kind, text: text),
                idempotencyKey: UUID().uuidString
            )
            await reconnect(turnId: accepted.turnId)
        } catch let error as AssistantGatewayError {
            if Self.isLegacyReadOnly(error) {
                isLegacyReadOnly = true
            }
            isStreaming = false
            activityLabel = nil
            draft = pendingUserText ?? draft
            pendingUserText = nil
            errorMessage = Self.describe(error)
        } catch {
            isStreaming = false
            activityLabel = nil
            draft = pendingUserText ?? draft
            pendingUserText = nil
            errorMessage = error.localizedDescription
        }
    }

    func cancelActiveTurn() async {
        guard let turnId = snapshot?.activeTurn?.turnId else { return }
        do {
            _ = try await gateway.cancelTurn(id: turnId, idempotencyKey: UUID().uuidString)
            await openSession(snapshot?.sessionId ?? "")
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ sessionId: String) async {
        do {
            try await gateway.deleteSession(id: sessionId, idempotencyKey: UUID().uuidString)
            sessions.removeAll { $0.sessionId == sessionId }
            if snapshot?.sessionId == sessionId { snapshot = nil }
        } catch let error as AssistantGatewayError {
            if Self.isLegacyReadOnly(error) {
                isLegacyReadOnly = true
            }
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bindSource(_ searchResultId: String, targetLanguage: String, quality: CloudTranslationQuality) async {
        guard let sessionId = snapshot?.sessionId else { return }
        do {
        let binding = try await gateway.bindSource(
                sessionId: sessionId,
                request: AssistantSourceBindRequest(
                    searchResultId: searchResultId,
                    targetLanguage: targetLanguage,
                    translationQuality: quality
                ),
                idempotencyKey: UUID().uuidString
            )
            if var snap = snapshot {
                snap.binding = binding
                snapshot = snap
            }
            await pollPreparation(sessionId: sessionId)
        } catch let error as AssistantGatewayError {
            if Self.isLegacyReadOnly(error) {
                isLegacyReadOnly = true
            }
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleBackground() {
        draftFlushTask?.cancel()
        draftFlushTask = nil
        isStreaming = false
        activityLabel = nil
    }

    func handleForeground() async {
        if let sessionId = snapshot?.sessionId {
            await openSession(sessionId)
        } else {
            await refreshList()
        }
    }

    private func pollPreparation(sessionId: String) async {
        for _ in 0..<90 {
            do {
                snapshot = try await gateway.getSession(id: sessionId)
                let sources = try await gateway.getSources(sessionId: sessionId)
                if var snap = snapshot, let binding = sources.binding {
                    snap.binding = binding
                    snapshot = snap
                    if binding.indexStatus == "ready" || binding.status == "failed" || binding.error != nil {
                        return
                    }
                }
            } catch {
                errorMessage = Self.describe(error as? AssistantGatewayError ?? .transport(error.localizedDescription))
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func reconnect(turnId: String) async {
        guard let stream, let gateway = gateway as? AssistantGateway else {
            if let sessionId = snapshot?.sessionId {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await openSession(sessionId)
            }
            return
        }
        isStreaming = true
        streamingDraft = ""
        draftBuffer = ""
        draftFlushTask?.cancel()
        draftFlushTask = nil
        suppressStreamAfterReport = false
        if activityLabel == nil {
            activityLabel = L10n.string("assistant.thinking", fallback: "Thinking")
        }
        let url = gateway.eventsURL(turnId: turnId)
        do {
            for try await event in await stream.events(url: url, lastEventId: nil) {
                apply(event)
                guard Self.shouldRefreshSnapshot(for: event.type) else { continue }
                if let sessionId = snapshot?.sessionId {
                    snapshot = try? await gateway.getSession(id: sessionId)
                    clearPendingIfAcked()
                }
            }
        } catch {
            errorMessage = Self.describe(error as? AssistantGatewayError ?? .transport(error.localizedDescription))
        }
        flushDraftNow()
        isStreaming = false
        activityLabel = nil
        streamingDraft = ""
        if let sessionId = snapshot?.sessionId {
            await openSession(sessionId)
            clearPendingIfAcked()
        }
    }

    nonisolated static func shouldRefreshSnapshot(for type: AssistantSseEventType) -> Bool {
        switch type {
        case .turnAccepted, .reportReady, .transcriptReady, .citationReady,
             .contentProgress, .turnCompleted, .turnFailed, .turnCancelled,
             .searchResultsRanked, .searchSourceCompleted, .sessionTitleUpdated:
            return true
        case .turnStarted, .toolStarted, .toolCompleted, .messageDelta, .heartbeat,
             .searchPlanReady, .searchSourceStarted:
            return false
        case .unknown(_):
            return false
        }
    }

    private func apply(_ event: AssistantStreamEvent) {
        switch event.type {
        case .toolStarted:
            flushDraftNow()
            streamingDraft = ""
            if let tool = payloadString(event, key: "tool") {
                activityLabel = Self.activityLabel(for: tool)
            }
        case .messageDelta:
            guard !suppressStreamAfterReport else { return }
            if let text = payloadString(event, key: "text") {
                enqueueDraft(text)
            }
        case .reportReady:
            flushDraftNow()
            streamingDraft = ""
            suppressStreamAfterReport = true
            activityLabel = L10n.string("assistant.activity.report", fallback: "Writing report")
        case .turnFailed:
            activityLabel = nil
        case .sessionTitleUpdated:
            if let title = payloadString(event, key: "title") {
                snapshot?.title = title
                let sessionId = event.data?.sessionId ?? snapshot?.sessionId
                if let sessionId, let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                    sessions[index].title = title
                }
            }
        default:
            break
        }
    }

    private func enqueueDraft(_ text: String) {
        draftBuffer += text
        guard draftFlushTask == nil else { return }
        draftFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.flushDraftNow()
        }
    }

    private func flushDraftNow() {
        draftFlushTask?.cancel()
        draftFlushTask = nil
        guard !draftBuffer.isEmpty else { return }
        streamingDraft += draftBuffer
        draftBuffer = ""
    }

    private func clearPendingIfAcked() {
        guard let pending = pendingUserText else { return }
        if snapshot?.messages.contains(where: { $0.role == "user" && $0.markdown == pending }) == true {
            pendingUserText = nil
        }
    }

    private func payloadString(_ event: AssistantStreamEvent, key: String) -> String? {
        guard let leaf = event.data?.payload[key], case .string(let value) = leaf else { return nil }
        return value
    }

    private static func activityLabel(for tool: String) -> String {
        switch tool {
        case "search_youtube":
            return L10n.string("assistant.activity.search_youtube", fallback: "Searching YouTube")
        case "search_apple_podcasts":
            return L10n.string("assistant.activity.search_apple_podcasts", fallback: "Searching Apple Podcasts")
        case "search_podcasts":
            return L10n.string("assistant.activity.search_podcasts", fallback: "Searching podcasts")
        case "get_podcast_episodes":
            return L10n.string("assistant.activity.feed", fallback: "Reading podcast episodes")
        case "read_search_run":
            return L10n.string("assistant.activity.read_results", fallback: "Reading results")
        case "get_youtube_video_details":
            return L10n.string("assistant.activity.youtube_details", fallback: "Loading video details")
        case "save_research_report":
            return L10n.string("assistant.activity.report", fallback: "Writing report")
        case "search_current_transcript":
            return L10n.string("assistant.activity.transcript", fallback: "Searching the transcript")
        default:
            return L10n.string("assistant.thinking", fallback: "Thinking")
        }
    }

    nonisolated static func describe(_ error: AssistantGatewayError) -> String {
        if isLegacyReadOnly(error) {
            return L10n.string(
                "assistant.legacy.mutation_blocked",
                fallback: "Previous sessions are read-only. Turn on V15 research in Settings to start a new workspace."
            )
        }
        switch error {
        case .http(_, let server):
            return server?.code ?? "HTTP error"
        case .transport:
            return "offline"
        case .decoding:
            return "decode"
        case .configuration:
            return "configuration"
        }
    }

    nonisolated static func isLegacyReadOnly(_ error: AssistantGatewayError) -> Bool {
        if error.v2Code == .legacySessionReadOnly { return true }
        if case .http(_, let server) = error, server?.code == "LEGACY_SESSION_READ_ONLY" {
            return true
        }
        return false
    }
}
