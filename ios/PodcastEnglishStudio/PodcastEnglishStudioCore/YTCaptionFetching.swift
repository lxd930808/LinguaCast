import Foundation

public struct YTEnglishCaptionPackage: Equatable, Sendable {
    public var englishVTT: String
    public var segments: [LearningSegment]

    public init(englishVTT: String, segments: [LearningSegment]) {
        self.englishVTT = englishVTT
        self.segments = segments
    }
}

/// First-pass acceptance gate for fetched English captions.
/// - `strict`: rejects fragmented/overlapping/abnormal-CPS timelines up front.
/// - `acceptParseableContent`: accepts any track that parses into non-empty segments
///   (iOS official-iframe playback). Empty, unparseable, HTTP, rate-limit and
///   attestation failures are still rejected, and the final publish gate in
///   `persistReadyTranslation` still applies the timeline quality check.
public enum YTCaptionIngestionPolicy: String, CaseIterable, Hashable, Sendable {
    case strict
    case acceptParseableContent
}

public enum YTCaptionError: LocalizedError, Equatable, Sendable {
    case missingEnglishTrack
    case emptyCaptionFile
    case emptyCaptionResponse
    case captionQualityRejected
    case rateLimited(retryAt: Date)
    case attestationRequired
    case accessBlocked(status: Int)
    case httpFailure(status: Int)

    public var errorDescription: String? {
        switch self {
        case .missingEnglishTrack:
            return "This video has no available English caption track."
        case .emptyCaptionFile:
            return "The caption file is empty or could not be parsed."
        case .emptyCaptionResponse:
            return "YouTube returned a caption track without caption content. Try another video."
        case .captionQualityRejected:
            return "The English caption track failed quality checks and cannot be used. Try another video."
        case .rateLimited(let retryAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "YouTube caption requests are rate limited. Try again after \(formatter.string(from: retryAt))."
        case .attestationRequired:
            return "The current caption track requires additional verification."
        case .accessBlocked(let status):
            return "YouTube blocked the caption request (HTTP \(status))."
        case .httpFailure(let status):
            return "YouTube caption request failed (HTTP \(status))."
        }
    }

    public var stableErrorCode: String {
        switch self {
        case .rateLimited:
            "youtube_caption_rate_limited"
        case .attestationRequired:
            "youtube_caption_attestation_required"
        case .accessBlocked:
            "youtube_caption_access_blocked"
        case .missingEnglishTrack:
            "youtube_caption_missing"
        default:
            "source_caption_failed"
        }
    }
}

public protocol YTCaptionClock: Sendable {
    var now: Date { get }
}

public struct SystemYTCaptionClock: YTCaptionClock {
    public init() {}
    public var now: Date { Date() }
}

public protocol YTCaptionJitterSource: Sendable {
    /// Returns a factor in `0...0.2` applied on top of base delays.
    func factor() -> Double
}

public struct RandomYTCaptionJitterSource: YTCaptionJitterSource {
    public init() {}
    public func factor() -> Double { Double.random(in: 0...0.2) }
}

public struct FixedYTCaptionJitterSource: YTCaptionJitterSource {
    private let value: Double
    public init(_ value: Double) { self.value = min(max(value, 0), 0.2) }
    public func factor() -> Double { value }
}

public protocol YTCaptionRequestStateStoring: Sendable {
    func load() -> YTCaptionPersistedRequestState
    func save(_ state: YTCaptionPersistedRequestState)
}

public struct YTCaptionPersistedRequestState: Codable, Equatable, Sendable {
    public var negativeMissingEnglish: [YTCaptionNegativeCacheEntry]
    public var rateLimit: YTCaptionRateLimitState

    public init(
        negativeMissingEnglish: [YTCaptionNegativeCacheEntry] = [],
        rateLimit: YTCaptionRateLimitState = YTCaptionRateLimitState()
    ) {
        self.negativeMissingEnglish = negativeMissingEnglish
        self.rateLimit = rateLimit
    }
}

public struct YTCaptionNegativeCacheEntry: Codable, Equatable, Sendable {
    public var videoID: String
    public var expiresAt: Date

    public init(videoID: String, expiresAt: Date) {
        self.videoID = videoID
        self.expiresAt = expiresAt
    }
}

public struct YTCaptionRateLimitState: Codable, Equatable, Sendable {
    public var cooldownUntil: Date?
    public var consecutiveCount: Int
    public var lastRateLimitedAt: Date?

    public init(
        cooldownUntil: Date? = nil,
        consecutiveCount: Int = 0,
        lastRateLimitedAt: Date? = nil
    ) {
        self.cooldownUntil = cooldownUntil
        self.consecutiveCount = consecutiveCount
        self.lastRateLimitedAt = lastRateLimitedAt
    }
}

public final class UserDefaultsYTCaptionRequestStateStore: YTCaptionRequestStateStoring, @unchecked Sendable {
    public static let storageKey = "youtubeCaptionRequestState.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> YTCaptionPersistedRequestState {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(YTCaptionPersistedRequestState.self, from: data)
        else {
            return YTCaptionPersistedRequestState()
        }
        return decoded
    }

