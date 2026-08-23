import Foundation

/// Local-only HTTP validators for RSS conditional requests (not CloudKit-synced).
public struct PodcastFeedValidators: Equatable, Sendable {
    public var etag: String?
    public var lastModified: String?
    public var feedURL: String

    public init(etag: String? = nil, lastModified: String? = nil, feedURL: String) {
        self.etag = Self.normalized(etag)
        self.lastModified = Self.normalized(lastModified)
        self.feedURL = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasAnyValidator: Bool {
        etag != nil || lastModified != nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}

/// Resolved catalog payload after a successful (modified) feed download.
public struct ResolvedPodcastFeed: Equatable, Sendable {
    public var show: PodcastShowInfo
    public var episodes: [PodcastEpisodeInfo]
    public var allEpisodeGUIDs: Set<String>
    public var feedURL: URL

    public init(
        show: PodcastShowInfo,
        episodes: [PodcastEpisodeInfo],
        allEpisodeGUIDs: Set<String>,
        feedURL: URL
    ) {
        self.show = show
        self.episodes = episodes
        self.allEpisodeGUIDs = allEpisodeGUIDs
        self.feedURL = feedURL
    }
}

/// Explicit outcome of an RSS resolve/refresh.
public enum PodcastFeedRefreshResult: Equatable, Sendable {
    case modified(ResolvedPodcastFeed, validators: PodcastFeedValidators)
    case notModified(validators: PodcastFeedValidators)
}

/// Conditional request header names/values for If-None-Match / If-Modified-Since.
public struct PodcastFeedConditionalHeaders: Equatable, Sendable {
    public var ifNoneMatch: String?
    public var ifModifiedSince: String?

    public init(ifNoneMatch: String? = nil, ifModifiedSince: String? = nil) {
        self.ifNoneMatch = ifNoneMatch
        self.ifModifiedSince = ifModifiedSince
    }

    public var isEmpty: Bool {
        ifNoneMatch == nil && ifModifiedSince == nil
    }

    public func applying(to request: inout URLRequest) {
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        if let ifModifiedSince {
            request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }
    }
}

public enum PodcastFeedConditionalRequestPolicy {
    /// Whether a recent (non-full) refresh may send conditional validators.
    ///
    /// Conditional headers are sent only when:
    /// - mode is `.recent`
    /// - local catalog baseline exists
    /// - stored validators match the current feed URL
    /// - at least one validator value is present
    public static func conditionalHeaders(
        validators: PodcastFeedValidators?,
        currentFeedURL: URL,
        mode: PodcastCatalogFetchMode,
        hasLocalCatalogBaseline: Bool
    ) -> PodcastFeedConditionalHeaders? {
        guard case .recent = mode else { return nil }
        guard hasLocalCatalogBaseline else { return nil }
        guard let validators, validators.hasAnyValidator else { return nil }
        let current = currentFeedURL.absoluteString
        guard validators.feedURL == current else { return nil }
        return PodcastFeedConditionalHeaders(
            ifNoneMatch: validators.etag,
            ifModifiedSince: validators.lastModified
        )
    }

    /// Interprets an HTTP status for conditional RSS fetches.
    public static func responseAction(
        statusCode: Int,
        hasLocalCatalogBaseline: Bool
    ) -> PodcastFeedConditionalResponseAction {
        switch statusCode {
        case 304:
            return hasLocalCatalogBaseline ? .acceptNotModified : .retryUnconditionally
        case 412:
            return .retryUnconditionally
        case 200..<300:
            return .acceptModified
        default:
            return .rejectHTTP
        }
    }

    /// Builds updated validators from a successful response.
    /// Missing response headers clear the corresponding previous value.
    public static func validators(
        from response: HTTPURLResponse,
        feedURL: URL,
        previous: PodcastFeedValidators?
    ) -> PodcastFeedValidators {
        let headers = normalizedHeaderFields(response.allHeaderFields)
        let etag = headers["etag"]
        let lastModified = headers["last-modified"]
        // A 200 without a given validator header clears that stored value.
        // When the status is 304, keep previous values if the header is absent.
        if response.statusCode == 304 {
            return PodcastFeedValidators(
                etag: etag ?? previous?.etag,
                lastModified: lastModified ?? previous?.lastModified,
                feedURL: feedURL.absoluteString
            )
        }
        return PodcastFeedValidators(
            etag: etag,
            lastModified: lastModified,
            feedURL: feedURL.absoluteString
        )
    }

    private static func normalizedHeaderFields(
        _ fields: [AnyHashable: Any]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in fields {
            guard let name = key as? String else { continue }
            let stringValue: String
            if let value = value as? String {
                stringValue = value
            } else {
                stringValue = String(describing: value)
            }
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result[name.lowercased()] = trimmed
        }
        return result
    }
}

public enum PodcastFeedConditionalResponseAction: Equatable, Sendable {
    case acceptModified
    case acceptNotModified
    case retryUnconditionally
    case rejectHTTP
}
