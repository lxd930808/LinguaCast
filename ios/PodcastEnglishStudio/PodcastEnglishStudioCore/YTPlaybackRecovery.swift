import Foundation

/// Platform kind for composed-HLS compatibility decisions.
/// Separated from UIKit/`#if os` so unit tests can inject versions.
public enum YTPlaybackPlatformKind: Equatable, Sendable {
    case tvOS
    case iOS
    case other
}

/// Decides whether synthesized (composed) HLS single-player is safe for a platform/OS.
///
/// tvOS 26+ hits a CoreMedia compatibility fault with composed HLS; prefer dual AVPlayer.
/// tvOS 17–25 keep composed HLS. Non-tvOS callers keep their own platform defaults.
public enum YTComposedPlaybackCompatibilityPolicy {
    public static let composedHLSUnsupportedMajorVersion = 26

    public static func prefersComposedHLSSinglePlayer(
        platform: YTPlaybackPlatformKind,
        majorVersion: Int
    ) -> Bool {
        guard platform == .tvOS else { return false }
        return majorVersion < composedHLSUnsupportedMajorVersion
    }
}

public enum YTPlaybackRecoveryPhase: Equatable, Sendable {
    /// Media items installed; waiting for readyToPlay.
    case preparing
    /// Both items ready; seeking to the snapshotted position.
    case restoring
    /// Seek finished; waiting for first sustainable keep-up while playing (or paused).
    case warmingUp
    /// Normal playback; stall watchdog may run.
    case active
}

public struct YTPlaybackRecoverySnapshot: Equatable, Sendable {
    public var position: TimeInterval
    public var wantsPlayback: Bool
    public var rate: Double

    public init(position: TimeInterval, wantsPlayback: Bool, rate: Double) {
        self.position = position
        self.wantsPlayback = wantsPlayback
        self.rate = rate
    }
}

public enum YTPlaybackRecoveryCommand: Equatable, Sendable {
    case play
    case pause
    case seek(TimeInterval, resumeAfterSeek: Bool)
}

public enum YTPlaybackRecoveryWatchdogKind: Equatable, Sendable {
    case prepareTimeout
    case sustainedStall
}

public enum YTPlaybackRecoveryEvent: Equatable, Sendable {
    case beginItemReplace(snapshot: YTPlaybackRecoverySnapshot)
    case itemsReady
    case restoreSeekSucceeded
    case restoreSeekFailed
    case firstSustainablePlayback
    case keepUpChanged(Bool)
    case prepareWatchdogFired
    case stallWatchdogFired
    case command(YTPlaybackRecoveryCommand)
}

public enum YTPlaybackRecoveryEffect: Equatable, Sendable {
    case none
    case scheduleWatchdog(YTPlaybackRecoveryWatchdogKind, after: TimeInterval)
    case cancelWatchdog
    case requestDowngrade(position: TimeInterval, wantsPlayback: Bool)
    case seekBothPlayers(to: TimeInterval, resume: Bool, rate: Double)
    case resumePlayback(rate: Double)
    case stayPaused
}

/// Pure recovery / stall state machine shared by tvOS and iOS native AVPlayer paths.
public struct YTPlaybackRecoveryMachine: Equatable, Sendable {
    public private(set) var phase: YTPlaybackRecoveryPhase
    public private(set) var generation: UInt64
    public private(set) var snapshot: YTPlaybackRecoverySnapshot?
    public private(set) var didRequestAutoDowngrade: Bool
    public private(set) var continuousStallStartedAt: Date?
    public private(set) var scheduledWatchdog: YTPlaybackRecoveryWatchdogKind?

    public static let prepareTimeout: TimeInterval = 25
    public static let sustainedStallTimeout: TimeInterval = 8

    public init(
        phase: YTPlaybackRecoveryPhase = .active,
        generation: UInt64 = 0,
        snapshot: YTPlaybackRecoverySnapshot? = nil,
        didRequestAutoDowngrade: Bool = false,
        continuousStallStartedAt: Date? = nil,
        scheduledWatchdog: YTPlaybackRecoveryWatchdogKind? = nil
    ) {
        self.phase = phase
        self.generation = generation
        self.snapshot = snapshot
        self.didRequestAutoDowngrade = didRequestAutoDowngrade
        self.continuousStallStartedAt = continuousStallStartedAt
        self.scheduledWatchdog = scheduledWatchdog
    }

    /// Observed times must not overwrite the binding with a near-zero value while
    /// a non-zero restore is still in flight.
    public var shouldPublishObservedPlaybackTime: Bool {
        switch phase {
        case .preparing, .restoring:
            return false
        case .warmingUp, .active:
            return true
        }
    }

    public var shouldApplyCommandsDirectlyToPlayer: Bool {
        phase == .active
    }

    public var trustedRecoveryPosition: TimeInterval {
        if let snapshot, snapshot.position.isFinite, snapshot.position >= 0 {
            return snapshot.position
        }
        return 0
    }

    /// Keep the snapshotted resume position fresh once playback is observable.
    public mutating func noteObservedPosition(_ position: TimeInterval) {
        guard phase == .warmingUp || phase == .active else { return }
        guard position.isFinite, position >= 0 else { return }
        if var snapshot {
            snapshot.position = position
            self.snapshot = snapshot
        } else {
            self.snapshot = YTPlaybackRecoverySnapshot(
                position: position,
                wantsPlayback: true,
                rate: 1
            )
        }
    }

