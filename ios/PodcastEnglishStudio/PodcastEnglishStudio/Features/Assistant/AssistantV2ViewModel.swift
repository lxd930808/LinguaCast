#if os(iOS)
import Foundation
import Observation
import DomainModels
import CloudSyncKit

struct AssistantV2SearchHit: Equatable, Sendable, Identifiable {
    var sourceId: String?
    var assistantSourceId: String?
    var nativeSourceId: String?
    var canonicalURL: String?
    var title: String?
    var platform: String?
    var enclosureUrl: String?

    var id: String {
        transcribeSourceId ?? nativeSourceId ?? canonicalURL ?? title ?? UUID().uuidString
    }

    var transcribeSourceId: String? {
        AssistantV2ViewModel.assistantSourceIdentifier(assistantSourceId, sourceId)
    }
}

struct AssistantV2DisplayedSource: Equatable, Identifiable, Hashable {
    var artifactId: String
    var kind: AssistantV2ArtifactKind
    var status: AssistantV2ArtifactStatus
    var evidenceLevel: AssistantV2EvidenceLevel
    var platform: String
    var title: String
    var canonicalURL: String?
    var transcribeSourceId: String?
    var nativeSourceId: String?
    var contentKey: String?
    var enclosureUrl: String?

    var id: String {
        transcribeSourceId ?? "\(artifactId):\(nativeSourceId ?? canonicalURL ?? title)"
    }

    var canTranscribe: Bool {
        guard transcribeSourceId != nil else { return false }
        if platform.lowercased() == "podcast" {
            let enclosure = enclosureUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !enclosure.isEmpty
        }
        return true
    }
}

@MainActor
@Observable
final class AssistantV2ViewModel {
    var researches: [AssistantV2Research] = []
    var snapshot: AssistantV2ResearchSnapshot?
    var reportText: String?
    var displayedSources: [AssistantV2DisplayedSource] = []
    @ObservationIgnored private var transcriptPollTasks: [String: (UUID, Task<Void, Never>)] = [:]
    var transcriptJobs: [String: AssistantV2TranscriptJob] = [:]
    /// Per-source transcription failure, keyed by `transcribeSourceId`. Kept separate from
    /// `errorMessage` (which only renders on the Conversation pane) so a failure to even start a
    /// transcription — before any job exists to carry its own `.failed*` status — is still visible
    /// on the Sources pane, next to the source that failed.
    var transcriptionErrors: [String: String] = [:]
    var draft = ""
    var errorMessage: String?
    var isLoading = false
    var isStreaming = false
    var pendingUserText: String?
    var streamingDraft = ""
    var activityLabel: String?
    var turnWork: [String: AssistantV2TurnWork] = [:]
    var liveTurnId: String?
    var thinkingStartedAt: [String: Date] = [:]

    /// Live work card for the turn currently in flight (pending bubble tail).
    var liveTurnWork: AssistantV2TurnWork? {
        let turnId = liveTurnId ?? snapshot?.activeTurn?.turnId
        guard let turnId else { return nil }
        return turnWork[turnId]
    }

    /// True once the in-flight turn has streamed at least one thinking or tool event.
    var hasVisibleTurnWork: Bool {
        guard let work = liveTurnWork else { return false }
        return work.thinking != nil || !work.tools.isEmpty
    }

    private let gateway: AssistantV2Gatewaying
    private var stream: AssistantV2EventStream?
    private let resolveEventsURL: ((String, String?) -> URL?)?
    private var lastEventId: String?
    private var streamTask: Task<Void, Never>?
    private var refreshedUnknownTypes = Set<String>()
    private var draftBuffer = ""
    private var draftFlushTask: Task<Void, Never>?
    private var suppressStreamAfterReport = false

    init(
        gateway: AssistantV2Gatewaying,
        stream: AssistantV2EventStream? = nil,
        resolveEventsURL: ((String, String?) -> URL?)? = nil
    ) {
        self.gateway = gateway
        self.stream = stream
        self.resolveEventsURL = resolveEventsURL
    }

