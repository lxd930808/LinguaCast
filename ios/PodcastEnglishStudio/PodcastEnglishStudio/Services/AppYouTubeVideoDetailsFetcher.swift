import Foundation
import CloudSyncKit

/// Adapts YTLocalService to the video-details fetch CloudSyncKit needs for targeted recovery.
/// Reads the current configuration lazily via a MainActor closure so a not-yet-entered
/// API key is not frozen at app startup.
final class AppYouTubeVideoDetailsFetcher: YouTubeVideoDetailsFetching, @unchecked Sendable {
    private let service: YTLocalService
    private let configurationProvider: @MainActor () -> AppConfiguration

    init(
        service: YTLocalService,
        configurationProvider: @escaping @MainActor () -> AppConfiguration
    ) {
        self.service = service
        self.configurationProvider = configurationProvider
    }

    func fetchVideoDetails(videoIDs: Set<String>) async throws -> [String: YouTubeVideoDetails] {
        let configuration = await configurationProvider()
        return try await service.fetchVideoDetailsByIDs(videoIDs, configuration: configuration)
    }
}
