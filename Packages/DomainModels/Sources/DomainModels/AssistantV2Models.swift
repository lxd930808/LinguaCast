import Foundation

// Assistant API DTOs (V15 / WP15). Wire format is frozen by
// docs/contracts/assistant-v2.openapi.yaml. Unknown enum values decode to
// .unknown(raw) and never crash. Unknown JSON fields are ignored.
// Client models never include real filesystem paths.

// MARK: - Open string enums

public enum AssistantV2ResearchStatus: Hashable, Sendable {
    case creating
    case ready
    case deleting
    case deleted
    case failed
    case degraded
    case corrupt
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .creating: return "creating"
        case .ready: return "ready"
        case .deleting: return "deleting"
        case .deleted: return "deleted"
        case .failed: return "failed"
        case .degraded: return "degraded"
        case .corrupt: return "corrupt"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "creating": self = .creating
        case "ready": self = .ready
        case "deleting": self = .deleting
        case "deleted": self = .deleted
        case "failed": self = .failed
        case "degraded": self = .degraded
        case "corrupt": self = .corrupt
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2ResearchStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2TurnMode: Hashable, Sendable {
    case research
    case contentQA
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .research: return "research"
        case .contentQA: return "content_qa"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "research": self = .research
        case "content_qa": self = .contentQA
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2TurnMode: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2TurnStatus: Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case interrupted
    case unknown(String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        case .queued, .running, .unknown: return false
        }
    }

