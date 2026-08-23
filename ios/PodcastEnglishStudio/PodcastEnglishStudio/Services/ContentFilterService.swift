import Foundation
import Observation
import PodcastEnglishStudioCore
import CloudSyncKit

/// Two-layer content filter for podcast episodes and YouTube videos.
///
/// Layer 1 (keyword) is synchronous and fully offline: items whose title or
/// channel/show name contains any configured keyword are hidden immediately.
/// Layer 2 (agent) is optional and asynchronous: when the filter is enabled,
/// a free-form instruction is set, and a Translation LLM is configured, items
/// are classified in small batches through the same chat-completions endpoint
/// used by `TranslationClient`. Agent verdicts are cached in-memory by item id
/// and never block list rendering; any failure falls back to the keyword result.
@MainActor
@Observable
final class ContentFilterService {
    /// An item submitted to the filter (podcast episode or YouTube video).
    struct Item: Equatable, Sendable {
        var id: String
        var title: String
        var channel: String
    }

    private static let agentBatchSize = 10

    private(set) var configuration = AppConfiguration()
    private var keywordPolicy = ContentFilterKeywordPolicy(keywords: [])
    private var agentVerdicts: [String: Bool] = [:]
    private var queuedItemIDs: Set<String> = []
    private var pendingItems: [Item] = []
    private var isProcessingQueue = false
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Pushes the latest configuration into the service. Cached agent verdicts
    /// are cleared whenever filter-relevant settings change.
    func update(configuration: AppConfiguration) {
        let previousFingerprint = agentFingerprint
        self.configuration = configuration
        keywordPolicy = ContentFilterKeywordPolicy(rawKeywords: configuration.contentFilterKeywords)
        if agentFingerprint != previousFingerprint {
            agentVerdicts.removeAll()
            queuedItemIDs.removeAll()
            pendingItems.removeAll()
        }
    }

    /// Whether any filtering can currently hide items.
    var isActive: Bool {
        configuration.contentFilterEnabled && (!keywordPolicy.isEmpty || isAgentAvailable)
    }

    /// Synchronous decision used by list views while rendering. The keyword
    /// layer answers immediately; a cached agent verdict upgrades the result.
    func isFilteredOut(id: String, title: String, channel: String?) -> Bool {
        guard configuration.contentFilterEnabled else { return false }
        if keywordMatches(title: title, channel: channel) { return true }
        return agentVerdicts[id] ?? false
    }

    /// Keyword-layer-only decision (synchronous, offline).
    func isFilteredOut(title: String, channel: String?) -> Bool {
        guard configuration.contentFilterEnabled else { return false }
        return keywordMatches(title: title, channel: channel)
    }

    /// Enqueues items for asynchronous agent classification. Designed to be
    /// called from `.task`/`.onChange`; never blocks the caller on the network.
    func prefetchAgentVerdicts(_ items: [Item]) {
        guard configuration.contentFilterEnabled, isAgentAvailable else { return }
        var didEnqueue = false
        for item in items {
            guard agentVerdicts[item.id] == nil,
                  !queuedItemIDs.contains(item.id),
                  !keywordMatches(title: item.title, channel: item.channel)
            else { continue }
            queuedItemIDs.insert(item.id)
            pendingItems.append(item)
            didEnqueue = true
        }
        guard didEnqueue, !isProcessingQueue else { return }
        isProcessingQueue = true
        Task { await processQueue() }
    }

    // MARK: - Keyword layer

    // The matching rules live in Core (ContentFilterKeywordPolicy) so they are unit-tested;
    // this delegate keeps the service's call-sites unchanged.
    private func keywordMatches(title: String, channel: String?) -> Bool {
        keywordPolicy.matches(title: title, channel: channel)
    }

    // MARK: - Agent layer

    private var isAgentAvailable: Bool {
        !configuration.contentFilterPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && configuration.hasTranslationKey
    }

    private var agentFingerprint: String {
        [
            configuration.translationProvider,
            configuration.translationBaseURL,
            configuration.translationModelID,
            configuration.contentFilterPrompt,
            String(configuration.contentFilterEnabled)
        ].joined(separator: "|")
    }

    private func processQueue() async {
        while !pendingItems.isEmpty {
            if Task.isCancelled { break }
            let batch = Array(pendingItems.prefix(Self.agentBatchSize))
            pendingItems.removeFirst(batch.count)
            // On any failure, fall back to the keyword result (false here, since
            // keyword-matched items are never enqueued) and cache it so a broken
            // endpoint is not retried for every list render.
            let classified = (try? await classify(batch)) ?? [:]
            for item in batch {
                agentVerdicts[item.id] = classified[item.id] ?? false
            }
        }
        isProcessingQueue = false
        // Items enqueued while awaiting the last batch are drained by the loop
        // above; nothing else to do here.
    }

    private func agentUserPrompt(for items: [Item]) -> String {
        let instruction = configuration.contentFilterPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = items.map { item -> String in
            let channel = item.channel.isEmpty ? "-" : item.channel
            return "[\(item.id)] \(item.title) (channel: \(channel))"
        }
        return "Filter instruction: \(instruction)\nItems:\n" + lines.joined(separator: "\n")
    }

    /// Mirrors `TranslationClient.requestChatCompletion`: same provider, base
    /// URL, model, and request-body policy, pointed at the classification task.
    private func classify(_ items: [Item]) async throws -> [String: Bool] {
        let provider = TranslationProviderPolicy.normalizedProvider(configuration.translationProvider)
        let baseURL = TranslationProviderPolicy.requestBaseURL(
            provider: provider,
            configuredBaseURL: configuration.translationBaseURL
        )
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw PipelineError.missingConfiguration("translation base URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.translationAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: TranslationChatRequestPolicy.requestBody(
                provider: provider,
                modelID: configuration.translationModelID,
                reasoningEffort: configuration.translationReasoningEffort,
                messages: [
                    ["role": "system", "content": ContentFilterAgentPolicy.systemPrompt],
                    ["role": "user", "content": agentUserPrompt(for: items)]
                ]
            )
        )
        // DeepSeek JSON Output can return empty content; retry the identical request once.
        var emptyContentAttempt = 1
        while true {
            let (data, response) = try await withNetworkRetries(operation: "content filter classification") {
                try await self.session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw PipelineError.badResponse("Content filter classification failed (HTTP \(status))")
            }
            let content = Self.extractChatContent(from: data)
            if !TranslationChatResponsePolicy.isEmptyContent(content) {
                return ContentFilterAgentPolicy.parseVerdicts(from: content ?? "")
            }
            if TranslationChatResponsePolicy.shouldRetryEmptyContent(
                provider: provider,
                attempt: emptyContentAttempt
            ) {
                emptyContentAttempt += 1
                continue
            }
            return [:]
        }
    }

    private static func extractChatContent(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let content = TranslationChatResponsePolicy.extractContent(from: json) {
            return content
        }
        return String(data: data, encoding: .utf8)
    }
}
