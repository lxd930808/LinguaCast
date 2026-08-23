import Foundation
import Kingfisher

/// Bounded artwork prefetcher shared across Home / Programs / Episode player.
@MainActor
final class ArtworkPrefetchService {
    static let shared = ArtworkPrefetchService()

    static let maxURLsPerPage = 20
    static let maxConcurrentDownloads = 3

    private var activePrefetcher: ImagePrefetcher?
    private var activeToken: String?

    /// Prefetch originals (no display-size processor) so list / home / detail can reuse one download.
    /// Suspends until cancelled so `.task(id:)` teardown stops unfinished work.
    func prefetchUntilCancelled(urls: [URL], token: String) async {
        guard !UITestSupport.isEnabled else { return }
        let unique = ArtworkPrefetchPolicy.deduplicated(urls, limit: Self.maxURLsPerPage)
        guard !unique.isEmpty else {
            cancel(matching: token)
            return
        }
        if activeToken != token || activePrefetcher == nil {
            cancel()
            activeToken = token
            let prefetcher = ImagePrefetcher(
                urls: unique,
                options: [.cacheOriginalImage, .backgroundDecode]
            )
            prefetcher.maxConcurrentDownloads = Self.maxConcurrentDownloads
            activePrefetcher = prefetcher
            prefetcher.start()
        }
        defer { cancel(matching: token) }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                break
            }
        }
    }

    func cancel(matching token: String? = nil) {
        if let token, activeToken != token { return }
        activePrefetcher?.stop()
        activePrefetcher = nil
        activeToken = nil
    }
}

enum ArtworkPrefetchPolicy {
    /// Prefer continue-playing URLs, then ready/completed catalog items.
    static func prioritizedURLs(
        continuePlaying: [URL],
        readyCatalog: [URL],
        limit: Int = ArtworkPrefetchService.maxURLsPerPage
    ) -> [URL] {
        deduplicated(continuePlaying + readyCatalog, limit: limit)
    }

    /// Current episode artwork plus the two previous and two next episodes by publish date.
    static func playerNeighborURLs(
        current: URL?,
        orderedEpisodeURLs: [URL],
        currentIndex: Int?
    ) -> [URL] {
        var urls: [URL] = []
        if let current {
            urls.append(current)
        }
        guard let currentIndex, !orderedEpisodeURLs.isEmpty else {
            return deduplicated(urls)
        }
        let lower = max(currentIndex - 2, 0)
        let upper = min(currentIndex + 2, orderedEpisodeURLs.count - 1)
        if lower <= upper {
            urls.append(contentsOf: orderedEpisodeURLs[lower...upper])
        }
        return deduplicated(urls)
    }

    static func deduplicated(
        _ urls: [URL],
        limit: Int = ArtworkPrefetchService.maxURLsPerPage
    ) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        result.reserveCapacity(min(urls.count, limit))
        for url in urls {
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(url)
            if result.count >= limit { break }
        }
        return result
    }
}
