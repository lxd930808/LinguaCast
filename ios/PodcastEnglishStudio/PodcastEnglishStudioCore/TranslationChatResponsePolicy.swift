import Foundation

/// Extracts chat-completion `content` and decides whether DeepSeek empty replies
/// should get exactly one immediate retry of the same request.
public enum TranslationChatResponsePolicy {
    /// Pulls `choices[0].message.content` from a decoded chat-completions JSON object.
    /// Returns nil when the field is missing; empty/whitespace strings are returned as-is
    /// so callers can apply empty-content retry separately.
    public static func extractContent(from responseJSON: [String: Any]) -> String? {
        let choices = responseJSON["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String
    }

    /// Whether `content` is missing or only whitespace (DeepSeek JSON Output empty-content case).
    public static func isEmptyContent(_ content: String?) -> Bool {
        guard let content else { return true }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// DeepSeek only: retry the identical request once when the first successful response
    /// has empty `content`. `attempt` is 1-based for the request that just returned empty.
    public static func shouldRetryEmptyContent(provider: String, attempt: Int) -> Bool {
        guard attempt == 1 else { return false }
        return TranslationProviderPolicy.normalizedProvider(provider)
            == TranslationProviderPolicy.deepSeekProviderID
    }
}
