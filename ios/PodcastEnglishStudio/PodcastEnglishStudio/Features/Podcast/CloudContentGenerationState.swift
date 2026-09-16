import Foundation
import DomainModels
import CloudSyncKit

// V10 / WP14 — shared observable cloud-generation state.
//
// Both detail screens (podcast episode and video player) project the same six
// observable fields so iOS and tvOS keep identical state semantics:
// queued / stage / audioReady / subtitlesReady / retryable / lastUpdated.
// The types here are pure values and policies; SwiftUI observes the underlying
// SwiftData records (EpisodeRecord / YTVideoRecord) and the snapshot below.

/// Sendable value copy of the remote-job fields the UI needs. Signed playback
/// URLs and tokens are never part of this snapshot.
struct CloudRemoteJobSnapshot: Equatable, Sendable {
    var jobID: String
    var statusRaw: String
    var stageRaw: String?
    var progress: Double
    var audioReady: Bool
    var subtitlesReady: Bool
    var errorCode: String?
    /// nil means the server did not provide the flag (local/legacy failure).
    var errorRetryable: Bool?
    var updatedAt: Date

    init(record: RemoteContentJobRecord) {
        jobID = record.jobID
        statusRaw = record.statusRaw
        stageRaw = record.stageRaw
        progress = record.progress
        audioReady = record.audioReady
        subtitlesReady = record.subtitlesReady
        errorCode = record.errorCode
        // RemoteContentJobRecord stores false both for "server said not
        // retryable" and "no error recorded"; treat the flag as authoritative
        // only when a failure code is present.
        errorRetryable = record.errorCode != nil ? record.errorRetryable : nil
        updatedAt = record.updatedAt
    }
}

/// The shared observable state surface (WP14 task 1). `stageRaw` keeps the
/// raw pipeline step / cloud stage string; localized titles stay in the view
/// layer (`progressStepTitle` / `YTSourceGenerationProgressText`).
struct CloudContentGenerationState: Equatable, Sendable {
    var isQueued: Bool
    var stageRaw: String?
    var progress: Double?
    var audioReady: Bool
    var subtitlesReady: Bool
    var retryable: Bool
    var lastUpdated: Date?
    /// Raw failure message; render through `CloudErrorMessagePresenter.display`.
    var errorMessage: String?

    /// Podcast projection: episode display fields plus the remote record when
    /// the cloud backend produced one. Local (legacy) mode stays untouched:
    /// retryable defaults to true and no remote flags are consulted.
    static func podcast(
        episode: EpisodeRecord,
        snapshot: CloudRemoteJobSnapshot?,
        cloudSelected: Bool
    ) -> CloudContentGenerationState {
        let errorCode = snapshot?.errorCode
            ?? CloudErrorMessagePresenter.errorCode(fromMessage: episode.errorMessage)
        return CloudContentGenerationState(
            isQueued: episode.status == "queued",
            stageRaw: snapshot?.stageRaw ?? episode.pipelineStep,
            progress: episode.pipelineProgress,
            audioReady: snapshot?.audioReady ?? false,
            subtitlesReady: snapshot?.subtitlesReady ?? (episode.status == "completed"),
            retryable: cloudSelected
                ? CloudRetryPolicy.isRetryable(errorCode: errorCode, serverRetryable: snapshot?.errorRetryable)
                : true,
            lastUpdated: snapshot?.updatedAt ?? episode.updatedAt,
            errorMessage: episode.errorMessage
        )
    }

    /// Video projection: the WP13 pipeline writes cloud state onto
    /// YTVideoRecord (subtitleStatus "generating", sourceGenerationStep,
    /// lastError with a [CODE] suffix), so no store access is needed here.
    static func video(video: YTVideoRecord) -> CloudContentGenerationState {
        let errorCode = CloudErrorMessagePresenter.errorCode(fromMessage: video.lastError)
        return CloudContentGenerationState(
            isQueued: video.subtitleStatus == "generating"
                && (video.sourceGenerationStep == nil || video.sourceGenerationStep == "queued"),
            stageRaw: video.sourceGenerationStep,
            progress: video.sourceGenerationProgress,
            audioReady: false,
            subtitlesReady: video.bilingualSubtitlesCompleted || video.subtitleStatus == "ready",
            retryable: CloudRetryPolicy.isRetryable(errorCode: errorCode, serverRetryable: nil),
            lastUpdated: video.recordUpdatedAt,
            errorMessage: video.lastError
        )
    }
}

/// Whether a failed generation may offer a direct Retry action. The server
/// `retryable` flag wins when present; otherwise the stable error-code
/// category decides (rate limits / transient failures retry, restricted or
/// gone sources and fatal pipeline errors do not). Unknown / missing codes
/// stay retryable so the legacy local pipeline behavior never regresses.
enum CloudRetryPolicy {
    static func isRetryable(errorCode: String?, serverRetryable: Bool? = nil) -> Bool {
        if let serverRetryable { return serverRetryable }
        guard let errorCode, !errorCode.isEmpty else { return true }
        switch CloudErrorPresentationPolicy.category(forCode: errorCode) {
        case .retryableFailure, .rateLimited, .capacity, .unknown:
            return true
        case .needsUpgrade, .sourceGone, .sourceRestricted, .fatalFailure:
            return false
        }
    }
}

