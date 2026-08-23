import Foundation

// Pure keyword-matching policy shared by the app-side ContentFilterService. The service
// owns configuration, agent classification, and caching; this type owns only the
// synchronous, offline keyword decision so it can be unit-tested in the Core test target.
public struct ContentFilterKeywordPolicy: Equatable, Sendable {
    public var keywords: [String]

    public init(keywords: [String]) {
        self.keywords = keywords
    }

    // Parses a raw, user-entered keyword list. Accepts comma, CJK comma/顿号, semicolon,
    // and whitespace/newline separators; lowercases and drops empties.
    public init(rawKeywords raw: String) {
        self.init(keywords: Self.parseKeywords(raw))
    }

    public static func parseKeywords(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    public var isEmpty: Bool {
        keywords.isEmpty
    }

    // Case-insensitive substring match over the title and (optional) channel/show name.
    public func matches(title: String, channel: String?) -> Bool {
        guard !keywords.isEmpty else { return false }
        let haystack = ([title, channel ?? ""] as [String]).joined(separator: " ").lowercased()
        return keywords.contains { haystack.contains($0) }
    }
}
