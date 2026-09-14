import Foundation

/// How a catalog record entered the local library.
/// Subscription items stay in Programs / Home continue-playing; assistant
/// items stay isolated unless the user pins them to the Home shelf.
public enum CatalogOrigin: String, Codable, Hashable, Sendable {
    case subscription
    case assistant

    /// Sentinel channel id used for assistant-materialized YouTube records
    /// so they never appear under a real subscribed channel.
    public static let assistantChannelRecordID = "assistant"

    public init(stored raw: String?) {
        if let raw, let value = CatalogOrigin(rawValue: raw) {
            self = value
        } else {
            self = .subscription
        }
    }

    /// `nil` means the historical default (subscription) so lightweight
    /// SwiftData migration can leave existing rows untouched.
    public var storedValue: String? {
        self == .subscription ? nil : rawValue
    }

    public var appearsInSubscriptionLibrary: Bool {
        self != .assistant
    }
}

public enum CatalogIsolationPolicy {
    public static func appearsInSubscriptionLibrary(originRaw: String?) -> Bool {
        CatalogOrigin(stored: originRaw).appearsInSubscriptionLibrary
    }

    public static func isPinnedAssistantHomeItem(originRaw: String?, pinnedToHome: Bool) -> Bool {
        CatalogOrigin(stored: originRaw) == .assistant && pinnedToHome
    }
}
