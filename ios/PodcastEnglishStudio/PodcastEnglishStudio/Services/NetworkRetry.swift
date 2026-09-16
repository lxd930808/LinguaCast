import Foundation
import PodcastEnglishStudioCore

// Shared request error type and transient-network retry helper used by feed
// refresh, the content filter, YouTube metadata and cloud artifact flows.
// Extracted from the on-device pipeline clients removed in V18.

enum PipelineError: LocalizedError {
    case missingConfiguration(String)
    case badResponse(String)
    case transientNetworkFailure(String, Int)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            L10n.string("error.missing_configuration", fallback: "Required configuration is missing. Check Settings and try again.")
        case .badResponse(let value):
            L10n.format("error.request_failed_detail", fallback: "The request could not be completed.\nDetails: %@", value)
        case .transientNetworkFailure(_, let attempts):
            L10n.format("error.network_failed", fallback: "The network request failed after %@ attempts. Check your connection and try again.", String(attempts))
        }
    }
}

func withNetworkRetries<T>(
    operation: String,
    maxAttempts: Int = 3,
    _ work: @escaping () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as URLError where error.isTransientNetworkError {
            if attempt >= maxAttempts {
                throw PipelineError.transientNetworkFailure(operation, maxAttempts)
            }
            try await Task.sleep(nanoseconds: UInt64(attempt * 3) * 1_000_000_000)
            attempt += 1
        } catch {
            throw error
        }
    }
}

private extension URLError {
    var isTransientNetworkError: Bool {
        switch code {
        case .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            true
        default:
            false
        }
    }
}
