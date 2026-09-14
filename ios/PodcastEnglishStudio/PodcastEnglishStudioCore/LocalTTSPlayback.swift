import Foundation

/// One synthesized unit of Chinese playback: a sentence, or one fragment of a
/// sentence that was too long for the model's input window.
public struct TTSPlaybackCursor: Hashable, Sendable, Comparable {
    public let segmentIndex: Int
    public let fragmentIndex: Int

    public init(segmentIndex: Int, fragmentIndex: Int = 0) {
        self.segmentIndex = segmentIndex
        self.fragmentIndex = fragmentIndex
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.segmentIndex, lhs.fragmentIndex) < (rhs.segmentIndex, rhs.fragmentIndex)
    }
}

/// Starting the next clip exactly when the current one ends, instead of after a
/// completion callback, is what removes the seam between sentences.
public enum TTSHandoffSchedule {
    /// Below this there is no time to arm a start, so the callback path takes over.
    public static let minimumLeadSeconds = 0.1

    /// Wall-clock seconds until the playing clip ends. Nil when a scheduled
    /// start would be unsafe — the rate makes this more than a division.
    public static func leadSeconds(duration: Double, currentTime: Double, rate: Double,
                                   minimumLead: Double = minimumLeadSeconds) -> Double? {
        guard duration.isFinite, currentTime.isFinite, rate.isFinite, rate > 0 else { return nil }
        let lead = (duration - currentTime) / rate
        guard lead.isFinite, lead >= minimumLead else { return nil }
        return lead
    }
}

public enum TTSPrefetchPressure: Sendable, Equatable {
    case normal
    case reduced
    case suspended

    public static func from(_ thermalState: ProcessInfo.ThermalState) -> Self {
        switch thermalState {
        case .nominal, .fair: return .normal
        case .serious: return .reduced
        case .critical: return .suspended
        @unknown default: return .reduced
        }
    }
}

/// One unit the player may want resident, with the length of its audio once ready.
public struct TTSPrefetchUnit: Equatable, Sendable {
    public let cursor: TTSPlaybackCursor
    public let readySeconds: Double?

    public init(cursor: TTSPlaybackCursor, readySeconds: Double?) {
        self.cursor = cursor
        self.readySeconds = readySeconds
    }

    public var isReady: Bool { readySeconds.map { $0.isFinite && $0 > 0 } ?? false }
}

/// How far ahead to synthesize, and when the first sentence may start.
/// Synthesis itself stays serial — one inference per device (需求文档V16:122).
public struct TTSPrefetchPolicy: Equatable, Sendable {
    public var lowWaterSeconds = 4.0
    public var secondsAhead = 12.0
    public var maxUnits = 4
    public var startSeconds = 0.0
    public var startTimeoutSeconds = 0.0

    public init() {}

    /// Only a contiguous, validated prefix can keep playback supplied.
    public func bufferedSeconds(units: [TTSPrefetchUnit], currentTime: Double, rate: Double) -> Double {
        guard rate.isFinite, rate > 0, currentTime.isFinite else { return 0 }
        var seconds = 0.0
        for (index, unit) in units.enumerated() {
            guard let duration = unit.readySeconds, duration.isFinite, duration > 0 else { break }
            seconds += max(0, duration - (index == 0 ? max(0, currentTime) : 0))
        }
        return seconds / rate
    }

    public func residentCount(units: [TTSPrefetchUnit], rate: Double, pressure: TTSPrefetchPressure) -> Int {
        guard !units.isEmpty else { return 0 }
        guard pressure == .normal else { return 1 }
        var seconds = 0.0
        for (index, unit) in units.prefix(maxUnits).enumerated() {
            guard let duration = unit.readySeconds, duration.isFinite, duration > 0 else { return index + 1 }
            seconds += duration
            if seconds / max(0.25, rate) >= secondsAhead { return index + 1 }
        }
        return min(units.count, maxUnits)
    }

    /// Background playback may use what is already cached but must not run the
    /// models; critical thermal state stops synthesis outright (需求文档V16:174).
    public func allowsSynthesis(pressure: TTSPrefetchPressure, isForeground: Bool) -> Bool {
        isForeground && pressure != .suspended
    }

    /// The pre-buffer gate. It can delay first sound, so it always yields to the
    /// timeout, to the last sentence, and to a lookahead that is already ready —
    /// AC-10 requires the first segment to play as soon as it can.
    public func canStart(playheadSeconds: Double?, nextIsReady: Bool, hasNext: Bool,
                         rate: Double, waitedSeconds: Double) -> Bool {
        guard let playheadSeconds else { return false }
        if waitedSeconds >= startTimeoutSeconds || !hasNext || nextIsReady { return true }
        return playheadSeconds >= startSeconds * max(0.25, rate)
    }
}
