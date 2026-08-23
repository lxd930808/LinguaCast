import Foundation

public enum ApplePodcastLookupError: Error {
    case invalidRequest
    case invalidResponse
    case noResults
}

public struct ApplePodcastLookupResult: Decodable, Equatable, Sendable {
    public var feedUrl: String?
    public var artistName: String?
    public var collectionName: String?
    public var collectionViewUrl: String?
    public var artworkUrl100: String?
    public var artworkUrl600: String?
}

public final class ApplePodcastLookupClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lookup(id: String) async throws -> ApplePodcastLookupResult {
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else {
            throw ApplePodcastLookupError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "entity", value: "podcast")
        ]
        guard let url = components.url else {
            throw ApplePodcastLookupError.invalidRequest
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode
        else {
            throw ApplePodcastLookupError.invalidResponse
        }
        let payload = try JSONDecoder().decode(ApplePodcastLookupResponse.self, from: data)
        guard let result = payload.results.first else {
            throw ApplePodcastLookupError.noResults
        }
        return result
    }
}

private struct ApplePodcastLookupResponse: Decodable {
    var results: [ApplePodcastLookupResult]
}