    @discardableResult
    public mutating func handle(
        _ event: YTPlaybackRecoveryEvent,
        now: Date = Date(),
        expectedGeneration: UInt64? = nil
    ) -> YTPlaybackRecoveryEffect {
        if let expectedGeneration, expectedGeneration != generation {
            return .none
        }

        switch event {
        case .beginItemReplace(let snapshot):
            return beginItemReplace(snapshot: snapshot)

        case .itemsReady:
            return itemsReady()

        case .restoreSeekSucceeded:
            return restoreSeekSucceeded()

        case .restoreSeekFailed:
            return restoreSeekFailed()

        case .firstSustainablePlayback:
            return firstSustainablePlayback()

        case .keepUpChanged(let keepUp):
            return keepUpChanged(keepUp, now: now)

        case .prepareWatchdogFired:
            return watchdogFired(.prepareTimeout)

        case .stallWatchdogFired:
            return watchdogFired(.sustainedStall)

        case .command(let command):
            return applyCommand(command)
        }
    }

    private mutating func beginItemReplace(
        snapshot: YTPlaybackRecoverySnapshot
    ) -> YTPlaybackRecoveryEffect {
        generation &+= 1
        phase = .preparing
        self.snapshot = snapshot
        didRequestAutoDowngrade = false
        continuousStallStartedAt = nil
        scheduledWatchdog = .prepareTimeout
        return .scheduleWatchdog(.prepareTimeout, after: Self.prepareTimeout)
    }

    private mutating func itemsReady() -> YTPlaybackRecoveryEffect {
        guard phase == .preparing, let snapshot else { return .none }
        phase = .restoring
        scheduledWatchdog = .prepareTimeout
        return .seekBothPlayers(
            to: snapshot.position,
            resume: false,
            rate: snapshot.rate
        )
    }

    private mutating func restoreSeekSucceeded() -> YTPlaybackRecoveryEffect {
        guard phase == .restoring, let snapshot else { return .none }
        phase = .warmingUp
        continuousStallStartedAt = nil
        // Keep the prepare timeout until first sustainable playback / active.
        scheduledWatchdog = .prepareTimeout
        if snapshot.wantsPlayback {
            return .resumePlayback(rate: snapshot.rate)
        }
        return .stayPaused
    }

    private mutating func restoreSeekFailed() -> YTPlaybackRecoveryEffect {
        guard phase == .restoring || phase == .preparing else { return .none }
        return requestDowngradeIfNeeded()
    }

    private mutating func firstSustainablePlayback() -> YTPlaybackRecoveryEffect {
        guard phase == .warmingUp || phase == .preparing || phase == .restoring else {
            return .none
        }
        phase = .active
        continuousStallStartedAt = nil
        if scheduledWatchdog != nil {
            scheduledWatchdog = nil
            return .cancelWatchdog
        }
        return .none
    }

    private mutating func keepUpChanged(_ keepUp: Bool, now: Date) -> YTPlaybackRecoveryEffect {
        // Transient keep-up flips during prepare/restore/warmup are not stalls.
        guard phase == .active else { return .none }
        guard !didRequestAutoDowngrade else { return .none }

        if keepUp {
            continuousStallStartedAt = nil
            if scheduledWatchdog == .sustainedStall {
                scheduledWatchdog = nil
                return .cancelWatchdog
            }
            return .none
        }

        if continuousStallStartedAt == nil {
            continuousStallStartedAt = now
            scheduledWatchdog = .sustainedStall
            return .scheduleWatchdog(.sustainedStall, after: Self.sustainedStallTimeout)
        }
        return .none
    }

    private mutating func watchdogFired(
        _ kind: YTPlaybackRecoveryWatchdogKind
    ) -> YTPlaybackRecoveryEffect {
        guard scheduledWatchdog == kind else { return .none }
        switch kind {
        case .prepareTimeout:
            guard phase == .preparing || phase == .restoring || phase == .warmingUp else {
                return .none
            }
            return requestDowngradeIfNeeded()
        case .sustainedStall:
            guard phase == .active, continuousStallStartedAt != nil else { return .none }
            return requestDowngradeIfNeeded()
        }
    }

    private mutating func applyCommand(
        _ command: YTPlaybackRecoveryCommand
    ) -> YTPlaybackRecoveryEffect {
        guard !shouldApplyCommandsDirectlyToPlayer else { return .none }
        var next = snapshot ?? YTPlaybackRecoverySnapshot(
            position: 0,
            wantsPlayback: false,
            rate: 1
        )
        switch command {
        case .play:
            next.wantsPlayback = true
        case .pause:
            next.wantsPlayback = false
        case .seek(let position, let resumeAfterSeek):
            next.position = max(0, position)
            next.wantsPlayback = resumeAfterSeek
        }
        snapshot = next
        return .none
    }

    private mutating func requestDowngradeIfNeeded() -> YTPlaybackRecoveryEffect {
        guard !didRequestAutoDowngrade else { return .none }
        didRequestAutoDowngrade = true
        scheduledWatchdog = nil
        continuousStallStartedAt = nil
        let wantsPlayback = snapshot?.wantsPlayback ?? true
        return .requestDowngrade(
            position: trustedRecoveryPosition,
            wantsPlayback: wantsPlayback
        )
    }

    /// Caller already issued a fallback (e.g. item `.failed`); suppress further watchdogs.
    public mutating func acknowledgeFallbackIssued() {
        didRequestAutoDowngrade = true
        scheduledWatchdog = nil
        continuousStallStartedAt = nil
    }
}

public enum YTPlaybackStallRecoveryPolicy {
    public static func watchdogDelay(allItemsReady: Bool) -> TimeInterval {
        allItemsReady
            ? YTPlaybackRecoveryMachine.sustainedStallTimeout
            : YTPlaybackRecoveryMachine.prepareTimeout
    }

    /// Whether a `likelyToKeepUp == false` observation should start/continue
    /// the active-phase sustained-stall watchdog.
    public static func countsAsPlaybackStall(
        phase: YTPlaybackRecoveryPhase
    ) -> Bool {
        phase == .active
    }
}
