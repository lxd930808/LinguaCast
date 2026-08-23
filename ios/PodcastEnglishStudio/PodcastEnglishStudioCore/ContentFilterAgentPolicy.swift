import Foundation

/// Agent-layer content-filter prompt and JSON parsing, kept in Core so unit tests can
/// cover the contract without spinning up `ContentFilterService`.
public enum ContentFilterAgentPolicy {
    /// System prompt for LLM classification. Uses an object wrapper so DeepSeek JSON Output
    /// (which requires `json_object`, not a top-level array) works for every provider.
    public static let systemPrompt = """
    You are a strict content filter for a media library. Given the user's filter \
    instruction and a numbered list of items, decide which items the user wants \
    hidden. Respond with strict JSON only: {"items":[{"id":"<id>","hide":true|false}]}. \
    Include one object per item using the exact item id. No markdown, no explanation.
    """

    /// Parse agent verdicts from chat `content`. Accepts the new `{"items":[...]}` object
    /// and the legacy top-level `[{...}]` array so non-DeepSeek providers keep working.
    public static func parseVerdicts(from content: String) -> [String: Bool] {
        let stripped = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return [:] }

        if let rows = extractItemRows(from: stripped) {
            return verdicts(from: rows)
        }
        return [:]
    }

    private static func extractItemRows(from stripped: String) -> [[String: Any]]? {
        if let start = stripped.firstIndex(of: "{"),
           let end = stripped.lastIndex(of: "}"),
           start < end,
           let data = String(stripped[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = object["items"] as? [[String: Any]] {
            return items
        }

        // Legacy: top-level JSON array of verdict objects.
        if let start = stripped.firstIndex(of: "["),
           let end = stripped.lastIndex(of: "]"),
           start < end,
           let data = String(stripped[start...end]).data(using: .utf8),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return rows
        }
        return nil
    }

    private static func verdicts(from rows: [[String: Any]]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for row in rows {
            let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init)
            guard let id else { continue }
            result[id] = hideValue(row["hide"])
        }
        return result
    }

    private static func hideValue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let string as String:
            return ["true", "yes", "1"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case let number as NSNumber:
            return number.intValue != 0
        default:
            return false
        }
    }
}
