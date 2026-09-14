import CryptoKit
import Foundation

public struct TTSPlaybackCheckpoint: Codable, Sendable {
    public let schemaVersion: Int
    public let episodeID: String
    public let mode: EpisodeAudioMode
    public let transcriptRevision: String
    public let segmentID: String
    public let fragmentIndex: Int
    public let rhythmVersion: String?
    public let fragmentSeconds: TimeInterval

    public init(episodeID: String, mode: EpisodeAudioMode, transcriptRevision: String,
                segmentID: String, fragmentIndex: Int, fragmentSeconds: TimeInterval, rhythmVersion: String? = nil) {
        self.rhythmVersion = rhythmVersion
        self.schemaVersion = 1
        self.episodeID = episodeID
        self.mode = mode
        self.transcriptRevision = transcriptRevision
        self.segmentID = segmentID
        self.fragmentIndex = fragmentIndex
        self.fragmentSeconds = fragmentSeconds
    }

    /// The audio store must additionally verify fragment existence and duration.
    /// Restoring this data never grants permission to start playback.
    public func canRestore(in snapshot: TTSTranscriptSnapshot) -> Bool {
        schemaVersion == 1 && episodeID == snapshot.episodeID && transcriptRevision == snapshot.revision
            && fragmentIndex >= 0 && fragmentSeconds.isFinite && fragmentSeconds >= 0
            && snapshot.segments.contains { $0.id == segmentID && $0.isReadable }
    }
}

public struct TTSResourceIdentity: Codable, Hashable, Sendable {
    public let model: String
    public let vocabulary: String
    public let frontend: String
    public let voice: String

    public init(model: String, vocabulary: String, frontend: String, voice: String) {
        self.model = model
        self.vocabulary = vocabulary
        self.frontend = frontend
        self.voice = voice
    }
}

/// Playback rate is deliberately absent: it does not alter synthesized audio.
public struct TTSAudioCacheKey: Codable, Hashable, Sendable {
    public let episodeID: String
    public let transcriptRevision: String
    public let segmentID: String
    public let fragmentIndex: Int
    public let text: String
    public let resources: TTSResourceIdentity
    public let rhythmVersion: String
    public let boundaryIdentity: String
    public let synthesisSpeed: Double

    public init(episodeID: String, transcriptRevision: String, segmentID: String,
                fragmentIndex: Int, text: String, resources: TTSResourceIdentity, synthesisSpeed: Double = 1,
                rhythmVersion: String = "current-v1", boundaryIdentity: String = "punctuation") {
        self.episodeID = episodeID
        self.transcriptRevision = transcriptRevision
        self.segmentID = segmentID
        self.fragmentIndex = fragmentIndex
        self.text = text
        self.resources = resources
        self.rhythmVersion = rhythmVersion
        self.boundaryIdentity = boundaryIdentity
        self.synthesisSpeed = synthesisSpeed
    }

    public func digest() throws -> String {
        guard !episodeID.isEmpty, !transcriptRevision.isEmpty, !segmentID.isEmpty,
              fragmentIndex >= 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rhythmVersion.isEmpty, !boundaryIdentity.isEmpty, synthesisSpeed.isFinite, synthesisSpeed > 0,
              [resources.model, resources.vocabulary, resources.frontend, resources.voice].allSatisfy({ !$0.isEmpty }) else {
            throw TTSSynthesisError.invalidInput
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum TTSSynthesisError: Error, Equatable, Sendable {
    case invalidInput
    case unsupportedDevice
    case modelUnavailable
    case incompatibleResources
    case cancelled
    case insufficientStorage
    case resourcePressure
    case synthesisFailed

    /// How far a failure reaches. Only a device, model or resource problem ends Chinese mode;
    /// a single sentence failing must leave the mode selected so the user can retry or skip.
    public var scope: TTSFailureScope {
        switch self {
        case .unsupportedDevice, .modelUnavailable, .incompatibleResources: return .mode
        case .invalidInput, .cancelled, .insufficientStorage, .resourcePressure, .synthesisFailed: return .sentence
        }
    }
}

public enum TTSFailureScope: Equatable, Sendable {
    case sentence
    case mode
}

public struct TTSSynthesisRequest: Sendable {
    public let transition: TTSAudioTransition
    public let cacheKey: TTSAudioCacheKey

    public init(transition: TTSAudioTransition, cacheKey: TTSAudioCacheKey) {
        self.transition = transition
        self.cacheKey = cacheKey
    }
}

public struct TTSSynthesizedAudio: Sendable {
    public let request: TTSSynthesisRequest
    public let fileURL: URL
    public let durationSeconds: TimeInterval

    public init(request: TTSSynthesisRequest, fileURL: URL, durationSeconds: TimeInterval) {
        self.request = request
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
    }
}

/// Implementations must serialize inference and validate the complete resource identity.
public protocol LocalTTSSynthesizing: Sendable {
    func synthesize(_ request: TTSSynthesisRequest) async throws -> TTSSynthesizedAudio
    func cancel(transition: TTSAudioTransition) async
}