/// Display-time localization for cloud failure messages. WP11/WP13 services
/// (frozen lane) persist plain-English messages with a stable machine code —
/// either "<base> [CODE]" (video) or "CODE: <message>" (podcast) or a bare
/// known client code. Views route every persisted cloud error through here so
/// the user-facing text is localized while the [CODE] suffix stays for
/// diagnostics and screenshots.
enum CloudErrorMessagePresenter {

    /// Extracts the stable cloud error code from a persisted message, or nil
    /// when the message is an ordinary localized/free-form string.
    static func errorCode(fromMessage message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("]"),
           let open = trimmed.lastIndex(of: "[") {
            let code = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            if isCodeLike(code) { return code }
        }
        if let colon = trimmed.firstIndex(of: ":") {
            let code = String(trimmed[..<colon])
            if isCodeLike(code) { return code }
        }
        if isCodeLike(trimmed) { return trimmed }
        return nil
    }

    /// Localized display text for a persisted cloud failure. Messages without
    /// a recognizable code pass through unchanged (legacy local errors).
    static func display(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }
        guard let code = errorCode(fromMessage: raw) else { return raw }
        return "\(localizedBase(for: code)) [\(code)]"
    }

    static func localizedBase(for code: String) -> String {
        switch code {
        case "CLOUD_NOT_CONFIGURED", "cloud_service_not_configured":
            return L10n.string(
                "cloud.error.not_configured",
                fallback: "Cloud generation is enabled but the content service is not configured."
            )
        case "cloud_service_unreachable":
            return L10n.string(
                "cloud.error.unreachable",
                fallback: "The content service is unreachable. Check the network and the service base URL."
            )
        case "cloud_unauthorized":
            return L10n.string(
                "cloud.error.unauthorized",
                fallback: "The content service rejected the access token. Update it in Settings."
            )
        case "cloud_invalid_response":
            return L10n.string(
                "cloud.error.invalid_response",
                fallback: "The content service returned an invalid response."
            )
        case "LOCAL_PIPELINE_REMOVED":
            return L10n.string(
                "cloud.error.local_pipeline_removed",
                fallback: "On-device processing is no longer available. Tap Retry to process this episode in the cloud."
            )
        case "QUOTA_EXCEEDED":
            return L10n.string(
                "cloud.error.quota_exceeded",
                fallback: "Today's free processing time is used up. It resets at midnight China Standard Time."
            )
        case "QUOTA_REQUEST_TOO_LARGE":
            return L10n.string(
                "cloud.error.quota_request_too_large",
                fallback: "This item is longer than the free daily processing time."
            )
        default:
            break
        }
        switch CloudErrorPresentationPolicy.category(forCode: code) {
        case .needsUpgrade:
            return L10n.string(
                "cloud.error.needs_upgrade",
                fallback: "Update the app to keep using the cloud content service."
            )
        case .sourceGone:
            return L10n.string(
                "cloud.error.source_gone",
                fallback: "This video is no longer available on the source platform."
            )
        case .sourceRestricted:
            return L10n.string(
                "cloud.error.source_restricted",
                fallback: "The source platform restricts this video (region, age, or login)."
            )
        case .rateLimited:
            return L10n.string(
                "cloud.error.rate_limited",
                fallback: "The source platform is rate limiting requests. Try again later."
            )
        case .capacity:
            return L10n.string(
                "cloud.error.capacity",
                fallback: "The content service is at capacity. Try again later."
            )
        case .retryableFailure:
            return L10n.string(
                "cloud.error.retryable",
                fallback: "Cloud subtitle generation failed; a retry may succeed."
            )
        case .fatalFailure:
            return L10n.string(
                "cloud.error.fatal",
                fallback: "Cloud subtitle generation cannot process this video."
            )
        case .unknown:
            return L10n.string(
                "cloud.error.unknown",
                fallback: "Cloud subtitle generation failed."
            )
        }
    }

    /// Client-side codes produced by the WP11 podcast gateway mapping (lowercase).
    private static let knownClientCodes: Set<String> = [
        "cloud_service_not_configured",
        "cloud_service_unreachable",
        "cloud_unauthorized",
        "cloud_invalid_response"
    ]

    private static func isCodeLike(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 48, !value.contains(" ") else { return false }
        if knownClientCodes.contains(value) { return true }
        // Server codes are SNAKE_CASE_UPPER (e.g. SOURCE_RESTRICTED).
        guard value.contains("_") else { return false }
        return value.allSatisfy { character in
            character == "_" || (character.isLetter && character.isUppercase)
        }
    }
}

/// The content-service token is never displayed in full: settings show only a
/// masked form, and screenshots / debug dumps never contain the raw value.
enum CloudTokenMasking {
    static func masked(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "••••••••" + trimmed.suffix(4)
    }
}
