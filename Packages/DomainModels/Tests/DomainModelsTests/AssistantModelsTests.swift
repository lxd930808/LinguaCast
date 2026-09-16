import Foundation
import Testing
@testable import DomainModels

@Suite("Assistant shared models contract")
struct AssistantModelsTests {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/Assistant")

    static func fixture(_ name: String) -> Data {
        let url = fixturesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            Issue.record("missing fixture \(name) at \(url.path)")
            return Data()
        }
        return data
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct SearchResultList: Decodable {
        var results: [AssistantSearchResult]
    }

    @Test("error envelope decodes")
    func decodeErrorEnvelope() throws {
        let error = try Self.decoder().decode(
            AssistantErrorEnvelope.self,
            from: Self.fixture("error-envelope-transcript-not-ready.json")
        )
        #expect(error.error.code == "TRANSCRIPT_NOT_READY")
        #expect(error.error.retryable)
    }

    @Test("youtube fallback and podcast RSS search results decode")
    func decodeSearchFixtures() throws {
        let youtube = try Self.decoder().decode(
            SearchResultList.self,
            from: Self.fixture("search-results-youtube-fallback.json")
        )
        #expect(youtube.results.first?.fallback == true)
        let podcasts = try Self.decoder().decode(
            SearchResultList.self,
            from: Self.fixture("search-results-podcast-rss.json")
        )
        #expect(podcasts.results.contains(where: { $0.sourceType == .podcastEpisode }))
        let episode = try #require(podcasts.results.first { $0.sourceType == .podcastEpisode })
        #expect(episode.enclosureUrl == "https://cdn.example.com/ai-ledger.mp3")
        #expect(episode.playbackAudioURL == "https://cdn.example.com/ai-ledger.mp3")
        #expect(episode.canonicalURL.contains("podcasts.apple.com"))
    }
}