    public var rawValue: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .interrupted: return "interrupted"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "queued": self = .queued
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "interrupted": self = .interrupted
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2TurnStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2ArtifactKind: Hashable, Sendable {
    case webSearch
    case webPage
    case podcastSearch
    case youtubeSearch
    case transcript
    case researchMemory
    case report
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .webSearch: return "web_search"
        case .webPage: return "web_page"
        case .podcastSearch: return "podcast_search"
        case .youtubeSearch: return "youtube_search"
        case .transcript: return "transcript"
        case .researchMemory: return "research_memory"
        case .report: return "report"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "web_search": self = .webSearch
        case "web_page": self = .webPage
        case "podcast_search": self = .podcastSearch
        case "youtube_search": self = .youtubeSearch
        case "transcript": self = .transcript
        case "research_memory": self = .researchMemory
        case "report": self = .report
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2ArtifactKind: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2ArtifactStatus: Hashable, Sendable {
    case pending
    case ready
    case superseded
    case failed
    case corrupt
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .ready: return "ready"
        case .superseded: return "superseded"
        case .failed: return "failed"
        case .corrupt: return "corrupt"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "ready": self = .ready
        case "superseded": self = .superseded
        case "failed": self = .failed
        case "corrupt": self = .corrupt
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2ArtifactStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2EvidenceLevel: Hashable, Sendable {
    case searchMetadata
    case primaryContent
    case transcript
    case researchNote
    case userPreference
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .searchMetadata: return "search_metadata"
        case .primaryContent: return "primary_content"
        case .transcript: return "transcript"
        case .researchNote: return "research_note"
        case .userPreference: return "user_preference"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "search_metadata": self = .searchMetadata
        case "primary_content": self = .primaryContent
        case "transcript": self = .transcript
        case "research_note": self = .researchNote
        case "user_preference": self = .userPreference
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2EvidenceLevel: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2GrantPermission: Hashable, Sendable {
    case read
    case readWrite
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .read: return "read"
        case .readWrite: return "read_write"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "read": self = .read
        case "read_write": self = .readWrite
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2GrantPermission: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2GrantStatus: Hashable, Sendable {
    case ready
    case unavailable
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .ready: return "ready"
        case .unavailable: return "unavailable"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "ready": self = .ready
        case "unavailable": self = .unavailable
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2GrantStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2MemoryScope: Hashable, Sendable {
    case research
    case global
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .research: return "research"
        case .global: return "global"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "research": self = .research
        case "global": self = .global
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2MemoryScope: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2MemoryProposalStatus: Hashable, Sendable {
    case pending
    case confirmed
    case rejected
    case expired
    case unknown(String)

    public var isTerminal: Bool {
        switch self {
        case .confirmed, .rejected, .expired: return true
        case .pending, .unknown: return false
        }
    }

    public var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .confirmed: return "confirmed"
        case .rejected: return "rejected"
        case .expired: return "expired"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "confirmed": self = .confirmed
        case "rejected": self = .rejected
        case "expired": self = .expired
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2MemoryProposalStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2TranscriptJobStatus: Hashable, Sendable {
    case requested
    case waitingService
    case running
    case installing
    case ready
    case failedRetryable
    case failedTerminal
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .requested: return "requested"
        case .waitingService: return "waiting_service"
        case .running: return "running"
        case .installing: return "installing"
        case .ready: return "ready"
        case .failedRetryable: return "failed_retryable"
        case .failedTerminal: return "failed_terminal"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "requested": self = .requested
        case "waiting_service": self = .waitingService
        case "running": self = .running
        case "installing": self = .installing
        case "ready": self = .ready
        case "failed_retryable": self = .failedRetryable
        case "failed_terminal": self = .failedTerminal
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2TranscriptJobStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2MessageRole: Hashable, Sendable {
    case user
    case assistant
    case systemSummary
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .systemSummary: return "system_summary"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "assistant": self = .assistant
        case "system_summary": self = .systemSummary
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2MessageRole: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2GrepMode: Hashable, Sendable {
    case literal
    case regex
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .literal: return "literal"
        case .regex: return "regex"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "literal": self = .literal
        case "regex": self = .regex
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2GrepMode: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2ArtifactEncoding: Hashable, Sendable {
    case utf8
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .utf8: return "utf-8"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "utf-8": self = .utf8
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantV2ArtifactEncoding: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AssistantV2SseEventType: Hashable, Sendable {
    case workspaceCreated
    case researchTitleUpdated
    case webSearchStarted
    case webSearchCompleted
    case webSearchFailed
    case webPageSaved
    case sourceSaved
    case transcriptJobUpdated
    case transcriptSaved
    case memoryUpdated
    case memoryProposed
    case thinkingStarted
    case thinkingDelta
    case thinkingCompleted
    case toolStarted
    case toolCompleted
    case reportDelta
    case reportCompleted
    case turnStarted
    case turnCompleted
    case turnFailed
    case turnCancelled
    case heartbeat
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "workspace.created": self = .workspaceCreated
        case "research.title_updated": self = .researchTitleUpdated
        case "web.search_started": self = .webSearchStarted
        case "web.search_completed": self = .webSearchCompleted
        case "web.search_failed": self = .webSearchFailed
        case "web.page_saved": self = .webPageSaved
        case "source.saved": self = .sourceSaved
        case "transcript.job_updated": self = .transcriptJobUpdated
        case "transcript.saved": self = .transcriptSaved
        case "memory.updated": self = .memoryUpdated
        case "memory.proposed": self = .memoryProposed
        case "thinking.started": self = .thinkingStarted
        case "thinking.delta": self = .thinkingDelta
        case "thinking.completed": self = .thinkingCompleted
        case "tool.started": self = .toolStarted
        case "tool.completed": self = .toolCompleted
        case "report.delta": self = .reportDelta
        case "report.completed": self = .reportCompleted
        case "turn.started": self = .turnStarted
        case "turn.completed": self = .turnCompleted
        case "turn.failed": self = .turnFailed
        case "turn.cancelled": self = .turnCancelled
        case "heartbeat": self = .heartbeat
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .workspaceCreated: return "workspace.created"
        case .researchTitleUpdated: return "research.title_updated"
        case .webSearchStarted: return "web.search_started"
        case .webSearchCompleted: return "web.search_completed"
        case .webSearchFailed: return "web.search_failed"
        case .webPageSaved: return "web.page_saved"
        case .sourceSaved: return "source.saved"
        case .transcriptJobUpdated: return "transcript.job_updated"
        case .transcriptSaved: return "transcript.saved"
        case .memoryUpdated: return "memory.updated"
        case .memoryProposed: return "memory.proposed"
        case .thinkingStarted: return "thinking.started"
        case .thinkingDelta: return "thinking.delta"
        case .thinkingCompleted: return "thinking.completed"
        case .toolStarted: return "tool.started"
        case .toolCompleted: return "tool.completed"
        case .reportDelta: return "report.delta"
        case .reportCompleted: return "report.completed"
        case .turnStarted: return "turn.started"
        case .turnCompleted: return "turn.completed"
        case .turnFailed: return "turn.failed"
        case .turnCancelled: return "turn.cancelled"
        case .heartbeat: return "heartbeat"
        case .unknown(let raw): return raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// Unknown event types must be ignored, then the client refreshes the snapshot once.
    public var shouldRefreshSnapshot: Bool { isUnknown }
}

// MARK: - Error codes

public enum AssistantV2ErrorCode: Hashable, Sendable {
    case invalidRequest
    case unauthorized
    case forbidden
    case researchNotFound
    case turnNotFound
    case artifactNotFound
    case sourceNotFound
    case transcriptJobNotFound
    case memoryProposalNotFound
    case idempotencyConflict
    case turnAlreadyRunning
    case invalidResearchStatus
    case eventCursorExpired
    case pipelineVersionUnsupported
    case sourceRateLimited
    case queueBusy
    case storageFull
    case modelNotConfigured
    case assistantV2Disabled
    case internalError
    case workspaceCreateFailed
    case workspaceNotReady
    case workspaceDegraded
    case workspaceCorrupt
    case workspacePathUnsafe
    case workspaceFileTypeRejected
    case workspaceGrantDenied
    case workspaceGrantReadOnly
    case workspaceGrantUnavailable
    case workspaceQuotaExceeded
    case sharedWriteDisabled
    case grepArgumentRejected
    case grepPatternRejected
    case grepTimeout
    case webDisabled
    case webURLBlocked
    case webURLNotAllowed
    case webContentUnsupported
    case webContentTooLarge
    case webSearchFailed
    case webFetchFailed
    case artifactNotReady
    case artifactCorrupt
    case artifactWriteFailed
    case memoryScopeDenied
    case memoryProposalNotConfirmed
    case memoryProposalExpired
    case transcriptConfirmationRequired
    case transcriptSourceNotEligible
    case v10Unauthorized
    case v10Unavailable
    case v10JobFailed
    case artifactInvalid
    case artifactIntegrityFailed
    case turnInterrupted
    case turnBudgetExceeded
    case turnCancelled
    case modelProviderUnavailable
    case toolNotAllowed
    case toolLimitExceeded
    case citationValidationFailed
    case evidenceNotFound
    case legacySessionReadOnly
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "INVALID_REQUEST": self = .invalidRequest
        case "UNAUTHORIZED": self = .unauthorized
        case "FORBIDDEN": self = .forbidden
        case "RESEARCH_NOT_FOUND": self = .researchNotFound
        case "TURN_NOT_FOUND": self = .turnNotFound
        case "ARTIFACT_NOT_FOUND": self = .artifactNotFound
        case "SOURCE_NOT_FOUND": self = .sourceNotFound
        case "TRANSCRIPT_JOB_NOT_FOUND": self = .transcriptJobNotFound
        case "MEMORY_PROPOSAL_NOT_FOUND": self = .memoryProposalNotFound
        case "IDEMPOTENCY_CONFLICT": self = .idempotencyConflict
        case "TURN_ALREADY_RUNNING": self = .turnAlreadyRunning
        case "INVALID_RESEARCH_STATUS": self = .invalidResearchStatus
        case "EVENT_CURSOR_EXPIRED": self = .eventCursorExpired
        case "PIPELINE_VERSION_UNSUPPORTED": self = .pipelineVersionUnsupported
        case "SOURCE_RATE_LIMITED": self = .sourceRateLimited
        case "QUEUE_BUSY": self = .queueBusy
        case "STORAGE_FULL": self = .storageFull
        case "MODEL_NOT_CONFIGURED": self = .modelNotConfigured
        case "ASSISTANT_V2_DISABLED": self = .assistantV2Disabled
        case "INTERNAL_ERROR": self = .internalError
        case "WORKSPACE_CREATE_FAILED": self = .workspaceCreateFailed
        case "WORKSPACE_NOT_READY": self = .workspaceNotReady
        case "WORKSPACE_DEGRADED": self = .workspaceDegraded
        case "WORKSPACE_CORRUPT": self = .workspaceCorrupt
        case "WORKSPACE_PATH_UNSAFE": self = .workspacePathUnsafe
        case "WORKSPACE_FILE_TYPE_REJECTED": self = .workspaceFileTypeRejected
        case "WORKSPACE_GRANT_DENIED": self = .workspaceGrantDenied
        case "WORKSPACE_GRANT_READ_ONLY": self = .workspaceGrantReadOnly
        case "WORKSPACE_GRANT_UNAVAILABLE": self = .workspaceGrantUnavailable
        case "WORKSPACE_QUOTA_EXCEEDED": self = .workspaceQuotaExceeded
        case "SHARED_WRITE_DISABLED": self = .sharedWriteDisabled
        case "GREP_ARGUMENT_REJECTED": self = .grepArgumentRejected
        case "GREP_PATTERN_REJECTED": self = .grepPatternRejected
        case "GREP_TIMEOUT": self = .grepTimeout
        case "WEB_DISABLED": self = .webDisabled
        case "WEB_URL_BLOCKED": self = .webURLBlocked
        case "WEB_URL_NOT_ALLOWED": self = .webURLNotAllowed
        case "WEB_CONTENT_UNSUPPORTED": self = .webContentUnsupported
        case "WEB_CONTENT_TOO_LARGE": self = .webContentTooLarge
        case "WEB_SEARCH_FAILED": self = .webSearchFailed
        case "WEB_FETCH_FAILED": self = .webFetchFailed
        case "ARTIFACT_NOT_READY": self = .artifactNotReady
        case "ARTIFACT_CORRUPT": self = .artifactCorrupt
        case "ARTIFACT_WRITE_FAILED": self = .artifactWriteFailed
        case "MEMORY_SCOPE_DENIED": self = .memoryScopeDenied
        case "MEMORY_PROPOSAL_NOT_CONFIRMED": self = .memoryProposalNotConfirmed
        case "MEMORY_PROPOSAL_EXPIRED": self = .memoryProposalExpired
        case "TRANSCRIPT_CONFIRMATION_REQUIRED": self = .transcriptConfirmationRequired
        case "TRANSCRIPT_SOURCE_NOT_ELIGIBLE": self = .transcriptSourceNotEligible
        case "V10_UNAUTHORIZED": self = .v10Unauthorized
        case "V10_UNAVAILABLE": self = .v10Unavailable
        case "V10_JOB_FAILED": self = .v10JobFailed
        case "ARTIFACT_INVALID": self = .artifactInvalid
        case "ARTIFACT_INTEGRITY_FAILED": self = .artifactIntegrityFailed
        case "TURN_INTERRUPTED": self = .turnInterrupted
        case "TURN_BUDGET_EXCEEDED": self = .turnBudgetExceeded
        case "TURN_CANCELLED": self = .turnCancelled
        case "MODEL_PROVIDER_UNAVAILABLE": self = .modelProviderUnavailable
        case "TOOL_NOT_ALLOWED": self = .toolNotAllowed
        case "TOOL_LIMIT_EXCEEDED": self = .toolLimitExceeded
        case "CITATION_VALIDATION_FAILED": self = .citationValidationFailed
        case "EVIDENCE_NOT_FOUND": self = .evidenceNotFound
        case "LEGACY_SESSION_READ_ONLY": self = .legacySessionReadOnly
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .invalidRequest: return "INVALID_REQUEST"
        case .unauthorized: return "UNAUTHORIZED"
        case .forbidden: return "FORBIDDEN"
        case .researchNotFound: return "RESEARCH_NOT_FOUND"
        case .turnNotFound: return "TURN_NOT_FOUND"
        case .artifactNotFound: return "ARTIFACT_NOT_FOUND"
        case .sourceNotFound: return "SOURCE_NOT_FOUND"
        case .transcriptJobNotFound: return "TRANSCRIPT_JOB_NOT_FOUND"
        case .memoryProposalNotFound: return "MEMORY_PROPOSAL_NOT_FOUND"
        case .idempotencyConflict: return "IDEMPOTENCY_CONFLICT"
        case .turnAlreadyRunning: return "TURN_ALREADY_RUNNING"
        case .invalidResearchStatus: return "INVALID_RESEARCH_STATUS"
        case .eventCursorExpired: return "EVENT_CURSOR_EXPIRED"
        case .pipelineVersionUnsupported: return "PIPELINE_VERSION_UNSUPPORTED"
        case .sourceRateLimited: return "SOURCE_RATE_LIMITED"
        case .queueBusy: return "QUEUE_BUSY"
        case .storageFull: return "STORAGE_FULL"
        case .modelNotConfigured: return "MODEL_NOT_CONFIGURED"
        case .assistantV2Disabled: return "ASSISTANT_V2_DISABLED"
        case .internalError: return "INTERNAL_ERROR"
        case .workspaceCreateFailed: return "WORKSPACE_CREATE_FAILED"
        case .workspaceNotReady: return "WORKSPACE_NOT_READY"
        case .workspaceDegraded: return "WORKSPACE_DEGRADED"
        case .workspaceCorrupt: return "WORKSPACE_CORRUPT"
        case .workspacePathUnsafe: return "WORKSPACE_PATH_UNSAFE"
        case .workspaceFileTypeRejected: return "WORKSPACE_FILE_TYPE_REJECTED"
        case .workspaceGrantDenied: return "WORKSPACE_GRANT_DENIED"
        case .workspaceGrantReadOnly: return "WORKSPACE_GRANT_READ_ONLY"
        case .workspaceGrantUnavailable: return "WORKSPACE_GRANT_UNAVAILABLE"
        case .workspaceQuotaExceeded: return "WORKSPACE_QUOTA_EXCEEDED"
        case .sharedWriteDisabled: return "SHARED_WRITE_DISABLED"
        case .grepArgumentRejected: return "GREP_ARGUMENT_REJECTED"
        case .grepPatternRejected: return "GREP_PATTERN_REJECTED"
        case .grepTimeout: return "GREP_TIMEOUT"
        case .webDisabled: return "WEB_DISABLED"
        case .webURLBlocked: return "WEB_URL_BLOCKED"
        case .webURLNotAllowed: return "WEB_URL_NOT_ALLOWED"
        case .webContentUnsupported: return "WEB_CONTENT_UNSUPPORTED"
        case .webContentTooLarge: return "WEB_CONTENT_TOO_LARGE"
        case .webSearchFailed: return "WEB_SEARCH_FAILED"
        case .webFetchFailed: return "WEB_FETCH_FAILED"
        case .artifactNotReady: return "ARTIFACT_NOT_READY"
        case .artifactCorrupt: return "ARTIFACT_CORRUPT"
        case .artifactWriteFailed: return "ARTIFACT_WRITE_FAILED"
        case .memoryScopeDenied: return "MEMORY_SCOPE_DENIED"
        case .memoryProposalNotConfirmed: return "MEMORY_PROPOSAL_NOT_CONFIRMED"
        case .memoryProposalExpired: return "MEMORY_PROPOSAL_EXPIRED"
        case .transcriptConfirmationRequired: return "TRANSCRIPT_CONFIRMATION_REQUIRED"
        case .transcriptSourceNotEligible: return "TRANSCRIPT_SOURCE_NOT_ELIGIBLE"
        case .v10Unauthorized: return "V10_UNAUTHORIZED"
        case .v10Unavailable: return "V10_UNAVAILABLE"
        case .v10JobFailed: return "V10_JOB_FAILED"
        case .artifactInvalid: return "ARTIFACT_INVALID"
        case .artifactIntegrityFailed: return "ARTIFACT_INTEGRITY_FAILED"
        case .turnInterrupted: return "TURN_INTERRUPTED"
        case .turnBudgetExceeded: return "TURN_BUDGET_EXCEEDED"
        case .turnCancelled: return "TURN_CANCELLED"
        case .modelProviderUnavailable: return "MODEL_PROVIDER_UNAVAILABLE"
        case .toolNotAllowed: return "TOOL_NOT_ALLOWED"
        case .toolLimitExceeded: return "TOOL_LIMIT_EXCEEDED"
        case .citationValidationFailed: return "CITATION_VALIDATION_FAILED"
        case .evidenceNotFound: return "EVIDENCE_NOT_FOUND"
        case .legacySessionReadOnly: return "LEGACY_SESSION_READ_ONLY"
        case .unknown(let raw): return raw
        }
    }

    /// Last-Event-ID is outside the 24h window; GET the Research snapshot.
    public var shouldRefreshSnapshot: Bool { self == .eventCursorExpired }

    /// Unknown codes are non-retryable unless HTTP status is 429 or 503.
    public func isRetryable(httpStatus: Int, serverRetryable: Bool) -> Bool {
        if serverRetryable { return true }
        if case .unknown = self {
            return httpStatus == 429 || httpStatus == 503
        }
        return false
    }
}

public enum AssistantV2WirePolicy {
    /// Keys that must never appear on REST artifact objects.
    public static let forbiddenArtifactPathKeys: Set<String> = [
        "path", "relativePath", "uri", "fileName", "filename", "realPath", "absolutePath"
    ]
}

// MARK: - Requests

public struct AssistantV2ResearchCreateRequest: Codable, Hashable, Sendable {
    public var outputLanguage: String?
    public var storefront: String?
    public var targetLanguage: String?
    public var translationQuality: CloudTranslationQuality?
    public var title: String?
    public var sharedAliases: [String]?

    public init(
        outputLanguage: String? = nil,
        storefront: String? = nil,
        targetLanguage: String? = nil,
        translationQuality: CloudTranslationQuality? = nil,
        title: String? = nil,
        sharedAliases: [String]? = nil
    ) {
        self.outputLanguage = outputLanguage
        self.storefront = storefront
        self.targetLanguage = targetLanguage
        self.translationQuality = translationQuality
        self.title = title
        self.sharedAliases = sharedAliases
    }
}

public struct AssistantV2TurnCreateRequest: Codable, Hashable, Sendable {
    public var message: String
    public var mode: AssistantV2TurnMode
    public var clientContext: AssistantClientContext?

    public init(message: String, mode: AssistantV2TurnMode, clientContext: AssistantClientContext? = nil) {
        self.message = message
        self.mode = mode
        self.clientContext = clientContext
    }
}

public struct AssistantV2TranscriptionCreateRequest: Codable, Hashable, Sendable {
    public var confirmed: Bool
    public var targetLanguage: String
    public var translationQuality: CloudTranslationQuality

    public init(targetLanguage: String, translationQuality: CloudTranslationQuality) {
        self.confirmed = true
        self.targetLanguage = targetLanguage
        self.translationQuality = translationQuality
    }
}

public struct AssistantV2GrepFilesRequest: Codable, Hashable, Sendable {
    public var root: String
    public var pattern: String
    public var mode: AssistantV2GrepMode
    public var glob: String?
    public var caseSensitive: Bool?

    public init(
        root: String,
        pattern: String,
        mode: AssistantV2GrepMode,
        glob: String? = nil,
        caseSensitive: Bool? = nil
    ) {
        self.root = root
        self.pattern = pattern
        self.mode = mode
        self.glob = glob
        self.caseSensitive = caseSensitive
    }
}

public struct AssistantV2GrepFilesMatch: Codable, Hashable, Sendable {
    public var uri: String
    public var line: Int
    public var column: Int
    public var text: String
    public var truncated: Bool
}

public struct AssistantV2GrepFilesResult: Codable, Hashable, Sendable {
    public var matches: [AssistantV2GrepFilesMatch]
    public var matchCount: Int
    public var truncated: Bool
}

// MARK: - Grants, sources, artifacts

public struct AssistantV2SourceReference: Codable, Hashable, Sendable {
    public var platform: String
    public var sourceId: String
    public var canonicalURL: String
    public var contentKey: String?
    public var provider: String?
    public var retrievedAt: Date?
    public var provenance: [String: AssistantJSONLeaf]?
}

public struct AssistantV2WorkspaceGrant: Codable, Hashable, Sendable {
    public var alias: String
    public var permission: AssistantV2GrantPermission
    public var allowedExtensions: [String]
    public var maxFileBytes: Int
    public var grantedAt: Date
    public var status: AssistantV2GrantStatus?
}

public struct AssistantV2ArtifactCounts: Codable, Hashable, Sendable {
    public var webSearch: Int
    public var webPage: Int
    public var podcastSearch: Int
    public var youtubeSearch: Int
    public var transcript: Int
    public var researchMemory: Int
    public var report: Int

    enum CodingKeys: String, CodingKey {
        case webSearch = "web_search"
        case webPage = "web_page"
        case podcastSearch = "podcast_search"
        case youtubeSearch = "youtube_search"
        case transcript
        case researchMemory = "research_memory"
        case report
    }

    public init(
        webSearch: Int = 0,
        webPage: Int = 0,
        podcastSearch: Int = 0,
        youtubeSearch: Int = 0,
        transcript: Int = 0,
        researchMemory: Int = 0,
        report: Int = 0
    ) {
        self.webSearch = webSearch
        self.webPage = webPage
        self.podcastSearch = podcastSearch
        self.youtubeSearch = youtubeSearch
        self.transcript = transcript
        self.researchMemory = researchMemory
        self.report = report
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        webSearch = try container.decodeIfPresent(Int.self, forKey: .webSearch) ?? 0
        webPage = try container.decodeIfPresent(Int.self, forKey: .webPage) ?? 0
        podcastSearch = try container.decodeIfPresent(Int.self, forKey: .podcastSearch) ?? 0
        youtubeSearch = try container.decodeIfPresent(Int.self, forKey: .youtubeSearch) ?? 0
        transcript = try container.decodeIfPresent(Int.self, forKey: .transcript) ?? 0
        researchMemory = try container.decodeIfPresent(Int.self, forKey: .researchMemory) ?? 0
        report = try container.decodeIfPresent(Int.self, forKey: .report) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(webSearch, forKey: .webSearch)
        try container.encode(webPage, forKey: .webPage)
        try container.encode(podcastSearch, forKey: .podcastSearch)
        try container.encode(youtubeSearch, forKey: .youtubeSearch)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(researchMemory, forKey: .researchMemory)
        try container.encode(report, forKey: .report)
    }
}

/// REST artifact summary. Identified by artifactId only; no path, URI, or filename.
public struct AssistantV2WorkspaceArtifact: Codable, Hashable, Sendable {
    public var artifactId: String
    public var researchId: String
    public var kind: AssistantV2ArtifactKind
    public var status: AssistantV2ArtifactStatus
    public var mediaType: String
    public var bytes: Int
    public var sha256: String
    public var producer: String
    public var sourceReference: AssistantV2SourceReference?
    public var evidenceLevel: AssistantV2EvidenceLevel
    public var createdAt: Date
    public var updatedAt: Date
}

public struct AssistantV2ArtifactListResponse: Codable, Hashable, Sendable {
    public var artifacts: [AssistantV2WorkspaceArtifact]
    public var nextCursor: String?
}

public struct AssistantV2ArtifactBody: Codable, Hashable, Sendable {
    public var artifact: AssistantV2WorkspaceArtifact
    public var text: String
    public var truncated: Bool
    public var encoding: AssistantV2ArtifactEncoding
}

public struct AssistantV2Citation: Codable, Hashable, Sendable {
    public var citationId: String
    public var artifactId: String
    public var evidenceLevel: AssistantV2EvidenceLevel
    public var label: String
    public var passageId: String?
    public var startMilliseconds: Int?
    public var endMilliseconds: Int?
    public var sourceURL: String?
    public var contentKey: String?
    public var quote: String
    public var sha256: String?
}

public struct AssistantV2Message: Codable, Hashable, Sendable {
    public var messageId: String
    public var researchId: String
    public var turnId: String
    public var role: AssistantV2MessageRole
    public var markdown: String
    public var citations: [AssistantV2Citation]?
    public var createdAt: Date
}

public struct AssistantV2TurnSummary: Codable, Hashable, Sendable {
    public var turnId: String
    public var researchId: String
    public var mode: AssistantV2TurnMode
    public var status: AssistantV2TurnStatus
    public var eventsURL: String?
    public var error: AssistantErrorBody?
    public var skillName: String?
    public var skillVersion: String?
    public var skillSha256: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
}

public struct AssistantV2TurnAcceptedResponse: Codable, Hashable, Sendable {
    public var turnId: String
    public var researchId: String
    public var mode: AssistantV2TurnMode
    public var status: AssistantV2TurnStatus
    public var eventsURL: String
    public var reused: Bool?
}

public struct AssistantV2MemoryEntry: Codable, Hashable, Sendable {
    public var memoryEntryId: String
    public var scope: AssistantV2MemoryScope
    public var type: String
    public var content: String
    public var status: String
    public var sourceArtifactId: String?
    public var hypothesis: Bool?
    public var createdAt: Date
    public var confirmedAt: Date?
}

public struct AssistantV2MemoryProposal: Codable, Hashable, Sendable {
    public var proposalId: String
    public var researchId: String
    public var content: String
    public var reason: String
    public var status: AssistantV2MemoryProposalStatus
    public var createdAt: Date
    public var expiresAt: Date
    public var confirmedAt: Date?
    public var rejectedAt: Date?
    public var memoryEntryId: String?
}

public struct AssistantV2MemorySnapshot: Codable, Hashable, Sendable {
    public var researchId: String
    public var entries: [AssistantV2MemoryEntry]
    public var proposals: [AssistantV2MemoryProposal]
}

public struct AssistantV2TranscriptJob: Codable, Hashable, Sendable {
    public var transcriptJobId: String
    public var researchId: String
    public var sourceId: String
    public var contentKey: String
    public var v10JobId: String?
    public var status: AssistantV2TranscriptJobStatus
    public var installStatus: String
    public var progress: Double
    public var artifactId: String?
    public var error: AssistantErrorBody?
    public var updatedAt: Date
}

public struct AssistantV2TranscriptJobListResponse: Codable, Hashable, Sendable {
    public var transcriptJobs: [AssistantV2TranscriptJob]
}

public struct AssistantV2Research: Codable, Hashable, Sendable {
    public var researchId: String
    public var title: String
    public var phase: String?
    public var status: AssistantV2ResearchStatus
    public var workspaceStatus: String
    public var outputLanguage: String?
    public var storefront: String?
    public var targetLanguage: String?
    public var translationQuality: CloudTranslationQuality?
    public var activeTurnId: String?
    public var artifactCounts: AssistantV2ArtifactCounts?
    public var grants: [AssistantV2WorkspaceGrant]?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct AssistantV2ResearchListResponse: Codable, Hashable, Sendable {
    public var researches: [AssistantV2Research]
    public var nextCursor: String?
}

public struct AssistantV2TurnWorkThinking: Codable, Hashable, Sendable {
    public var status: String
    public var durationMs: Int?
    public var text: String?
    public var truncated: Bool?
    public var redacted: Bool?

    public init(status: String, durationMs: Int? = nil, text: String? = nil, truncated: Bool? = nil, redacted: Bool? = nil) {
        self.status = status
        self.durationMs = durationMs
        self.text = text
        self.truncated = truncated
        self.redacted = redacted
    }

    public var isStreaming: Bool { status == "streaming" }
    public var isRedacted: Bool { redacted == true || status == "redacted" }
}

public struct AssistantV2TurnWorkTool: Codable, Hashable, Sendable, Identifiable {
    public var callId: String
    public var tool: String
    public var labelKey: String
    public var status: String
    public var query: String?

    public init(callId: String, tool: String, labelKey: String, status: String, query: String? = nil) {
        self.callId = callId
        self.tool = tool
        self.labelKey = labelKey
        self.status = status
        self.query = query
    }

    public var id: String { callId }
    public var isRunning: Bool { status == "running" }
    public var isFailed: Bool { status == "failed" }
}

/// Per-turn work card projected from durable v2_events. Display only.
public struct AssistantV2TurnWork: Codable, Hashable, Sendable, Identifiable {
    public var turnId: String
    public var durationMs: Int?
    public var thinking: AssistantV2TurnWorkThinking?
    public var tools: [AssistantV2TurnWorkTool]

    public init(turnId: String, durationMs: Int? = nil, thinking: AssistantV2TurnWorkThinking? = nil, tools: [AssistantV2TurnWorkTool] = []) {
        self.turnId = turnId
        self.durationMs = durationMs
        self.thinking = thinking
        self.tools = tools
    }

    public var id: String { turnId }
    public var isRunning: Bool {
        if thinking?.isStreaming == true { return true }
        return tools.contains { $0.isRunning }
    }
}

public struct AssistantV2ResearchSnapshot: Codable, Hashable, Sendable {
    public var researchId: String
    public var title: String
    public var phase: String?
    public var status: AssistantV2ResearchStatus
    public var workspaceStatus: String
    public var outputLanguage: String?
    public var storefront: String?
    public var targetLanguage: String?
    public var translationQuality: CloudTranslationQuality?
    public var activeTurnId: String?
    public var artifactCounts: AssistantV2ArtifactCounts?
    public var grants: [AssistantV2WorkspaceGrant]
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [AssistantV2Message]
    public var artifacts: [AssistantV2WorkspaceArtifact]
    public var memory: AssistantV2MemorySnapshot?
    public var latestReportArtifactId: String?
    public var activeTurn: AssistantV2TurnSummary?
    public var turnWork: [AssistantV2TurnWork]?
}

public struct AssistantV2SseEventData: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var eventId: Int
    public var sequence: Int
    public var researchId: String
    public var turnId: String
    public var type: String
    public var occurredAt: Date
    public var payload: [String: AssistantJSONLeaf]
}
