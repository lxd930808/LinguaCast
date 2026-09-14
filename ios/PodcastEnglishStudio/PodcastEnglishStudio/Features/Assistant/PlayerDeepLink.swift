import Foundation

public struct PlayerDeepLink: Equatable, Sendable {
    public var contentKey: String
    public var startMs: Int

    public init(contentKey: String, startMs: Int) {
        self.contentKey = contentKey
        self.startMs = startMs
    }

    public static func parse(_ url: URL) -> PlayerDeepLink? {
        guard url.scheme?.lowercased() == "linguacast" else { return nil }
        guard url.host?.lowercased() == "play" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        var seen = Set<String>()
        var contentKey: String?
        var startMs: Int?
        for item in items {
            let name = item.name.lowercased()
            if seen.contains(name) { return nil }
            seen.insert(name)
            if name == "content_key" {
                contentKey = item.value
            } else if name == "start_ms" {
                guard let raw = item.value, let value = Int(raw), value >= 0 else { return nil }
                startMs = value
            } else {
                return nil
            }
        }
        guard let contentKey, !contentKey.isEmpty, let startMs else { return nil }
        return PlayerDeepLink(contentKey: contentKey, startMs: startMs)
    }
}