    public func save(_ state: YTCaptionPersistedRequestState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

public struct YTCaptionRequestKey: Hashable, Sendable {
    public var videoID: String
    public var language: String
    public var translationLanguage: String
    public var pipelineVersion: Int
    public var qualityTolerance: Double
    /// Part of the cache key so the strict and lenient policies never share a
    /// success-cache entry produced under the other policy's acceptance rules.
    public var ingestionPolicy: YTCaptionIngestionPolicy

    public init(
        videoID: String,
        language: String = "en",
        translationLanguage: String = "",
        pipelineVersion: Int = SubtitlePipelineVersion.current,
        qualityTolerance: Double,
        ingestionPolicy: YTCaptionIngestionPolicy = .strict
    ) {
        self.videoID = videoID
        self.language = language
        self.translationLanguage = translationLanguage
        self.pipelineVersion = pipelineVersion
        self.qualityTolerance = qualityTolerance
        self.ingestionPolicy = ingestionPolicy
    }
}

private struct CaptionCacheEntry<Value> {
    var value: Value
    var expiresAt: Date
}

private struct ResolvedCaptionTrack: Sendable {
    var track: YTCaptionTrack
    var userAgent: String
    var visitorData: String?
    var cookieHeader: String?
    var clientType: String
}

public actor YTCaptionRequestCoordinator {
    public static let shared = YTCaptionRequestCoordinator()

    private let stateStore: YTCaptionRequestStateStoring
    private let clock: YTCaptionClock
    private let jitter: YTCaptionJitterSource
    private let minimumLaunchSpacing: TimeInterval
    private let successCacheLimit: Int
    private let trackCacheLimit: Int
    private let negativeCacheLimit: Int
    private let successTTL: TimeInterval
    private let trackTTL: TimeInterval
    private let negativeTTL: TimeInterval

    private var inFlight: [YTCaptionRequestKey: Task<YTEnglishCaptionPackage, Error>] = [:]
    private var successCache: [YTCaptionRequestKey: CaptionCacheEntry<YTEnglishCaptionPackage>] = [:]
    private var successOrder: [YTCaptionRequestKey] = []
    private var trackCache: [String: CaptionCacheEntry<[ResolvedCaptionTrack]>] = [:]
    private var trackOrder: [String] = []
    private var lastLaunchAt: Date?
    private var persisted: YTCaptionPersistedRequestState

    public init(
        stateStore: YTCaptionRequestStateStoring = UserDefaultsYTCaptionRequestStateStore(),
        clock: YTCaptionClock = SystemYTCaptionClock(),
        jitter: YTCaptionJitterSource = RandomYTCaptionJitterSource(),
        minimumLaunchSpacing: TimeInterval = 2,
        successCacheLimit: Int = 20,
        trackCacheLimit: Int = 50,
        negativeCacheLimit: Int = 200,
        successTTL: TimeInterval = 600,
        trackTTL: TimeInterval = 300,
        negativeTTL: TimeInterval = 6 * 3600
    ) {
        self.stateStore = stateStore
        self.clock = clock
        self.jitter = jitter
        self.minimumLaunchSpacing = minimumLaunchSpacing
        self.successCacheLimit = successCacheLimit
        self.trackCacheLimit = trackCacheLimit
        self.negativeCacheLimit = negativeCacheLimit
        self.successTTL = successTTL
        self.trackTTL = trackTTL
        self.negativeTTL = negativeTTL
        var loaded = stateStore.load()
        loaded.negativeMissingEnglish.removeAll { $0.expiresAt <= clock.now }
        if let last = loaded.rateLimit.lastRateLimitedAt,
           clock.now.timeIntervalSince(last) > 24 * 3600 {
            loaded.rateLimit.consecutiveCount = 0
            loaded.rateLimit.lastRateLimitedAt = nil
        }
        if let until = loaded.rateLimit.cooldownUntil, until <= clock.now {
            loaded.rateLimit.cooldownUntil = nil
        }
        self.persisted = loaded
        stateStore.save(loaded)
    }

    public func rateLimitedRetryAt(now: Date? = nil) -> Date? {
        let current = now ?? clock.now
        prunePersistedLocked(now: current)
        guard let until = persisted.rateLimit.cooldownUntil, until > current else { return nil }
        return until
    }

    public func fetchEnglishPackage(
        key: YTCaptionRequestKey,
        operation: @escaping @Sendable () async throws -> YTEnglishCaptionPackage
    ) async throws -> YTEnglishCaptionPackage {
        let now = clock.now
        prunePersistedLocked(now: now)

        if let until = persisted.rateLimit.cooldownUntil, until > now {
            YTCaptionLog.info("cooldown hit video=\(key.videoID)")
            throw YTCaptionError.rateLimited(retryAt: until)
        }

        if let cached = successCache[key], cached.expiresAt > now {
            YTCaptionLog.info("success cache hit video=\(key.videoID)")
            return cached.value
        }

        if isNegativelyCached(videoID: key.videoID, now: now) {
            YTCaptionLog.info("negative cache hit video=\(key.videoID)")
            throw YTCaptionError.missingEnglishTrack
        }

        if let existing = inFlight[key] {
            YTCaptionLog.info("single-flight join video=\(key.videoID)")
            return try await existing.value
        }

        if let lastLaunchAt {
            let elapsed = now.timeIntervalSince(lastLaunchAt)
            if elapsed < minimumLaunchSpacing {
                let delay = minimumLaunchSpacing - elapsed
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        lastLaunchAt = clock.now

        let task = Task<YTEnglishCaptionPackage, Error> {
            try await operation()
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let value = try await task.value
            storeSuccess(key: key, value: value, now: clock.now)
            clearRateLimitAfterSuccess(now: clock.now)
            return value
        } catch let error as YTCaptionError {
            if case .missingEnglishTrack = error {
                storeNegativeMissing(videoID: key.videoID, now: clock.now)
            }
            throw error
        } catch {
            throw error
        }
    }

    fileprivate func cachedTracks(videoID: String, now: Date? = nil) -> [ResolvedCaptionTrack]? {
        let current = now ?? clock.now
        guard let entry = trackCache[videoID], entry.expiresAt > current else { return nil }
        return entry.value
    }

    fileprivate func storeTracks(_ tracks: [ResolvedCaptionTrack], videoID: String, now: Date? = nil) {
        let current = now ?? clock.now
        trackCache[videoID] = CaptionCacheEntry(value: tracks, expiresAt: current.addingTimeInterval(trackTTL))
        touchOrder(&trackOrder, key: videoID, limit: trackCacheLimit) {
            trackCache.removeValue(forKey: $0)
        }
    }

    func clearTracks(videoID: String) {
        trackCache.removeValue(forKey: videoID)
        trackOrder.removeAll { $0 == videoID }
    }

    func noteRateLimited(retryAt: Date, now: Date? = nil) {
        let current = now ?? clock.now
        prunePersistedLocked(now: current)
        var rate = persisted.rateLimit
        if let last = rate.lastRateLimitedAt, current.timeIntervalSince(last) > 24 * 3600 {
            rate.consecutiveCount = 0
        }
        rate.consecutiveCount += 1
        rate.lastRateLimitedAt = current
        rate.cooldownUntil = max(retryAt, rate.cooldownUntil ?? .distantPast)
        persisted.rateLimit = rate
        persistLocked()
    }

    func makeDefaultCooldown(now: Date? = nil) -> Date {
        let current = now ?? clock.now
        prunePersistedLocked(now: current)
        var rate = persisted.rateLimit
        if let last = rate.lastRateLimitedAt, current.timeIntervalSince(last) > 24 * 3600 {
            rate.consecutiveCount = 0
        }
        let nextCount = rate.consecutiveCount + 1
        let minutes: Double
        switch nextCount {
        case 1: minutes = 15
        case 2: minutes = 30
        case 3: minutes = 60
        case 4: minutes = 120
        default: minutes = 360
        }
        let capped = min(minutes, 360)
        let delay = capped * 60 * (1 + jitter.factor())
        return current.addingTimeInterval(delay)
    }

    private func clearRateLimitAfterSuccess(now: Date) {
        prunePersistedLocked(now: now)
        persisted.rateLimit = YTCaptionRateLimitState()
        persistLocked()
    }

    private func storeSuccess(key: YTCaptionRequestKey, value: YTEnglishCaptionPackage, now: Date) {
        successCache[key] = CaptionCacheEntry(value: value, expiresAt: now.addingTimeInterval(successTTL))
        touchOrder(&successOrder, key: key, limit: successCacheLimit) {
            successCache.removeValue(forKey: $0)
        }
    }

    private func storeNegativeMissing(videoID: String, now: Date) {
        persisted.negativeMissingEnglish.removeAll { $0.videoID == videoID }
        persisted.negativeMissingEnglish.append(
            YTCaptionNegativeCacheEntry(videoID: videoID, expiresAt: now.addingTimeInterval(negativeTTL))
        )
        if persisted.negativeMissingEnglish.count > negativeCacheLimit {
            persisted.negativeMissingEnglish = Array(persisted.negativeMissingEnglish.suffix(negativeCacheLimit))
        }
        persistLocked()
    }

    private func isNegativelyCached(videoID: String, now: Date) -> Bool {
        persisted.negativeMissingEnglish.contains { $0.videoID == videoID && $0.expiresAt > now }
    }

    private func prunePersistedLocked(now: Date) {
        persisted.negativeMissingEnglish.removeAll { $0.expiresAt <= now }
        if let last = persisted.rateLimit.lastRateLimitedAt, now.timeIntervalSince(last) > 24 * 3600 {
            persisted.rateLimit.consecutiveCount = 0
            persisted.rateLimit.lastRateLimitedAt = nil
        }
        if let until = persisted.rateLimit.cooldownUntil, until <= now {
            persisted.rateLimit.cooldownUntil = nil
        }
        persistLocked()
    }

    private func persistLocked() {
        stateStore.save(persisted)
    }

    private func touchOrder<Key: Equatable>(
        _ order: inout [Key],
        key: Key,
        limit: Int,
        onEvict: (Key) -> Void
    ) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            let evicted = order.removeFirst()
            onEvict(evicted)
        }
    }
}

public final class YTCaptionService: @unchecked Sendable {
    public static let sharedCoordinator = YTCaptionRequestCoordinator.shared

    private let session: URLSession
    private let coordinator: YTCaptionRequestCoordinator
    private let clock: YTCaptionClock
    private let jitter: YTCaptionJitterSource
    private let ownsSession: Bool

    public init(
        session: URLSession? = nil,
        coordinator: YTCaptionRequestCoordinator? = nil,
        stateStore: YTCaptionRequestStateStoring? = nil,
        clock: YTCaptionClock? = nil,
        jitter: YTCaptionJitterSource? = nil
    ) {
        let resolvedClock = clock ?? SystemYTCaptionClock()
        let resolvedJitter = jitter ?? RandomYTCaptionJitterSource()
        self.clock = resolvedClock
        self.jitter = resolvedJitter
        if let coordinator {
            self.coordinator = coordinator
        } else if let stateStore {
            self.coordinator = YTCaptionRequestCoordinator(
                stateStore: stateStore,
                clock: resolvedClock,
                jitter: resolvedJitter
            )
        } else {
            self.coordinator = Self.sharedCoordinator
        }
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
            configuration.httpShouldSetCookies = true
            configuration.httpCookieStorage = HTTPCookieStorage()
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    public func fetchEnglishCaptionPackage(
        videoID: String,
        qualityTolerance: Double,
        language: String = "en",
        translationLanguage: String = "",
        pipelineVersion: Int = SubtitlePipelineVersion.current,
        ingestionPolicy: YTCaptionIngestionPolicy = .strict
    ) async throws -> YTEnglishCaptionPackage {
        let key = YTCaptionRequestKey(
            videoID: videoID,
            language: language,
            translationLanguage: translationLanguage,
            pipelineVersion: pipelineVersion,
            qualityTolerance: qualityTolerance,
            ingestionPolicy: ingestionPolicy
        )
        return try await coordinator.fetchEnglishPackage(key: key) {
            try await self.downloadEnglishCaptionPackage(
                videoID: videoID,
                qualityTolerance: qualityTolerance,
                ingestionPolicy: ingestionPolicy
            )
        }
    }

    public func fetchNativeChineseVTT(videoID: String) async throws -> String {
        let resolved = try await discoverTracks(
            videoID: videoID,
            allowTrackCache: true,
            prefers: { isChineseTrack($0.track) }
        )
        var lastError: Error = YTCaptionError.emptyCaptionResponse
        var sawAttestation = false
        for item in chineseTrackCandidates(from: resolved) {
            if item.track.requiresAttestation {
                sawAttestation = true
                continue
            }
            do {
                return try await fetchCaptionAsVTT(resolved: item)
            } catch let error as YTCaptionError {
                if case .rateLimited = error { throw error }
                if case .accessBlocked = error { throw error }
                if case .attestationRequired = error {
                    sawAttestation = true
                    continue
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        if sawAttestation, (lastError as? YTCaptionError) == .emptyCaptionResponse {
            throw YTCaptionError.attestationRequired
        }
        throw lastError
    }

    public func fetchAutoTranslatedChineseVTT(videoID: String) async throws -> String {
        let resolved = try await discoverTracks(
            videoID: videoID,
            allowTrackCache: true,
            prefers: { $0.track.languageCode.lowercased().hasPrefix("en") && $0.track.isTranslatable }
        )
        var lastError: Error = YTCaptionError.emptyCaptionResponse
        var sawAttestation = false
        for item in englishTrackCandidates(from: resolved) where item.track.isTranslatable {
            if item.track.requiresAttestation {
                sawAttestation = true
                continue
            }
            do {
                return try await fetchCaptionAsVTT(resolved: item, translatedTo: "zh-Hans")
            } catch let error as YTCaptionError {
                if case .rateLimited = error { throw error }
                if case .accessBlocked = error { throw error }
                if case .attestationRequired = error {
                    sawAttestation = true
                    continue
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        if sawAttestation, (lastError as? YTCaptionError) == .emptyCaptionResponse {
            throw YTCaptionError.attestationRequired
        }
        throw lastError
    }

    private func downloadEnglishCaptionPackage(
        videoID: String,
        qualityTolerance: Double,
        ingestionPolicy: YTCaptionIngestionPolicy
    ) async throws -> YTEnglishCaptionPackage {
        YTCaptionLog.info("download start video=\(videoID)")
        let tracks = try await discoverTracks(
            videoID: videoID,
            allowTrackCache: true,
            prefers: { $0.track.languageCode.lowercased().hasPrefix("en") }
        )
        let english = englishTrackCandidates(from: tracks)
        let usable = english.filter { !$0.track.requiresAttestation }
        if usable.isEmpty {
            if english.contains(where: { $0.track.requiresAttestation }) {
                throw YTCaptionError.attestationRequired
            }
            throw YTCaptionError.missingEnglishTrack
        }

        var preferredError: Error = YTCaptionError.emptyCaptionResponse
        var preferredPriority = YTCaptionFailurePriority.priority(for: preferredError)
        var refreshedOnce = false

        for item in usable {
            do {
                YTCaptionLog.info(
                    "fetch track lang=\(item.track.languageCode) kind=\(item.track.kind ?? "manual") source=\(item.clientType)"
                )
                let package = try await fetchCaptionPackage(
                    resolved: item,
                    outlierTolerancePercent: qualityTolerance,
                    ingestionPolicy: ingestionPolicy
                )
                guard !package.segments.isEmpty else { throw YTCaptionError.emptyCaptionFile }
                return package
            } catch let error as YTCaptionError {
                switch error {
                case .rateLimited, .accessBlocked, .attestationRequired, .captionQualityRejected:
                    throw error
                case .httpFailure(let status) where (status == 404 || status == 410) && !refreshedOnce:
                    refreshedOnce = true
                    YTCaptionLog.info("signature expired status=\(status) refreshing tracks")
                    await coordinator.clearTracks(videoID: videoID)
                    let refreshed = try await discoverTracks(
                        videoID: videoID,
                        allowTrackCache: false,
                        prefers: { $0.track.languageCode.lowercased().hasPrefix("en") }
                    )
                    let refreshedUsable = englishTrackCandidates(from: refreshed)
                        .filter { !$0.track.requiresAttestation }
                    guard let first = refreshedUsable.first else {
                        throw YTCaptionError.missingEnglishTrack
                    }
                    return try await fetchCaptionPackage(
                        resolved: first,
                        outlierTolerancePercent: qualityTolerance,
                        ingestionPolicy: ingestionPolicy
                    )
                default:
                    let priority = YTCaptionFailurePriority.priority(for: error)
                    if priority < preferredPriority {
                        preferredPriority = priority
                        preferredError = error
                    }
                }
            } catch {
                let priority = YTCaptionFailurePriority.priority(for: error)
                if priority < preferredPriority {
                    preferredPriority = priority
                    preferredError = error
                }
            }
        }
        throw preferredError
    }

    private func discoverTracks(
        videoID: String,
        allowTrackCache: Bool,
        prefers: (ResolvedCaptionTrack) -> Bool
    ) async throws -> [ResolvedCaptionTrack] {
        if allowTrackCache, let cached = await coordinator.cachedTracks(videoID: videoID), cached.contains(where: prefers) {
            YTCaptionLog.info("track cache hit video=\(videoID) count=\(cached.count)")
            return cached
        }

        let watch = try await loadWatchContext(videoID: videoID)
        let watchTracks = dedupeTracks(watch.tracks.map {
            ResolvedCaptionTrack(
                track: $0,
                userAgent: watch.userAgent,
                visitorData: watch.visitorData,
                cookieHeader: watch.cookieHeader,
                clientType: "web"
            )
        })
        let usableWatch = watchTracks.filter { !$0.track.requiresAttestation }
        if usableWatch.contains(where: prefers) {
            YTCaptionLog.info("using watch tracks count=\(usableWatch.count)")
            await coordinator.storeTracks(usableWatch, videoID: videoID)
            return usableWatch
        }

        var sawAttestationOnly = watchTracks.contains(where: { $0.track.requiresAttestation && prefers($0) })
        YTCaptionLog.info("watch tracks unusable attestationOnly=\(sawAttestationOnly); trying ios")

        do {
            let iosTracks = try await loadInnertubeTracks(
                videoID: videoID,
                client: .ios,
                apiKey: watch.apiKey,
                visitorData: watch.visitorData,
                cookieHeader: watch.cookieHeader
            )
            let usableIOS = dedupeTracks(iosTracks).filter { !$0.track.requiresAttestation }
            if usableIOS.contains(where: prefers) {
                await coordinator.storeTracks(usableIOS, videoID: videoID)
                return usableIOS
            }
            if iosTracks.contains(where: { $0.track.requiresAttestation && prefers($0) }) {
                sawAttestationOnly = true
            }

            // Only rotate to Android VR when iOS returned no usable target tracks
            // (empty / unsupported), never after 429/403/HTML risk pages.
            YTCaptionLog.info("ios tracks empty; trying android_vr")
            let vrTracks = try await loadInnertubeTracks(
                videoID: videoID,
                client: .androidVR,
                apiKey: watch.apiKey,
                visitorData: watch.visitorData,
                cookieHeader: watch.cookieHeader
            )
            let usableVR = dedupeTracks(vrTracks).filter { !$0.track.requiresAttestation }
            if usableVR.contains(where: prefers) {
                await coordinator.storeTracks(usableVR, videoID: videoID)
                return usableVR
            }
            if vrTracks.contains(where: { $0.track.requiresAttestation && prefers($0) }) {
                sawAttestationOnly = true
            }
        } catch let error as YTCaptionError {
            switch error {
            case .rateLimited, .accessBlocked:
                throw error
            default:
                YTCaptionLog.info("innertube discovery failed: \(error.stableErrorCode)")
            }
        } catch {
            YTCaptionLog.info("innertube discovery failed: \(error.localizedDescription)")
        }

        if sawAttestationOnly {
            throw YTCaptionError.attestationRequired
        }
        return []
    }

    private struct WatchContext {
        var tracks: [YTCaptionTrack]
        var userAgent: String
        var visitorData: String?
        var cookieHeader: String?
        var apiKey: String?
    }

    private func loadWatchContext(videoID: String) async throws -> WatchContext {
        let userAgent = YTCaptionClients.webUserAgent
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            throw YTCaptionError.httpFailure(status: -1)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await performCaptionRequest(request, operation: "watch")
        try throwIfInvalidYouTubeResponse(response, data: data, context: "watch")
        let html = String(data: data, encoding: .utf8) ?? ""
        let tracks = (try? YTCaptionTrackExtractor.captionTracks(fromWatchHTML: html)) ?? []
        return WatchContext(
            tracks: tracks,
            userAgent: userAgent,
            visitorData: YTCaptionTrackExtractor.visitorData(fromWatchHTML: html),
            cookieHeader: cookieHeader(for: url),
            apiKey: YTCaptionTrackExtractor.innertubeAPIKey(fromWatchHTML: html)
        )
    }

    private func loadInnertubeTracks(
        videoID: String,
        client: YTCaptionClients.Client,
        apiKey: String?,
        visitorData: String?,
        cookieHeader: String?
    ) async throws -> [ResolvedCaptionTrack] {
        guard let url = innertubePlayerURL(apiKey: apiKey) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.headerName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: innertubePlayerBody(videoID: videoID, client: client, visitorData: visitorData)
        )
        let (data, response) = try await performCaptionRequest(request, operation: "player_\(client.name)")
        try throwIfInvalidYouTubeResponse(response, data: data, context: "player")
        let tracks = try YTCaptionTrackExtractor.captionTracks(fromPlayerResponseData: data)
        return tracks.map {
            ResolvedCaptionTrack(
                track: $0,
                userAgent: client.userAgent,
                visitorData: visitorData,
                cookieHeader: cookieHeader,
                clientType: client.name.lowercased()
            )
        }
    }

    private func fetchCaptionPackage(
        resolved: ResolvedCaptionTrack,
        outlierTolerancePercent: Double,
        ingestionPolicy: YTCaptionIngestionPolicy
    ) async throws -> YTEnglishCaptionPackage {
        do {
            let json = try await fetchCaptionText(resolved: resolved, format: "json3")
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return try await fetchVTTPackage(
                    resolved: resolved,
                    outlierTolerancePercent: outlierTolerancePercent,
                    ingestionPolicy: ingestionPolicy
                )
            }
            let semanticSegments = YTVTTParser.learningSegmentsFromYouTubeJSON3(json)
            let semanticQuality = YTCaptionSegmentationQualityPolicy.report(
                for: semanticSegments,
                outlierTolerancePercent: outlierTolerancePercent
            )
            if semanticQuality.isAcceptable
                || (ingestionPolicy == .acceptParseableContent && !semanticSegments.isEmpty) {
                YTCaptionLog.info(
                    "semantic json3 accepted segments=\(semanticQuality.segmentCount) source=\(resolved.clientType) policy=\(ingestionPolicy.rawValue)"
                )
                return YTEnglishCaptionPackage(
                    englishVTT: YTVTTParser.makeVTT(from: YTVTTParser.sourceCues(from: semanticSegments)),
                    segments: semanticSegments
                )
            }
            let cues = YTVTTParser.cuesFromYouTubeJSON3(json)
            if !cues.isEmpty {
                let fallbackSegments = YTVTTParser.captionIngestionSegments(from: cues)
                let fallbackQuality = YTCaptionSegmentationQualityPolicy.report(
                    for: fallbackSegments,
                    outlierTolerancePercent: outlierTolerancePercent
                )
                if fallbackQuality.isAcceptable
                    || (ingestionPolicy == .acceptParseableContent && !fallbackSegments.isEmpty) {
                    YTCaptionLog.info(
                        "json3 cue accepted segments=\(fallbackQuality.segmentCount) source=\(resolved.clientType) policy=\(ingestionPolicy.rawValue)"
                    )
                    return YTEnglishCaptionPackage(
                        englishVTT: YTVTTParser.makeVTT(from: YTVTTParser.sourceCues(from: fallbackSegments)),
                        segments: fallbackSegments
                    )
                }
                YTCaptionLog.info(
                    "json3 rejected source=\(resolved.clientType) policy=\(ingestionPolicy.rawValue) semanticSegments=\(semanticSegments.count) cues=\(cues.count) cueSegments=\(fallbackSegments.count) jsonBytes=\(json.utf8.count) head=\(String(json.prefix(160)).replacingOccurrences(of: "\n", with: " "))"
                )
                throw YTCaptionError.captionQualityRejected
            }
            // JSON3 body present but unparseable: one VTT fallback.
            return try await fetchVTTPackage(
                resolved: resolved,
                outlierTolerancePercent: outlierTolerancePercent,
                ingestionPolicy: ingestionPolicy
            )
        } catch let error as YTCaptionError {
            switch error {
            case .rateLimited, .accessBlocked, .attestationRequired, .captionQualityRejected, .httpFailure:
                throw error
            case .emptyCaptionFile, .emptyCaptionResponse:
                return try await fetchVTTPackage(
                    resolved: resolved,
                    outlierTolerancePercent: outlierTolerancePercent,
                    ingestionPolicy: ingestionPolicy
                )
            case .missingEnglishTrack:
                throw error
            }
        } catch {
            throw error
        }
    }

    private func fetchVTTPackage(
        resolved: ResolvedCaptionTrack,
        outlierTolerancePercent: Double,
        ingestionPolicy: YTCaptionIngestionPolicy
    ) async throws -> YTEnglishCaptionPackage {
        let vtt = try await fetchCaptionText(resolved: resolved, format: "vtt")
        let cues = YTVTTParser.parse(vtt)
        guard !cues.isEmpty else { throw YTCaptionError.emptyCaptionFile }
        let segments = YTVTTParser.captionIngestionSegments(from: cues)
        let quality = YTCaptionSegmentationQualityPolicy.report(
            for: segments,
            outlierTolerancePercent: outlierTolerancePercent
        )
        // Lenient policy still requires a non-empty parseable track; only the timeline
        // quality gate is skipped here.
        guard quality.isAcceptable || ingestionPolicy == .acceptParseableContent else {
            YTCaptionLog.info(
                "vtt rejected source=\(resolved.clientType) policy=\(ingestionPolicy.rawValue) cues=\(cues.count) segments=\(segments.count)"
            )
            throw YTCaptionError.captionQualityRejected
        }
        return YTEnglishCaptionPackage(
            englishVTT: YTVTTParser.makeVTT(from: YTVTTParser.sourceCues(from: segments)),
            segments: segments
        )
    }

    private func fetchCaptionAsVTT(
        resolved: ResolvedCaptionTrack,
        translatedTo languageCode: String? = nil
    ) async throws -> String {
        do {
            let json = try await fetchCaptionText(
                resolved: resolved,
                translatedTo: languageCode,
                format: "json3"
            )
            let cues = YTVTTParser.cuesFromYouTubeJSON3(json)
            if !cues.isEmpty {
                return YTVTTParser.makeVTT(from: cues)
            }
        } catch let error as YTCaptionError {
            switch error {
            case .rateLimited, .accessBlocked, .attestationRequired:
                throw error
            default:
                break
            }
        }
        let vtt = try await fetchCaptionText(
            resolved: resolved,
            translatedTo: languageCode,
            format: "vtt"
        )
        guard !YTVTTParser.parse(vtt).isEmpty else { throw YTCaptionError.emptyCaptionFile }
        return vtt
    }

    private func fetchCaptionText(
        resolved: ResolvedCaptionTrack,
        translatedTo languageCode: String? = nil,
        format: String?
    ) async throws -> String {
        if resolved.track.requiresAttestation {
            throw YTCaptionError.attestationRequired
        }
        guard let url = YTCaptionTrackExtractor.captionURL(
            for: resolved.track,
            translatedTo: languageCode,
            format: format
        ) else {
            throw YTCaptionError.httpFailure(status: -1)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(resolved.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData = resolved.visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if let cookieHeader = resolved.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await performCaptionRequest(
            request,
            operation: "timedtext_\(format ?? "default")"
        )
        try throwIfInvalidYouTubeResponse(response, data: data, context: "timedtext")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func performCaptionRequest(
        _ request: URLRequest,
        operation: String
    ) async throws -> (Data, URLResponse) {
        if let retryAt = await coordinator.rateLimitedRetryAt() {
            throw YTCaptionError.rateLimited(retryAt: retryAt)
        }

        var attempt = 1
        let maxAttempts = 2
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    YTCaptionLog.info("response op=\(operation) status=\(http.statusCode)")
                    if http.statusCode == 429 {
                        let retryAt = retryAtDate(from: http, fallback: await coordinator.makeDefaultCooldown())
                        await coordinator.noteRateLimited(retryAt: retryAt)
                        throw YTCaptionError.rateLimited(retryAt: retryAt)
                    }
                    if (500...599).contains(http.statusCode), attempt < maxAttempts {
                        let delay = 1.0 * (1 + jitter.factor())
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                }
                return (data, response)
            } catch let error as YTCaptionError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.isTransientCaptionNetworkError {
                if attempt >= maxAttempts {
                    throw error
                }
                let delay = 1.0 * (1 + jitter.factor())
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            } catch {
                throw error
            }
        }
    }

    private func throwIfInvalidYouTubeResponse(
        _ response: URLResponse,
        data: Data,
        context: String
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw YTCaptionError.httpFailure(status: -1)
        }
        if (200..<300).contains(http.statusCode) {
            return
        }
        if http.statusCode == 429 {
            let retryAt = retryAtDate(from: http, fallback: clock.now.addingTimeInterval(15 * 60))
            throw YTCaptionError.rateLimited(retryAt: retryAt)
        }
        if http.statusCode == 403 {
            throw YTCaptionError.accessBlocked(status: 403)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        let isHTML = body.localizedCaseInsensitiveContains("<!doctype html")
            || body.localizedCaseInsensitiveContains("<html")
        if isHTML, http.statusCode == 403 || http.statusCode >= 500 {
            throw YTCaptionError.accessBlocked(status: http.statusCode)
        }
        YTCaptionLog.info("http failure context=\(context) status=\(http.statusCode)")
        throw YTCaptionError.httpFailure(status: http.statusCode)
    }

    private func retryAtDate(from response: HTTPURLResponse, fallback: Date) -> Date {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return fallback
        }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return clock.now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return date
        }
        return fallback
    }

    private func cookieHeader(for url: URL) -> String? {
        let cookies = session.configuration.httpCookieStorage?.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    private func innertubePlayerURL(apiKey: String?) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")
        var items = [URLQueryItem(name: "prettyPrint", value: "false")]
        if let apiKey, !apiKey.isEmpty {
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        components?.queryItems = items
        return components?.url
    }

    private func innertubePlayerBody(
        videoID: String,
        client: YTCaptionClients.Client,
        visitorData: String?
    ) -> [String: Any] {
        var clientContext = client.context
        if let visitorData, !visitorData.isEmpty {
            clientContext["visitorData"] = visitorData
        }
        return [
            "context": [
                "client": clientContext
            ],
            "videoId": videoID,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
    }

    private func englishTrackCandidates(from tracks: [ResolvedCaptionTrack]) -> [ResolvedCaptionTrack] {
        tracks
            .filter { $0.track.languageCode.lowercased().hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.track.requiresAttestation != rhs.track.requiresAttestation {
                    return !lhs.track.requiresAttestation
                }
                if (lhs.track.kind == "asr") != (rhs.track.kind == "asr") {
                    return lhs.track.kind != "asr"
                }
                return lhs.track.name < rhs.track.name
            }
    }

    private func chineseTrackCandidates(from tracks: [ResolvedCaptionTrack]) -> [ResolvedCaptionTrack] {
        tracks.filter { isChineseTrack($0.track) }
        .sorted { lhs, rhs in
            if (lhs.track.kind == "asr") != (rhs.track.kind == "asr") {
                return lhs.track.kind != "asr"
            }
            let lhsSimplified = ["zh", "zh-cn", "zh-hans"].contains(lhs.track.languageCode.lowercased())
            let rhsSimplified = ["zh", "zh-cn", "zh-hans"].contains(rhs.track.languageCode.lowercased())
            if lhsSimplified != rhsSimplified {
                return lhsSimplified
            }
            return lhs.track.name < rhs.track.name
        }
    }

    private func isChineseTrack(_ track: YTCaptionTrack) -> Bool {
        let code = track.languageCode.lowercased()
        return ["zh", "zh-cn", "zh-hans", "zh-hant"].contains(code)
            || track.name.contains("中文")
            || track.name.localizedCaseInsensitiveContains("Chinese")
    }

    private func dedupeTracks(_ tracks: [ResolvedCaptionTrack]) -> [ResolvedCaptionTrack] {
        var result: [ResolvedCaptionTrack] = []
        var seen: Set<String> = []
        for track in tracks {
            guard seen.insert(track.track.stableIdentity).inserted else { continue }
            result.append(track)
        }
        return result
    }
}

private enum YTCaptionFailurePriority: Int, Comparable {
    case qualityRejected = 0
    case unparseable = 1
    case transport = 2
    case emptyResponse = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func priority(for error: Error) -> Self {
        guard let captionError = error as? YTCaptionError else {
            return .transport
        }
        switch captionError {
        case .captionQualityRejected:
            return .qualityRejected
        case .emptyCaptionFile:
            return .unparseable
        case .emptyCaptionResponse, .missingEnglishTrack, .attestationRequired:
            return .emptyResponse
        case .rateLimited, .accessBlocked, .httpFailure:
            return .transport
        }
    }
}

private enum YTCaptionClients {
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    struct Client {
        var name: String
        var version: String
        var headerName: String
        var userAgent: String
        var extraContext: [String: Any]

        var context: [String: Any] {
            var value = extraContext
            value["clientName"] = name
            value["clientVersion"] = version
            value["userAgent"] = userAgent
            value["hl"] = "en"
            value["timeZone"] = "UTC"
            value["utcOffsetMinutes"] = 0
            return value
        }

        static let ios = Client(
            name: "IOS",
            version: "21.02.3",
            headerName: "5",
            userAgent: "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            extraContext: [
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2.22D82"
            ]
        )

        static let androidVR = Client(
            name: "ANDROID_VR",
            version: "1.71.26",
            headerName: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.71.26 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extraContext: [
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L"
            ]
        )
    }
}

private enum YTCaptionLog {
    static func info(_ message: String) {
        print("YTCaptionService: \(message)")
    }
}

private extension URLError {
    var isTransientCaptionNetworkError: Bool {
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
