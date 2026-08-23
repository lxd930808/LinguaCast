import Foundation

public struct LocalSetupAccessGrant: Sendable, Equatable {
    public let token: String
    public let expiresAt: Date
    private var invalidated: Bool

    public init(token: String, issuedAt: Date, lifetime: TimeInterval) {
        self.token = token
        expiresAt = issuedAt.addingTimeInterval(lifetime)
        invalidated = false
    }

    public func accepts(_ candidate: String?, at date: Date = Date()) -> Bool {
        !invalidated && candidate == token && date < expiresAt
    }

    public mutating func consume(_ candidate: String?, at date: Date = Date()) -> Bool {
        guard accepts(candidate, at: date) else { return false }
        invalidated = true
        return true
    }

    public mutating func invalidate() {
        invalidated = true
    }
}

public enum LocalSetupFormPolicy {
    public static let localMediaAllowedKeys: Set<String> = [
        "localMediaEnabled",
        "localMediaBaseURL",
        "localMediaMode",
        "localMediaPreferredHeight"
    ]

    public static func filteredLocalMediaFields(_ form: [String: String]) -> [String: String] {
        form.filter { localMediaAllowedKeys.contains($0.key) }
    }
}
