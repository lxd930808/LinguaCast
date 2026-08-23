import Foundation
import PodcastEnglishStudioCore
import CloudSyncKit

/// Adapts PodcastFeedService to the RSS fetch CloudSyncKit needs for targeted recovery.
/// Reuses the existing Apple Podcasts link resolution and retried download logic.
/// Always downloads unconditionally — recovery cannot rely on 304 because raw XML is not stored.
extension PodcastFeedService: PodcastFeedDataFetching {
    public func fetchFeedData(sourceURL: String) async throws -> Data {
        guard let inputURL = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PodcastFeedError.invalidURL
        }
        let feedURL = try await resolveFeedURL(from: inputURL)
        let (data, _) = try await withNetworkRetries(operation: "catalog recovery feed download") {
            try await self.session.data(from: feedURL)
        }
        return data
    }
}

enum PodcastFeedError: LocalizedError {
    case invalidURL
    case unsupportedAppleChannel
    case missingFeedURL
    case missingEpisodeAudio
    case invalidHTTPStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            L10n.string("error.podcast_invalid_url", fallback: "The Podcast URL is invalid.")
        case .unsupportedAppleChannel:
            L10n.string("error.podcast_unsupported_channel", fallback: "This Apple Podcasts link is not an individual show. Add a show link or RSS feed.")
        case .missingFeedURL:
            L10n.string("error.podcast_missing_feed", fallback: "The Podcast RSS feed could not be resolved.")
        case .missingEpisodeAudio:
            L10n.string("error.podcast_missing_audio", fallback: "The Podcast feed does not include any playable audio episodes.")
        case .invalidHTTPStatus(let code):
            L10n.format(
                "error.podcast_feed_http",
                fallback: "The Podcast RSS feed returned HTTP %@.",
                String(code)
            )
        }
    }
}

private enum PodcastFeedDownloadResult {
    case modified(Data, validators: PodcastFeedValidators)
    case notModified(validators: PodcastFeedValidators)
}

final class PodcastFeedService: @unchecked Sendable {
    let session: URLSession
    private let appleLookupClient: ApplePodcastLookupClient

    init(session: URLSession = .shared) {
        self.session = session
        self.appleLookupClient = ApplePodcastLookupClient(session: session)
    }

    func resolveFeed(
        from showURL: String,
        knownFeedURL: String? = nil,
        mode: PodcastCatalogFetchMode = .recent(limit: 50),
        validators: PodcastFeedValidators? = nil,
        hasLocalCatalogBaseline: Bool = false
    ) async throws -> PodcastFeedRefreshResult {
        guard let inputURL = URL(string: showURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PodcastFeedError.invalidURL
        }
        let source = try await resolveSource(
            inputURL: inputURL,
            knownFeedURL: knownFeedURL
        )
        do {
            return try await loadResolvedFeed(
                source: source,
                mode: mode,
                validators: validators,
                hasLocalCatalogBaseline: hasLocalCatalogBaseline
            )
        } catch {
            guard knownFeedURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  PodcastSubscriptionURLInspector.applePodcastID(from: inputURL) != nil
            else {
                throw error
            }

            // A saved feed normally avoids Apple entirely. If it stops working, refresh the
            // address with the deterministic show-ID lookup and retry once.
            // Clear validators: the feed URL may change after Apple fallback.
            let refreshedSource = try await resolveSource(inputURL: inputURL, knownFeedURL: nil)
            guard refreshedSource.feedURL != source.feedURL else {
                throw error
            }
            return try await loadResolvedFeed(
                source: refreshedSource,
                mode: mode,
                validators: nil,
                hasLocalCatalogBaseline: hasLocalCatalogBaseline
            )
        }
    }

    private func loadResolvedFeed(
        source: ResolvedPodcastSource,
        mode: PodcastCatalogFetchMode,
        validators: PodcastFeedValidators?,
        hasLocalCatalogBaseline: Bool
    ) async throws -> PodcastFeedRefreshResult {
        let feedURL = source.feedURL
        let download = try await withNetworkRetries(operation: "subscription feed download") {
            try await self.downloadFeedData(
                feedURL: feedURL,
                validators: validators,
                mode: mode,
                hasLocalCatalogBaseline: hasLocalCatalogBaseline
            )
        }
        switch download {
        case .notModified(let nextValidators):
            return .notModified(validators: nextValidators)
        case .modified(let data, let nextValidators):
            let feed = try PodcastFeedParser().parse(data: data, feedURL: feedURL)
            let allEpisodes = PodcastFeedOrderingPolicy.newestFirst(feed.episodes)
            guard !allEpisodes.isEmpty else {
                throw PodcastFeedError.missingEpisodeAudio
            }
            let show = PodcastShowMetadataPolicy.merging(rss: feed.show, apple: source.appleMetadata)
            let resolved = ResolvedPodcastFeed(
                show: show,
                episodes: PodcastCatalogSelectionPolicy.select(allEpisodes, mode: mode),
                allEpisodeGUIDs: Set(allEpisodes.map(\.guid)),
                feedURL: feedURL
            )
            return .modified(resolved, validators: nextValidators)
        }
    }

