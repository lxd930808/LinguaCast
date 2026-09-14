import Foundation

public enum EpisodeAudioMode: String, Codable, Sendable {
    case original
    case chinese
}

/// Identifies a single asynchronous transition, including its originating episode.
public struct TTSAudioTransition: Equatable, Sendable {
    public let episodeID: String
    public let id: UUID
    public let mode: EpisodeAudioMode
}

/// Pure policy; the coordinator applies audio side effects from these states.
public struct TTSAudioSessionState: Sendable {
    public private(set) var episodeID: String
    public private(set) var selectedMode: EpisodeAudioMode = .original
    public private(set) var pendingTransition: TTSAudioTransition?
    public private(set) var playIntent: Bool
    public private(set) var isPreparing = false
    private var preparingTransition: TTSAudioTransition?

    public var isPlaying: Bool { playIntent && !isPreparing }

    public init(episodeID: String, isPlaying: Bool = false) {
        self.episodeID = episodeID
        self.playIntent = isPlaying
    }

    /// Preflight and downloads do not stop the currently selected audio.
    @discardableResult
    public mutating func request(_ mode: EpisodeAudioMode) -> TTSAudioTransition {
        let transition = TTSAudioTransition(episodeID: episodeID, id: UUID(), mode: mode)
        pendingTransition = transition
        preparingTransition = nil
        return transition
    }

    /// Called only after compatibility, model and transcript checks pass.
    @discardableResult
    public mutating func beginPreparation(_ transition: TTSAudioTransition) -> Bool {
        guard pendingTransition == transition else { return false }
        isPreparing = true
        preparingTransition = transition
        return true
    }

    @discardableResult
    public mutating func finishPreparation(_ transition: TTSAudioTransition) -> Bool {
        guard pendingTransition == transition, preparingTransition == transition else { return false }
        selectedMode = transition.mode
        pendingTransition = nil
        preparingTransition = nil
        isPreparing = false
        return true
    }

    /// A failed preflight preserves playback; a failed handover restores paused original audio.
    @discardableResult
    public mutating func fail(_ transition: TTSAudioTransition) -> Bool {
        guard pendingTransition == transition else { return false }
        if isPreparing {
            selectedMode = .original
            playIntent = false
        }
        isPreparing = false
        preparingTransition = nil
        pendingTransition = nil
        return true
    }

    public mutating func pause() { playIntent = false }
    public mutating func play() { playIntent = true }

    public mutating func changeEpisode(to episodeID: String) {
        self = Self(episodeID: episodeID)
    }
}