    func refreshList() async {
        isLoading = true
        defer { isLoading = false }
        do {
            researches = try await gateway.listResearches(cursor: nil, limit: 20).researches
            errorMessage = nil
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createResearch(outputLanguage: String, targetLanguage: String, quality: CloudTranslationQuality) async -> String? {
        do {
            let created = try await gateway.createResearch(
                AssistantV2ResearchCreateRequest(
                    outputLanguage: outputLanguage,
                    storefront: "US",
                    targetLanguage: targetLanguage,
                    translationQuality: quality
                ),
                idempotencyKey: UUID().uuidString
            )
            await refreshList()
            return created.researchId
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openResearch(_ researchId: String) async {
        do {
            if snapshot?.researchId != researchId {
                lastEventId = nil
                refreshedUnknownTypes.removeAll()
                reportText = nil
                cancelTranscriptPolling()
                transcriptJobs = [:]
                displayedSources = []
                turnWork = [:]
                thinkingStartedAt = [:]
                liveTurnId = nil
            }
            snapshot = try await gateway.getResearch(id: researchId)
            mergeTurnWorkFromSnapshot()
            errorMessage = nil
            clearPendingIfAcked()
            await loadReportIfNeeded()
            await loadDisplayedSources()
            await reconcileTranscriptJobs(researchId: researchId)
            if let turn = snapshot?.activeTurn, !turn.status.isTerminal {
                await reconnect(turnId: turn.turnId, eventsURL: turn.eventsURL)
            }
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit() async {
        guard let researchId = snapshot?.researchId else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        pendingUserText = text
        streamingDraft = ""
        draftBuffer = ""
        draftFlushTask?.cancel()
        draftFlushTask = nil
        suppressStreamAfterReport = false
        lastEventId = nil
        refreshedUnknownTypes.removeAll()
        activityLabel = L10n.string("assistant.thinking", fallback: "Thinking")
        isStreaming = true
        errorMessage = nil
        do {
            let accepted = try await gateway.createTurn(
                researchId: researchId,
                request: AssistantV2TurnCreateRequest(message: text, mode: currentTurnMode),
                idempotencyKey: UUID().uuidString
            )
            liveTurnId = accepted.turnId
            await reconnect(turnId: accepted.turnId, eventsURL: accepted.eventsURL)
        } catch let error as AssistantGatewayError {
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
            await openResearch(snapshot?.researchId ?? "")
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteResearch(_ researchId: String) async {
        do {
            _ = try await gateway.deleteResearch(id: researchId, idempotencyKey: UUID().uuidString)
            researches.removeAll { $0.researchId == researchId }
            if snapshot?.researchId == researchId { snapshot = nil }
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmTranscription(sourceId: String, targetLanguage: String, quality: CloudTranslationQuality) async {
        guard let researchId = snapshot?.researchId else { return }
        transcriptionErrors[sourceId] = nil
        do {
            let job = try await gateway.requestTranscription(
                researchId: researchId,
                sourceId: sourceId,
                request: AssistantV2TranscriptionCreateRequest(
                    targetLanguage: targetLanguage,
                    translationQuality: quality
                ),
                idempotencyKey: UUID().uuidString
            )
            transcriptJobs[sourceId] = job
            startTranscriptPolling(researchId: researchId, job: job)
        } catch let error as AssistantGatewayError {
            transcriptionErrors[sourceId] = Self.describe(error)
        } catch {
            transcriptionErrors[sourceId] = error.localizedDescription
        }
    }

    func confirmMemoryProposal(_ proposalId: String) async {
        do {
            _ = try await gateway.confirmMemoryProposal(id: proposalId, idempotencyKey: UUID().uuidString)
            if let researchId = snapshot?.researchId {
                snapshot?.memory = try await gateway.getMemory(researchId: researchId)
            }
            errorMessage = nil
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rejectMemoryProposal(_ proposalId: String) async {
        do {
            _ = try await gateway.rejectMemoryProposal(id: proposalId, idempotencyKey: UUID().uuidString)
            if let researchId = snapshot?.researchId {
                snapshot?.memory = try await gateway.getMemory(researchId: researchId)
            }
            errorMessage = nil
        } catch let error as AssistantGatewayError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleBackground() {
        cancelTranscriptPolling()
        streamTask?.cancel()
        streamTask = nil
        draftFlushTask?.cancel()
        draftFlushTask = nil
        isStreaming = false
        activityLabel = nil
    }

    func handleForeground() async {
        if let researchId = snapshot?.researchId {
            await openResearch(researchId)
        } else {
            await refreshList()
        }
    }

    var pendingMemoryProposals: [AssistantV2MemoryProposal] {
        (snapshot?.memory?.proposals ?? []).filter { $0.status == .pending }
    }

    var researchMemoryEntries: [AssistantV2MemoryEntry] {
        snapshot?.memory?.entries ?? []
    }

    var currentTurnMode: AssistantV2TurnMode {
        let hasTranscript = snapshot?.artifacts.contains { $0.kind == .transcript && $0.status == .ready } == true
        return hasTranscript ? .contentQA : .research
    }

    private func loadReportIfNeeded() async {
        guard let researchId = snapshot?.researchId,
              let artifactId = snapshot?.latestReportArtifactId
        else { return }
        do {
            let body = try await gateway.getArtifact(researchId: researchId, artifactId: artifactId)
            reportText = body.text
        } catch {
            // Snapshot stays usable without the report body.
        }
    }

    private func loadDisplayedSources() async {
        guard let snapshot else {
            displayedSources = []
            return
        }
        var hits: [AssistantV2SearchHit] = []
        let searchKinds: Set<AssistantV2ArtifactKind> = [.youtubeSearch, .podcastSearch]
        for artifact in snapshot.artifacts where searchKinds.contains(artifact.kind) && artifact.status == .ready {
            do {
                let body = try await gateway.getArtifact(researchId: snapshot.researchId, artifactId: artifact.artifactId)
                hits.append(contentsOf: Self.parseSearchHits(from: body.text, fallbackPlatform: artifact.kind == .youtubeSearch ? "youtube" : "podcast"))
            } catch {
                continue
            }
        }
        displayedSources = Self.displayedSources(artifacts: snapshot.artifacts, hits: hits)
    }

    private func cancelTranscriptPolling() {
        for (_, task) in transcriptPollTasks.values { task.cancel() }
        transcriptPollTasks.removeAll()
    }

    private func startTranscriptPolling(researchId: String, job: AssistantV2TranscriptJob) {
        guard transcriptPollTasks[job.transcriptJobId] == nil,
              job.status != .ready, job.status != .failedTerminal, job.status != .failedRetryable else { return }
        let generation = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.pollTranscription(researchId: researchId, jobId: job.transcriptJobId, sourceId: job.sourceId)
            if self.transcriptPollTasks[job.transcriptJobId]?.0 == generation {
                self.transcriptPollTasks[job.transcriptJobId] = nil
            }
        }
        transcriptPollTasks[job.transcriptJobId] = (generation, task)
    }

    private func pollTranscription(researchId: String, jobId: String, sourceId: String) async {
        while !Task.isCancelled && snapshot?.researchId == researchId {
            do {
                let job = try await gateway.getTranscription(researchId: researchId, jobId: jobId)
                guard !Task.isCancelled, snapshot?.researchId == researchId else { return }
                transcriptJobs[sourceId] = job
                transcriptionErrors[sourceId] = nil
                switch job.status {
                case .ready, .failedTerminal:
                    await openResearch(researchId)
                    return
                case .failedRetryable:
                    return
                default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                transcriptionErrors[sourceId] = L10n.string("assistant.v2.transcript.reconnecting", fallback: "Connection interrupted. Retrying…")
            }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
        }
    }

    /// Reopening a research resumes progress polling for all unfinished jobs.
    private func reconcileTranscriptJobs(researchId: String) async {
        guard let jobs = try? await gateway.listTranscriptions(researchId: researchId) else { return }
        for job in jobs {
            transcriptJobs[job.sourceId] = job
            startTranscriptPolling(researchId: researchId, job: job)
        }
    }

    private func reconnect(turnId: String, eventsURL: String?) async {
        streamTask?.cancel()
        guard stream != nil, let url = resolveEventsURL?(turnId, eventsURL) else {
            if let researchId = snapshot?.researchId {
                try? await Task.sleep(nanoseconds: 400_000_000)
                snapshot = try? await gateway.getResearch(id: researchId)
                clearPendingIfAcked()
                await loadReportIfNeeded()
                await loadDisplayedSources()
            }
            isStreaming = false
            activityLabel = nil
            return
        }
        isStreaming = true
        streamingDraft = ""
        draftBuffer = ""
        draftFlushTask?.cancel()
        draftFlushTask = nil
        suppressStreamAfterReport = false
        liveTurnId = turnId
        if activityLabel == nil {
            activityLabel = L10n.string("assistant.thinking", fallback: "Thinking")
        }
        let cursor = lastEventId
        streamTask = Task { [weak self] in
            await self?.consumeStream(url: url, cursor: cursor)
        }
        await streamTask?.value
    }

    private func consumeStream(url: URL, cursor: String?) async {
        guard let stream else { return }
        do {
            for try await event in await stream.events(url: url, lastEventId: cursor) {
                if Task.isCancelled { break }
                apply(event)
                if let eventId = event.id.isEmpty ? nil : event.id {
                    lastEventId = eventId
                } else if let numeric = event.eventId {
                    lastEventId = String(numeric)
                }
                guard Self.shouldRefreshSnapshot(for: event.type) else { continue }
                if case .unknown(let raw) = event.type {
                    if refreshedUnknownTypes.contains(raw) { continue }
                    refreshedUnknownTypes.insert(raw)
                }
                if let researchId = snapshot?.researchId {
                    snapshot = try? await gateway.getResearch(id: researchId)
                    clearPendingIfAcked()
                    if event.type == .reportCompleted {
                        await loadReportIfNeeded()
                    }
                    if event.type == .sourceSaved || event.type == .webPageSaved || event.type == .webSearchCompleted {
                        await loadDisplayedSources()
                    }
                }
            }
        } catch {
            switch AssistantV2StreamRecovery.action(for: error) {
            case .refreshSnapshot:
                lastEventId = nil
                if let researchId = snapshot?.researchId {
                    await openResearch(researchId)
                }
            case .retryAfter(let seconds):
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                if let turn = snapshot?.activeTurn, !turn.status.isTerminal {
                    await reconnect(turnId: turn.turnId, eventsURL: turn.eventsURL)
                    return
                }
            case .fail:
                errorMessage = Self.describe(error as? AssistantGatewayError ?? .transport(error.localizedDescription))
            }
        }
        flushDraftNow()
        isStreaming = false
        activityLabel = nil
        streamingDraft = ""
        if let researchId = snapshot?.researchId {
            await openResearch(researchId)
            clearPendingIfAcked()
        }
    }

    nonisolated static func shouldRefreshSnapshot(for type: AssistantV2SseEventType) -> Bool {
        if type.shouldRefreshSnapshot { return true }
        switch type {
        case .sourceSaved, .webPageSaved, .webSearchCompleted, .webSearchFailed,
             .transcriptJobUpdated, .transcriptSaved, .memoryUpdated, .memoryProposed,
             .reportCompleted, .turnCompleted, .turnFailed, .turnCancelled:
            return true
        case .workspaceCreated, .researchTitleUpdated, .webSearchStarted, .reportDelta, .turnStarted,
             .heartbeat, .unknown,
             .thinkingStarted, .thinkingDelta, .thinkingCompleted, .toolStarted, .toolCompleted:
            return false
        }
    }

    private func apply(_ event: AssistantV2StreamEvent) {
        switch event.type {
        case .researchTitleUpdated:
            guard let title = payloadString(event, key: "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { break }
            snapshot?.title = title
            if let researchId = snapshot?.researchId,
               let index = researches.firstIndex(where: { $0.researchId == researchId }) {
                researches[index].title = title
            }
        case .webSearchStarted:
            activityLabel = L10n.string("assistant.v2.activity.search_web", fallback: "Searching the web")
        case .webSearchFailed:
            activityLabel = L10n.string("assistant.v2.activity.search_failed", fallback: "A web search could not finish")
        case .webPageSaved:
            activityLabel = L10n.string("assistant.v2.activity.page_saved", fallback: "Saved a web page")
        case .sourceSaved:
            activityLabel = L10n.string("assistant.v2.activity.source_saved", fallback: "Saved a source")
        case .transcriptJobUpdated:
            activityLabel = L10n.string("assistant.v2.activity.transcript", fallback: "Transcribing")
            if let jobId = payloadString(event, key: "transcriptJobId"),
               let statusRaw = payloadString(event, key: "status") {
                let status = AssistantV2TranscriptJobStatus(rawValue: statusRaw)
                if let existing = transcriptJobs.first(where: { $0.value.transcriptJobId == jobId }) {
                    var job = existing.value
                    job.status = status
                    if let progress = payloadNumber(event, key: "progress") {
                        job.progress = progress
                    }
                    transcriptJobs[existing.key] = job
                }
            }
        case .memoryUpdated, .memoryProposed:
            activityLabel = L10n.string("assistant.v2.activity.memory", fallback: "Updating memory")
        case .reportDelta:
            guard !suppressStreamAfterReport else { return }
            if let text = payloadString(event, key: "text") {
                enqueueDraft(text)
            }
        case .reportCompleted:
            flushDraftNow()
            streamingDraft = ""
            suppressStreamAfterReport = true
            activityLabel = L10n.string("assistant.v2.activity.report", fallback: "Writing report")
        case .turnFailed:
            activityLabel = nil
        case .thinkingStarted, .thinkingDelta, .thinkingCompleted, .toolStarted, .toolCompleted:
            guard let data = event.data else { break }
            let turnId = data.turnId
            turnWork[turnId] = Self.reduceTurnWork(turnWork[turnId], turnId: turnId, type: event.type, payload: data.payload)
            if event.type == .thinkingStarted {
                thinkingStartedAt[turnId] = Date()
            }
        default:
            break
        }
    }

    /// Seeds `turnWork` from the snapshot. Finished turns are always overwritten with the
    /// server's projection (authoritative after a refresh); the turn still streaming keeps its
    /// locally accumulated state so an in-flight thinking block or tool row is never rolled back.
    private func mergeTurnWorkFromSnapshot() {
        guard let entries = snapshot?.turnWork else { return }
        let liveId = liveTurnId ?? snapshot?.activeTurn?.turnId
        for entry in entries {
            if entry.turnId == liveId, turnWork[entry.turnId] != nil { continue }
            turnWork[entry.turnId] = entry
        }
    }

    /// Folds one `thinking.*` / `tool.*` SSE event into a turn's work card. Mirrors the server's
    /// `projectTurnWork` fold so a live view and a post-refresh snapshot render the same shape.
    nonisolated static func reduceTurnWork(
        _ current: AssistantV2TurnWork?,
        turnId: String,
        type: AssistantV2SseEventType,
        payload: [String: AssistantJSONLeaf]
    ) -> AssistantV2TurnWork {
        var work = current ?? AssistantV2TurnWork(turnId: turnId, durationMs: nil, thinking: nil, tools: [])
        switch type {
        case .thinkingStarted:
            if work.thinking == nil {
                work.thinking = AssistantV2TurnWorkThinking(status: "streaming", durationMs: nil, text: "", truncated: false, redacted: false)
            }
        case .thinkingDelta:
            var thinking = work.thinking ?? AssistantV2TurnWorkThinking(status: "streaming", durationMs: nil, text: "", truncated: false, redacted: false)
            let chunk = leafString(payload["text"]) ?? ""
            if !chunk.isEmpty {
                let appended = appendThinkingText(thinking.text ?? "", chunk)
                thinking.text = appended.text
                thinking.truncated = (thinking.truncated ?? false) || appended.truncated
            }
            work.thinking = thinking
        case .thinkingCompleted:
            let redacted = leafBool(payload["redacted"]) == true
            var thinking = work.thinking ?? AssistantV2TurnWorkThinking(status: "streaming", durationMs: nil, text: "", truncated: false, redacted: false)
            thinking.status = redacted ? "redacted" : "done"
            thinking.redacted = redacted
            if let duration = leafNumber(payload["durationMs"]) {
                thinking.durationMs = max(0, Int(duration))
            }
            if redacted {
                thinking.text = ""
                thinking.truncated = false
            }
            work.thinking = thinking
        case .toolStarted:
            let callId = leafString(payload["callId"]) ?? ""
            let tool = leafString(payload["tool"]) ?? ""
            let row = AssistantV2TurnWorkTool(callId: callId, tool: tool, labelKey: tool, status: "running", query: leafString(payload["query"]))
            var tools = work.tools
            if let index = tools.firstIndex(where: { $0.callId == callId }) {
                tools[index] = row
            } else {
                tools.append(row)
            }
            work.tools = tools
        case .toolCompleted:
            let callId = leafString(payload["callId"]) ?? ""
            let ok = leafBool(payload["ok"]) == true
            var tools = work.tools
            if let index = tools.firstIndex(where: { $0.callId == callId }) {
                tools[index].status = ok ? "completed" : "failed"
            } else {
                let tool = leafString(payload["tool"]) ?? ""
                tools.append(AssistantV2TurnWorkTool(callId: callId, tool: tool, labelKey: tool, status: ok ? "completed" : "failed", query: nil))
            }
            work.tools = tools
        default:
            break
        }
        return work
    }

    private nonisolated static let thinkingTextMax = 4096

    /// Mirrors the server's `appendString`: caps folded thinking text at 4096 characters.
    nonisolated static func appendThinkingText(_ current: String, _ chunk: String) -> (text: String, truncated: Bool) {
        if current.count >= thinkingTextMax { return (current, true) }
        let combined = current + chunk
        if combined.count <= thinkingTextMax { return (combined, false) }
        return (String(combined.prefix(thinkingTextMax)), true)
    }

    private nonisolated static func leafString(_ leaf: AssistantJSONLeaf?) -> String? {
        guard case .string(let value) = leaf else { return nil }
        return value
    }

    private nonisolated static func leafNumber(_ leaf: AssistantJSONLeaf?) -> Double? {
        switch leaf {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    private nonisolated static func leafBool(_ leaf: AssistantJSONLeaf?) -> Bool? {
        guard case .bool(let value) = leaf else { return nil }
        return value
    }

    /// Human-readable tool-row label. The server only ever sends the stable tool name; the
    /// sentence is chosen here so nothing server-authored (a path, a query, a function name)
    /// leaks into the UI verbatim.
    nonisolated static func toolLabel(for tool: String) -> String {
        switch tool {
        case "search_youtube":
            return L10n.string("assistant.v2.tool.search_youtube", fallback: "Searching YouTube")
        case "search_podcasts":
            return L10n.string("assistant.v2.tool.search_podcasts", fallback: "Searching podcasts")
        case "get_podcast_episodes":
            return L10n.string("assistant.v2.tool.get_podcast_episodes", fallback: "Reading episodes")
        case "web_search":
            return L10n.string("assistant.v2.tool.web_search", fallback: "Searching the web")
        case "fetch_web_page":
            return L10n.string("assistant.v2.tool.fetch_web_page", fallback: "Opening a web page")
        case "list_files", "read_file", "grep_files", "search_files":
            return L10n.string("assistant.v2.tool.workspace", fallback: "Looking at the workspace")
        case "retrieve_evidence":
            return L10n.string("assistant.v2.tool.retrieve_evidence", fallback: "Gathering evidence")
        case "save_research_report":
            return L10n.string("assistant.v2.tool.save_research_report", fallback: "Writing the report")
        case "request_transcription":
            return L10n.string("assistant.v2.tool.request_transcription", fallback: "Requesting a transcript")
        default:
            return L10n.string("assistant.v2.tool.generic", fallback: "Working")
        }
    }

    /// The Cindy-style verb bucket a tool call belongs to in the fold-header summary, or nil if
    /// the tool doesn't contribute to that summary (e.g. saving the report).
    nonisolated static func workCategory(forTool tool: String) -> String? {
        switch tool {
        case "search_youtube", "get_youtube_video_details", "search_podcasts", "get_podcast_episodes", "read_search_run", "web_search":
            return "search"
        case "fetch_web_page":
            return "open"
        case "list_files", "read_file", "grep_files", "search_files":
            return "view"
        case "retrieve_evidence":
            return "organize"
        default:
            return nil
        }
    }

    /// Only the "search" bucket names its target (YouTube / podcasts / the web); other buckets
    /// use one fixed phrase, so this only needs to resolve for search tools.
    nonisolated static func workNounKey(forTool tool: String) -> String? {
        switch tool {
        case "search_youtube", "get_youtube_video_details": return "youtube"
        case "search_podcasts", "get_podcast_episodes", "read_search_run": return "podcasts"
        case "web_search": return "web"
        default: return nil
        }
    }

    nonisolated static func workNoun(forKey key: String) -> String {
        switch key {
        case "youtube": return L10n.string("assistant.v2.work.noun.youtube", fallback: "YouTube")
        case "podcasts": return L10n.string("assistant.v2.work.noun.podcasts", fallback: "podcasts")
        case "web": return L10n.string("assistant.v2.work.noun.web", fallback: "the web")
        default: return key
        }
    }

    /// "Searched YouTube, podcasts and the web" — one phrase per verb bucket present in the turn,
    /// in a fixed search/open/view/organize order, joined the same way `ListFormatter` renders
    /// any other localized list. Returns nil when no tool call maps to a bucket (nothing to
    /// summarize beyond "Thought").
    nonisolated static func workDetailPhrase(for work: AssistantV2TurnWork, locale: Locale = .current) -> String? {
        var searchNounKeys: [String] = []
        var categoriesPresent = Set<String>()
        for tool in work.tools {
            guard let category = workCategory(forTool: tool.tool) else { continue }
            categoriesPresent.insert(category)
            if category == "search", let nounKey = workNounKey(forTool: tool.tool), !searchNounKeys.contains(nounKey) {
                searchNounKeys.append(nounKey)
            }
        }
        guard !categoriesPresent.isEmpty else { return nil }
        let formatter = ListFormatter()
        formatter.locale = locale
        var phrases: [String] = []
        for category in ["search", "open", "view", "organize"] where categoriesPresent.contains(category) {
            switch category {
            case "search":
                let nouns = searchNounKeys.map { workNoun(forKey: $0) }
                let joined = formatter.string(from: nouns) ?? nouns.joined(separator: ", ")
                phrases.append(L10n.format("assistant.v2.work.phrase.search", fallback: "Searched %@", joined))
            case "open":
                phrases.append(L10n.string("assistant.v2.work.phrase.open", fallback: "Opened a web page"))
            case "view":
                phrases.append(L10n.string("assistant.v2.work.phrase.view", fallback: "Looked at the workspace"))
            case "organize":
                phrases.append(L10n.string("assistant.v2.work.phrase.organize", fallback: "Gathered evidence"))
            default:
                break
            }
        }
        guard !phrases.isEmpty else { return nil }
        return formatter.string(from: phrases) ?? phrases.joined(separator: ", ")
    }

    /// Fold-header summary: "Work in progress" while running, else "Thought · <detail>" once
    /// something was searched/opened/viewed/gathered, else a plain "Thought"/"Done".
    nonisolated static func foldSummary(for work: AssistantV2TurnWork?, isRunning: Bool, locale: Locale = .current) -> String {
        if isRunning {
            return L10n.string("assistant.v2.work.in_progress", fallback: "Work in progress")
        }
        guard let work else {
            return L10n.string("assistant.v2.work.summary_done", fallback: "Done")
        }
        if let detail = workDetailPhrase(for: work, locale: locale) {
            return L10n.format("assistant.v2.work.summary_with_detail", fallback: "Thought · %@", detail)
        }
        if work.thinking != nil {
            return L10n.string("assistant.v2.work.summary_thought_only", fallback: "Thought")
        }
        return L10n.string("assistant.v2.work.summary_done", fallback: "Done")
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
        if snapshot?.messages.contains(where: { $0.role == .user && $0.markdown == pending }) == true {
            pendingUserText = nil
        }
    }

    private func payloadString(_ event: AssistantV2StreamEvent, key: String) -> String? {
        guard let leaf = event.data?.payload[key] else { return nil }
        switch leaf {
        case .string(let value): return value
        case .number(let value): return String(Int(value))
        case .bool(let value): return value ? "true" : "false"
        case .null: return nil
        }
    }

    private func payloadNumber(_ event: AssistantV2StreamEvent, key: String) -> Double? {
        guard let leaf = event.data?.payload[key] else { return nil }
        if case .number(let value) = leaf { return value }
        if case .string(let value) = leaf { return Double(value) }
        return nil
    }

    nonisolated static func describe(_ error: AssistantGatewayError) -> String {
        if error.v2Code == .assistantV2Disabled {
            return L10n.string(
                "assistant.v2.disabled",
                fallback: "V15 research is turned off on the server."
            )
        }
        if error.v2Code == .eventCursorExpired {
            return L10n.string("assistant.v2.cursor_expired", fallback: "Refreshing the latest research state.")
        }
        if case .http(_, let server) = error, server?.code == "QUOTA_EXCEEDED" {
            return L10n.string(
                "assistant.v2.quota_exceeded",
                fallback: "You've used today's free assistant turns. They reset at midnight China Standard Time."
            )
        }
        switch error {
        case .http(_, let server):
            return server?.message.isEmpty == false ? (server?.message ?? "HTTP error") : (server?.code ?? "HTTP error")
        case .transport:
            return "offline"
        case .decoding:
            return "decode"
        case .configuration:
            return "configuration"
        }
    }

    nonisolated static func assistantSourceIdentifier(_ assistantSourceId: String?, _ sourceId: String?) -> String? {
        [assistantSourceId, sourceId].compactMap { $0 }.first(where: isAssistantSourceId)
    }

    nonisolated static func isAssistantSourceId(_ value: String) -> Bool {
        guard value.hasPrefix("so_"), value.count == 29 else { return false }
        let body = value.dropFirst(3)
        return body.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "A" && scalar <= "H")
                || (scalar >= "J" && scalar <= "N")
                || (scalar >= "P" && scalar <= "T")
                || (scalar >= "V" && scalar <= "Z")
        }
    }

    nonisolated static func parseSearchHits(from text: String, fallbackPlatform: String) -> [AssistantV2SearchHit] {
        struct Document: Decodable {
            var results: [Hit]?
            var platform: String?
        }
        struct Hit: Decodable {
            var sourceId: String?
            var assistantSourceId: String?
            var nativeSourceId: String?
            var canonicalURL: String?
            var title: String?
            var platform: String?
            var enclosureUrl: String?
        }
        guard let data = text.data(using: .utf8),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return (document.results ?? []).map { hit in
            AssistantV2SearchHit(
                sourceId: hit.sourceId,
                assistantSourceId: hit.assistantSourceId,
                nativeSourceId: hit.nativeSourceId ?? (hit.sourceId.flatMap { isAssistantSourceId($0) ? nil : $0 }),
                canonicalURL: hit.canonicalURL,
                title: hit.title,
                platform: hit.platform ?? document.platform ?? fallbackPlatform,
                enclosureUrl: hit.enclosureUrl
            )
        }
    }

    nonisolated static func displayedSources(
        artifacts: [AssistantV2WorkspaceArtifact],
        hits: [AssistantV2SearchHit]
    ) -> [AssistantV2DisplayedSource] {
        var rows: [AssistantV2DisplayedSource] = []
        if hits.isEmpty {
            for artifact in artifacts where artifact.sourceReference != nil {
                let reference = artifact.sourceReference!
                rows.append(
                    AssistantV2DisplayedSource(
                        artifactId: artifact.artifactId,
                        kind: artifact.kind,
                        status: artifact.status,
                        evidenceLevel: artifact.evidenceLevel,
                        platform: reference.platform,
                        title: reference.canonicalURL,
                        canonicalURL: reference.canonicalURL,
                        transcribeSourceId: assistantSourceIdentifier(nil, reference.sourceId),
                        nativeSourceId: reference.sourceId,
                        contentKey: reference.contentKey,
                        enclosureUrl: nil
                    )
                )
            }
            return rows
        }
        var usedHits = Set<String>()
        for hit in hits {
            let key = hit.id
            usedHits.insert(key)
            let artifact = artifacts.first { candidate in
                candidate.sourceReference?.canonicalURL == hit.canonicalURL
                    || candidate.sourceReference?.sourceId == hit.nativeSourceId
                    || candidate.sourceReference?.sourceId == hit.sourceId
                    || (hit.platform == "youtube" && candidate.kind == .youtubeSearch)
                    || (hit.platform == "podcast" && candidate.kind == .podcastSearch)
            }
            let platform = hit.platform ?? artifact?.sourceReference?.platform ?? "web"
            rows.append(
                AssistantV2DisplayedSource(
                    artifactId: artifact?.artifactId ?? hit.id,
                    kind: artifact?.kind ?? (platform == "youtube" ? .youtubeSearch : .podcastSearch),
                    status: artifact?.status ?? .ready,
                    evidenceLevel: artifact?.evidenceLevel ?? .searchMetadata,
                    platform: platform,
                    title: hit.title ?? hit.canonicalURL ?? platform,
                    canonicalURL: hit.canonicalURL ?? artifact?.sourceReference?.canonicalURL,
                    transcribeSourceId: hit.transcribeSourceId,
                    nativeSourceId: hit.nativeSourceId ?? hit.sourceId,
                    contentKey: artifact?.sourceReference?.contentKey,
                    enclosureUrl: hit.enclosureUrl
                )
            )
        }
        for artifact in artifacts where artifact.kind == .webPage {
            let reference = artifact.sourceReference
            rows.append(
                AssistantV2DisplayedSource(
                    artifactId: artifact.artifactId,
                    kind: artifact.kind,
                    status: artifact.status,
                    evidenceLevel: artifact.evidenceLevel,
                    platform: reference?.platform ?? "web",
                    title: reference?.canonicalURL ?? artifact.artifactId,
                    canonicalURL: reference?.canonicalURL,
                    transcribeSourceId: nil,
                    nativeSourceId: reference?.sourceId,
                    contentKey: reference?.contentKey,
                    enclosureUrl: nil
                )
            )
        }
        _ = usedHits
        return rows
    }

    nonisolated static func evidenceTitle(_ level: AssistantV2EvidenceLevel) -> String {
        switch level {
        case .searchMetadata:
            return L10n.string("assistant.v2.evidence.search_metadata", fallback: "Search summary")
        case .primaryContent:
            return L10n.string("assistant.v2.evidence.primary_content", fallback: "Page")
        case .transcript:
            return L10n.string("assistant.v2.evidence.transcript", fallback: "Transcript")
        case .researchNote:
            return L10n.string("assistant.v2.evidence.research_note", fallback: "Note")
        case .userPreference:
            return L10n.string("assistant.v2.evidence.user_preference", fallback: "Preference")
        case .unknown(let raw):
            return raw
        }
    }

    nonisolated static func transcriptStatusTitle(_ status: AssistantV2TranscriptJobStatus, progress: Double? = nil, error: String? = nil, installStatus: String? = nil) -> String {
        switch status {
        case .requested, .waitingService:
            return L10n.string("cloud.stage.queued", fallback: "Queued on the server")
        case .running:
            if installStatus == "retrying" { return L10n.string("assistant.v2.transcript.reconnecting", fallback: "Connection interrupted. Retrying…") }
            if installStatus == "stalled" { return L10n.string("assistant.v2.transcript.stalled", fallback: "Progress has not changed for a while. Still checking…") }
            return YTSourceGenerationProgressText.title(step: installStatus == "translating" ? "translating" : "transcribing", progress: progress, hidesZeroProgress: true) ?? PipelineStepTitle.display("transcribe")
        case .installing:
            return L10n.string("pipeline.step.preparing", fallback: "Preparing")
        case .ready:
            return L10n.string("assistant.v2.transcript.ready", fallback: "Transcript ready")
        case .failedRetryable, .failedTerminal:
            let title = L10n.string("assistant.v2.transcript.failed", fallback: "Transcription failed")
            guard let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return title }
            return "\(title) · \(reason)"
        case .unknown(let raw):
            return raw
        }
    }
}
#endif
