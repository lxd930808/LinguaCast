import Foundation
import CloudSyncKit

// App-side bridge for the V10 cloud content gateway (WP10). All wire logic
// lives in CloudSyncKit; this file only adapts app configuration and keychain
// storage into the gateway types.

enum CloudContentGatewayFactory {

    /// Builds a job client from the committed app configuration, or nil when
    /// cloud generation is not usable (disabled, missing token or bad URL).
    static func makeClient(configuration: AppConfiguration) -> CloudContentJobClient? {
        guard configuration.isCloudGenerationUsable else { return nil }
        return makeClientIfCredentialsPresent(configuration: configuration)
    }

    /// Artifact fetch for assistant playback: needs URL + token, not the
    /// local "cloud generation" toggle. The V10 job already exists server-side.
    static func makeClientIfCredentialsPresent(configuration: AppConfiguration) -> CloudContentJobClient? {
        let token = configuration.contentServiceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, URL(string: configuration.normalizedContentServiceBaseURL) != nil else {
            return nil
        }
        return try? CloudContentJobClient.makeDefault(
            baseURLString: configuration.normalizedContentServiceBaseURL,
            tokenProvider: StaticContentTokenProvider(token: token)
        )
    }

    /// Keychain-backed token provider for the content service. Preferred when
    /// the token should be read fresh on every request (e.g. after iCloud
    /// keychain sync rotated it).
    static func makeKeychainTokenProvider(keychain: KeychainStore = KeychainStore())
        -> KeychainContentTokenProvider {
        KeychainContentTokenProvider(store: keychain)
    }
}