    fileprivate func downloadFeedData(
        feedURL: URL,
        validators: PodcastFeedValidators?,
        mode: PodcastCatalogFetchMode,
        hasLocalCatalogBaseline: Bool
    ) async throws -> PodcastFeedDownloadResult {
        try await downloadFeedData(
            feedURL: feedURL,
            validators: validators,
            mode: mode,
            hasLocalCatalogBaseline: hasLocalCatalogBaseline,
            allowUnconditionalRetry: true
        )
    }

    private func downloadFeedData(
        feedURL: URL,
        validators: PodcastFeedValidators?,
        mode: PodcastCatalogFetchMode,
        hasLocalCatalogBaseline: Bool,
        allowUnconditionalRetry: Bool
    ) async throws -> PodcastFeedDownloadResult {
        var request = URLRequest(url: feedURL)
        let headers = PodcastFeedConditionalRequestPolicy.conditionalHeaders(
            validators: validators,
            currentFeedURL: feedURL,
            mode: mode,
            hasLocalCatalogBaseline: hasLocalCatalogBaseline
        )
        headers?.applying(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PodcastFeedError.invalidHTTPStatus(-1)
        }

        let action = PodcastFeedConditionalRequestPolicy.responseAction(
            statusCode: http.statusCode,
            hasLocalCatalogBaseline: hasLocalCatalogBaseline
        )
        switch action {
        case .acceptNotModified:
            let next = PodcastFeedConditionalRequestPolicy.validators(
                from: http,
                feedURL: feedURL,
                previous: validators
            )
            return .notModified(validators: next)
        case .acceptModified:
            let next = PodcastFeedConditionalRequestPolicy.validators(
                from: http,
                feedURL: feedURL,
                previous: validators
            )
            return .modified(data, validators: next)
        case .retryUnconditionally:
            guard allowUnconditionalRetry else {
                throw PodcastFeedError.invalidHTTPStatus(http.statusCode)
            }
            return try await downloadFeedData(
                feedURL: feedURL,
                validators: nil,
                mode: mode,
                hasLocalCatalogBaseline: hasLocalCatalogBaseline,
                allowUnconditionalRetry: false
            )
        case .rejectHTTP:
            throw PodcastFeedError.invalidHTTPStatus(http.statusCode)
        }
    }

    func resolveFeedURL(from url: URL) async throws -> URL {
        if PodcastSubscriptionURLInspector.isUnsupportedAppleChannel(url) {
            throw PodcastFeedError.unsupportedAppleChannel
        }
        if url.absoluteString.hasSuffix(".xml") || url.host()?.contains("feeds.") == true {
            return url
        }
        if let id = PodcastSubscriptionURLInspector.applePodcastID(from: url) {
            let payload = try await lookupPodcast(id: id)
            if let feed = payload.feedUrl, let feedURL = URL(string: feed) {
                return feedURL
            }
        }
        if url.scheme == "https" || url.scheme == "http" {
            return url
        }
        throw PodcastFeedError.missingFeedURL
    }

    private func resolveSource(
        inputURL: URL,
        knownFeedURL: String?
    ) async throws -> ResolvedPodcastSource {
        if let knownFeedURL = knownFeedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !knownFeedURL.isEmpty,
           let url = URL(string: knownFeedURL) {
            return ResolvedPodcastSource(feedURL: url, appleMetadata: nil)
        }
        if PodcastSubscriptionURLInspector.isUnsupportedAppleChannel(inputURL) {
            throw PodcastFeedError.unsupportedAppleChannel
        }
        if let id = PodcastSubscriptionURLInspector.applePodcastID(from: inputURL) {
            let result = try await lookupPodcast(id: id)
            guard let feed = result.feedUrl, let feedURL = URL(string: feed) else {
                throw PodcastFeedError.missingFeedURL
            }
            let artwork = result.artworkUrl600 ?? result.artworkUrl100
            let appleMetadata = PodcastShowInfo(
                title: result.collectionName ?? "",
                author: result.artistName ?? "",
                feedURL: feedURL,
                artworkURL: artwork.flatMap(URL.init(string:)),
                websiteURL: nil,
                applePodcastsURL: (result.collectionViewUrl.flatMap(URL.init(string:))) ?? inputURL,
                artworkSource: artwork == nil ? nil : .apple
            )
            return ResolvedPodcastSource(feedURL: feedURL, appleMetadata: appleMetadata)
        }
        return ResolvedPodcastSource(
            feedURL: try await resolveFeedURL(from: inputURL),
            appleMetadata: nil
        )
    }

    private func lookupPodcast(id: String) async throws -> ApplePodcastLookupResult {
        do {
            return try await withNetworkRetries(operation: "Apple Podcasts subscription resolution") {
                try await self.appleLookupClient.lookup(id: id)
            }
        } catch ApplePodcastLookupError.noResults {
            throw PodcastFeedError.missingFeedURL
        }
    }
}

private struct ResolvedPodcastSource {
    var feedURL: URL
    var appleMetadata: PodcastShowInfo?
}
