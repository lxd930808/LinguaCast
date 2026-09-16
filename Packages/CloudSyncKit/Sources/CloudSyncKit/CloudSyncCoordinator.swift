import CloudKit
import Foundation
import Observation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels

public enum CloudSyncPhase: Equatable, Sendable {
    case starting
    case noAccount
    case awaitingAccountConfirmation
    case syncing
    case synced
    case failed(String)
}

@MainActor
public protocol SubtitleArtifactSyncing: AnyObject {
    var subtitleArtifactCount: Int { get }
    var subtitleArtifactByteCount: Int64 { get }

    func lookup(identity: SubtitleArtifactIdentity) async -> SubtitleArtifactLookupResult
    func publishReady(
        identity: SubtitleArtifactIdentity,
        segments: [LearningSegment],
        generatedAt: Date
    ) async throws
    func backfillReadyArtifacts(context: ModelContext) async
    func clearCloudSubtitleCache() async
}

@MainActor
@Observable
public final class CloudSyncCoordinator: NSObject, CKSyncEngineDelegate, SubtitleArtifactSyncing, @unchecked Sendable {
    private enum StorageKey {
        static let documents = "CloudSync.documents.v1"
        static let systemFields = "CloudSync.systemFields.v1"
        static let pendingApplications = "CloudSync.pendingApplications.v1"
        static let engineState = "CloudSync.engineState.v1"
        static let deviceID = "CloudSync.deviceID.v1"
        static let accountID = "CloudSync.accountID.v1"
        static let playbackProgress = "CloudSync.playbackProgress.v1"
        static let pendingPlaybackApplications = "CloudSync.pendingPlaybackApplications.v1"
        static let subtitleArtifactEngineMigrationVersion = "CloudSync.subtitleArtifactEngineMigrationVersion"
        static let podcastDefinitiveMisses = "CloudSync.podcastDefinitiveMisses.v1"
        static let podcastAttemptStates = "CloudSync.podcastAttemptStates.v1"
    }

    /// Podcast 定向补全请求目标（按订阅分组）。
    public struct PodcastCatalogRecoveryRequest: Sendable, Hashable {
        public var subscriptionIdentity: String
        public var episodeGUIDs: Set<String>

        public init(subscriptionIdentity: String, episodeGUIDs: Set<String>) {
            self.subscriptionIdentity = subscriptionIdentity
            self.episodeGUIDs = episodeGUIDs
        }
    }

    /// 单个订阅的 RSS 补全尝试状态（用于退避）。
    struct PodcastAttemptState: Codable, Hashable, Sendable {
        var consecutiveFailures: Int
        var lastAttemptAt: Date?
    }

    private enum SecureStorageAccount {
        static let configurationDocuments = "CloudSync.configurationDocuments.v1"
        static let pendingConfigurationApplications = "CloudSync.pendingConfigurationApplications.v1"
    }

    private struct LegacyStorageMigrationError: LocalizedError {
        let storageKey: String

        var errorDescription: String? {
            "The legacy iCloud sync cache \(storageKey) could not be decoded. It was retained for recovery."
        }
    }

    // iCloud 回归重点：container / zone / recordType / recordName 全部保持不变。
    private static let containerIdentifier = "iCloud.com.local.PodcastEnglishStudio"
    private static let configurationRecordName = "configuration"
    private static let subtitleArtifactRecordType = "LCSubtitleArtifact"
    private static let playbackProgressRecordType = "LCPlaybackProgress"
    private static let currentSubtitleArtifactEngineMigrationVersion = 1
    private static let zoneID = CKRecordZone.ID(zoneName: "LinguaCastSync")

    public var phase: CloudSyncPhase = .starting
    public var lastSuccessfulSyncAt: Date?
    private var subtitleCacheRevision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()
    @ObservationIgnored private var documents: [String: SyncDocument]
    @ObservationIgnored private var systemFields: [String: Data]
    @ObservationIgnored private var pendingApplications: [String: SyncDocument]
    @ObservationIgnored private var playbackProgress: [String: PlaybackProgressState]
    @ObservationIgnored private var pendingPlaybackApplications: [String: PlaybackProgressState]
    @ObservationIgnored private var podcastDefinitiveMisses: [String: PodcastCatalogDefinitiveMiss]
    @ObservationIgnored private var podcastAttemptStates: [String: PodcastAttemptState]
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var database: CKDatabase?
    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var currentAccountID: String?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isZoneRecoveryQueued = false
    @ObservationIgnored private let artifactStore = SubtitleArtifactLocalStore()

    /// app 侧注入的远程通知注册回调（原 `UIApplication.shared.registerForRemoteNotifications()`）。
    /// 为 nil 时跳过注册；包内不依赖 UIKit。
    @ObservationIgnored public var remoteNotificationRegistrar: (() -> Void)?

    /// app 侧注入：返回指定 podcast episode 的 legacy segments.json URL（用于升级回填）。
    @ObservationIgnored public var legacyPodcastSegmentsURLProvider: ((String) -> URL?)?
    /// app 侧注入：返回指定 YouTube 视频的 legacy segments.json URL（用于升级回填）。
    @ObservationIgnored public var legacyYouTubeSegmentsURLProvider: ((String) -> URL?)?

    /// 可注入时钟（计划：时间判断使用可注入时钟）。默认系统时间；测试注入固定值。
    @ObservationIgnored public var nowProvider: () -> Date = { Date() }

    /// app 侧注入的 Podcast RSS 拉取实现（定向补全用）。测试注入假实现。
    @ObservationIgnored public var podcastFeedFetcher: (any PodcastFeedDataFetching)?
    /// app 侧注入的 YouTube 视频详情拉取实现（定向补全用）。测试注入假实现。
    @ObservationIgnored public var youTubeVideoDetailsFetcher: (any YouTubeVideoDetailsFetching)?

    public let deviceID: String

    public var subtitleArtifactCount: Int {
        _ = subtitleCacheRevision
        return artifactStore.activeCount
    }
    public var subtitleArtifactByteCount: Int64 {
        _ = subtitleCacheRevision
        return artifactStore.activeByteCount
    }

    public static let shared = CloudSyncCoordinator(defaults: .standard, keychain: KeychainStore())

    /// Package-internal initializer used by `shared` and by unit tests with an isolated `UserDefaults` suite.
    init(defaults: UserDefaults, keychain: KeychainStore = KeychainStore()) {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        self.defaults = defaults
        self.keychain = keychain
        let storedDocuments = Self.loadAndMigrateDocuments(
            defaults: defaults,
            keychain: keychain,
            storageKey: StorageKey.documents,
            secureAccount: SecureStorageAccount.configurationDocuments,
            decoder: decoder,
            encoder: encoder
        )
        documents = storedDocuments.documents
        if let data = defaults.data(forKey: StorageKey.systemFields),
           let stored = try? JSONDecoder().decode([String: Data].self, from: data) {
            systemFields = stored
        } else {
            systemFields = [:]
        }
        let storedPendingApplications = Self.loadAndMigrateDocuments(
            defaults: defaults,
            keychain: keychain,
            storageKey: StorageKey.pendingApplications,
            secureAccount: SecureStorageAccount.pendingConfigurationApplications,
            decoder: decoder,
            encoder: encoder
        )
        pendingApplications = storedPendingApplications.documents
        if let data = defaults.data(forKey: StorageKey.playbackProgress),
           let stored = try? decoder.decode([String: PlaybackProgressState].self, from: data) {
            playbackProgress = stored
        } else {
            playbackProgress = [:]
        }
        if let data = defaults.data(forKey: StorageKey.pendingPlaybackApplications),
           let stored = try? decoder.decode([String: PlaybackProgressState].self, from: data) {
            pendingPlaybackApplications = stored
        } else {
            pendingPlaybackApplications = [:]
        }
        if let data = defaults.data(forKey: StorageKey.podcastDefinitiveMisses),
           let stored = try? decoder.decode([String: PodcastCatalogDefinitiveMiss].self, from: data) {
            podcastDefinitiveMisses = stored
        } else {
            podcastDefinitiveMisses = [:]
        }
        if let data = defaults.data(forKey: StorageKey.podcastAttemptStates),
           let stored = try? decoder.decode([String: PodcastAttemptState].self, from: data) {
            podcastAttemptStates = stored
        } else {
            podcastAttemptStates = [:]
        }
        if let stored = defaults.string(forKey: StorageKey.deviceID) {
            deviceID = stored
        } else {
            let generated = UUID().uuidString
            deviceID = generated
            defaults.set(generated, forKey: StorageKey.deviceID)
        }
        super.init()
        if let migrationError = storedDocuments.error ?? storedPendingApplications.error {
            phase = .failed(migrationError.localizedDescription)
        }
    }

    private static func loadAndMigrateDocuments(
        defaults: UserDefaults,
        keychain: KeychainStore,
        storageKey: String,
        secureAccount: String,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) -> (documents: [String: SyncDocument], error: Error?) {
        let legacyData = defaults.data(forKey: storageKey)
        var loadedSecure: [String: SyncDocument] = [:]

        do {
            if let secureData = try keychain.readData(account: secureAccount) {
                loadedSecure = try decoder.decode([String: SyncDocument].self, from: secureData)
            }

            guard let legacyData else { return (loadedSecure, nil) }
            guard let legacy = try? decoder.decode([String: SyncDocument].self, from: legacyData) else {
                return (loadedSecure, LegacyStorageMigrationError(storageKey: storageKey))
            }

            let partition = SyncDocumentPersistencePartition.partition(legacy)
            var mergedSecure = loadedSecure
            for (recordName, legacyDocument) in partition.secure {
                mergedSecure[recordName] = mergedSecure[recordName]?.merged(with: legacyDocument) ?? legacyDocument
            }

            // Prepare both payloads before changing either store. The legacy defaults value
            // is rewritten only after Keychain confirms that the secure copy is durable.
            let ordinaryData = try encoder.encode(partition.ordinary)
            let secureData = try encoder.encode(mergedSecure)
            if mergedSecure.isEmpty {
                try keychain.deleteData(account: secureAccount)
            } else {
                try keychain.writeData(secureData, account: secureAccount)
            }
            defaults.set(ordinaryData, forKey: storageKey)

            return (
                SyncDocumentPersistencePartition(
                    secure: mergedSecure,
                    ordinary: partition.ordinary
                ).recombined,
                nil
            )
        } catch {
            if let legacyData,
               let legacy = try? decoder.decode([String: SyncDocument].self, from: legacyData) {
                let partition = SyncDocumentPersistencePartition.partition(legacy)
                for (recordName, legacyDocument) in partition.secure {
                    loadedSecure[recordName] = loadedSecure[recordName]?.merged(with: legacyDocument) ?? legacyDocument
                }
                return (
                    SyncDocumentPersistencePartition(
                        secure: loadedSecure,
                        ordinary: partition.ordinary
                    ).recombined,
                    error
                )
            }
            return (loadedSecure, error)
        }
    }

    public var statusTitle: String {
        switch phase {
        case .starting: CloudSyncKitL10n.string("cloud.status.starting", fallback: "Checking iCloud")
        case .noAccount: CloudSyncKitL10n.string("cloud.status.no_account", fallback: "Not Signed In to iCloud")
        case .awaitingAccountConfirmation: CloudSyncKitL10n.string("cloud.status.account_changed", fallback: "iCloud Account Changed")
        case .syncing: CloudSyncKitL10n.string("cloud.status.syncing", fallback: "Syncing")
        case .synced: CloudSyncKitL10n.string("cloud.status.synced", fallback: "iCloud Sync Is Active")
        case .failed: CloudSyncKitL10n.string("cloud.status.failed", fallback: "iCloud Sync Failed")
        }
    }

    public var statusDetail: String {
        switch phase {
        case .starting: return CloudSyncKitL10n.string("cloud.detail.starting", fallback: "Checking the account and cloud changes.")
        case .noAccount: return CloudSyncKitL10n.string("cloud.detail.no_account", fallback: "Local data remains available. Sync starts after you sign in to iCloud.")
        case .awaitingAccountConfirmation: return CloudSyncKitL10n.string("cloud.detail.account_changed", fallback: "Confirm before merging local data into the new account.")
        case .syncing: return CloudSyncKitL10n.string("cloud.detail.syncing", fallback: "Uploading and downloading settings, subscriptions, and subtitle results.")
        case .synced:
            if let lastSuccessfulSyncAt {
                return CloudSyncKitL10n.format(
                    "cloud.detail.synced_at",
                    fallback: "Last synced: %@",
                    lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened)
                )
            }
            return CloudSyncKitL10n.string("cloud.detail.synced", fallback: "Settings, subscriptions, and completed subtitle results stay in sync between iPhone and Apple TV.")
        case .failed(let message): return message
        }
    }

    public func start(context: ModelContext, settings: SettingsStore) {
        attachModelContext(context)
        self.settings = settings
        settings.onSave = { [weak self, weak settings] keys, modifiedAt in
            guard let self, let settings else { return }
            self.recordConfigurationChange(keys, configuration: settings.configuration, modifiedAt: modifiedAt)
        }
        guard startTask == nil, engine == nil else { return }
        phase = .starting
        startTask = Task { [weak self] in
            await self?.establishEngine()
            self?.startTask = nil
        }
    }

    public func recordConfigurationChange(
        _ keys: Set<AppConfigurationKey>,
        configuration: AppConfiguration,
        modifiedAt: Date = Date()
    ) {
        guard !keys.isEmpty else { return }
        var document = documents[Self.configurationRecordName] ?? SyncDocument(
            recordName: Self.configurationRecordName,
            kind: .configuration,
            fields: [:]
        )
        let version = SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID)
        for key in keys {
            document.fields[key.rawValue] = SyncFieldValue(value: configuration[key], version: version)
        }
        saveAndQueue(document)
    }

    // MARK: Playback progress sync (record type LCPlaybackProgress)

    // Identifies one playable item's progress record. YouTube videos key on their stable
    // video id; podcast episodes key on the (stable) subscription identity + episode GUID,
    // since EpisodeRecord.id is a per-install UUID and cannot sync across devices.
    public enum PlaybackProgressItem: Sendable {
        case youtubeVideo(videoID: String)
        case podcastEpisode(subscriptionSourceURL: String, episodeGUID: String)
    }

    // Local per-item progress state, keyed by recordName and persisted to UserDefaults.
    // Playback progress uses its own record type (LCPlaybackProgress) and does not go
    // through SyncDocumentKind, mirroring the subtitle-artifact path.
    //
    // 可选目录快照（catalog）与播放进度共用一条记录但**独立 LWW**：进度看 `version`，
    // 快照看 `catalog.version`。旧客户端写不带快照的新进度时不得清除已有快照。
    struct PlaybackProgressState: Codable, Hashable, Sendable {
        var recordName: String
        var positionSeconds: Double?
        var durationSeconds: Double?
        var completedAt: Date?
        var version: SyncFieldVersion
        /// 精简可播放目录快照；旧格式记录为 nil，走定向网络补全。
        var catalog: PlaybackCatalogSnapshot?

        var catalogVersion: SyncFieldVersion? {
            catalog?.version
        }
    }

    /// 进度与快照分别 LWW 的合并（计划 §1）。本地与远端同 recordName 时：
    /// - 进度取 version 较新的一方；
    /// - 快照独立比较 catalogVersion，较新者胜出；
    /// - 任一方缺少快照时保留另一方的快照（不清除）。
    static func mergedPlaybackProgress(
        local: PlaybackProgressState?,
        remote: PlaybackProgressState
    ) -> PlaybackProgressState {
        guard let local else { return remote }
        let progressWinner = local.version > remote.version ? local : remote
        let catalogWinner: PlaybackCatalogSnapshot?
        switch (local.catalog, remote.catalog) {
        case let (l?, r?):
            catalogWinner = l.version >= r.version ? l : r
        case let (l?, nil):
            catalogWinner = l
        case let (nil, r?):
            catalogWinner = r
        case (nil, nil):
            catalogWinner = nil
        }
        var merged = progressWinner
        merged.catalog = catalogWinner
        return merged
    }

    // Records one playable item's progress locally and queues it for upload. Merges by
    // version (last-writer-wins per record), so an older write never overwrites a newer one.
    //
    // `catalog` 为可选目录快照。进度与快照独立 LWW：本次携带快照且其版本较新时更新快照，
    // 否则保留已有快照（旧客户端不带快照的进度写入不会清除云端快照）。
    public func recordPlaybackProgress(
        _ item: PlaybackProgressItem,
        positionSeconds: Double?,
        durationSeconds: Double?,
        completedAt: Date?,
        modifiedAt: Date = Date(),
        catalog: PlaybackCatalogSnapshot? = nil
    ) {
        let recordName = Self.playbackProgressRecordName(for: item)
        let version = SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID)
        if let existing = playbackProgress[recordName], existing.version >= version {
            return
        }
        // 快照独立 LWW：仅当本次快照较新（或原本无快照）时采用。
        let resolvedCatalog: PlaybackCatalogSnapshot?
        switch (playbackProgress[recordName]?.catalog, catalog) {
        case let (existingCatalog?, newCatalog?):
            resolvedCatalog = newCatalog.version >= existingCatalog.version ? newCatalog : existingCatalog
        case let (existingCatalog?, nil):
            resolvedCatalog = existingCatalog
        case let (nil, newCatalog?):
            resolvedCatalog = newCatalog
        case (nil, nil):
            resolvedCatalog = nil
        }
        playbackProgress[recordName] = PlaybackProgressState(
            recordName: recordName,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            completedAt: completedAt,
            version: version,
            catalog: resolvedCatalog
        )
        persistPlaybackProgress()
        guard let engine else {
            return
        }
        let recordID = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    static func playbackProgressRecordName(for item: PlaybackProgressItem) -> String {
        switch item {
        case .youtubeVideo(let videoID):
            return "playback-yt-\(videoID.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .podcastEpisode(let subscriptionSourceURL, let episodeGUID):
            let subscriptionKey = SyncRecordIdentity.podcast(sourceURL: subscriptionSourceURL)
            return "playback-ep-\(subscriptionKey)-\(episodeGUID.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// 由快照内容复算其应对应的 record name，用于身份一致性校验（计划 §1：
    /// 快照身份与 record name 不一致时只丢快照、保留进度）。
    static func playbackProgressRecordName(for snapshot: PlaybackCatalogSnapshot) -> String {
        switch snapshot.content {
        case .podcast(let podcast):
            return playbackProgressRecordName(for: .podcastEpisode(
                subscriptionSourceURL: podcast.sourceURL,
                episodeGUID: podcast.episodeGUID
            ))
        case .youtube(let youtube):
            return playbackProgressRecordName(for: .youtubeVideo(videoID: youtube.videoID))
        }
    }

    /// 校验快照可安全用于物化：结构完整且身份与 record name 一致。
    /// 返回 nil 表示可用；否则返回丢弃原因（仅丢快照，不动进度）。
    static func catalogSnapshotRejection(
        _ snapshot: PlaybackCatalogSnapshot,
        forRecordName recordName: String
    ) -> PlaybackCatalogSnapshotRejection? {
        if let rejection = PlaybackCatalogSnapshotPolicy.completenessRejection(snapshot) {
            return rejection
        }
        guard playbackProgressRecordName(for: snapshot) == recordName else {
            return .identityMismatch
        }
        return nil
    }

    // MARK: 目录快照构造（从领域对象）

    /// 由 Podcast 领域对象构造目录快照。enclosure URL 非远程可播放时返回 nil（不生成残缺快照）。
    static func catalogSnapshot(
        episode: EpisodeRecord,
        subscription: PodcastSubscription,
        modifiedAt: Date,
        deviceID: String
    ) -> PlaybackCatalogSnapshot? {
        let snapshot = PlaybackCatalogSnapshot(
            content: .podcast(.init(
                sourceURL: subscription.showURL,
                episodeGUID: episode.episodeGUID,
                episodeTitle: episode.episodeTitle,
                showTitle: episode.showTitle.isEmpty ? subscription.displayName : episode.showTitle,
                showArtist: episode.showArtist,
                enclosureURL: episode.enclosureURL,
                publishedAt: episode.publishedAt
            )),
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
        // 仅当快照自身完整（GUID/标题/远程 enclosure）时才携带。
        guard PlaybackCatalogSnapshotPolicy.completenessRejection(snapshot) == nil else {
            return nil
        }
        return snapshot
    }

    /// 由 YouTube 领域对象构造目录快照。
    static func catalogSnapshot(
        video: YTVideoRecord,
        modifiedAt: Date,
        deviceID: String
    ) -> PlaybackCatalogSnapshot? {
        let snapshot = PlaybackCatalogSnapshot(
            content: .youtube(.init(
                videoID: video.id,
                channelID: video.channelID,
                title: video.title,
                playbackURL: video.url,
                thumbnailURL: video.thumbnail,
                publishedAt: video.publishedAt
            )),
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
        guard PlaybackCatalogSnapshotPolicy.completenessRejection(snapshot) == nil else {
            return nil
        }
        return snapshot
    }

    // MARK: 领域对象上报（推荐入口）

    /// 直接接收 Podcast 领域记录，内部生成稳定身份与目录快照（计划：上报接口直接接收领域记录）。
    public func recordPlaybackProgress(
        episode: EpisodeRecord,
        subscription: PodcastSubscription,
        positionSeconds: Double?,
        durationSeconds: Double?,
        completedAt: Date?,
        modifiedAt: Date = Date()
    ) {
        guard episode.catalogOrigin != .assistant else { return }
        let catalog = Self.catalogSnapshot(
            episode: episode,
            subscription: subscription,
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
        recordPlaybackProgress(
            .podcastEpisode(subscriptionSourceURL: subscription.showURL, episodeGUID: episode.episodeGUID),
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            completedAt: completedAt,
            modifiedAt: modifiedAt,
            catalog: catalog
        )
    }

    /// 直接接收 YouTube 领域记录，内部生成稳定身份与目录快照。
    public func recordPlaybackProgress(
        video: YTVideoRecord,
        positionSeconds: Double?,
        durationSeconds: Double?,
        completedAt: Date?,
        modifiedAt: Date = Date()
    ) {
        guard video.catalogOrigin != .assistant else { return }
        let catalog = Self.catalogSnapshot(video: video, modifiedAt: modifiedAt, deviceID: deviceID)
        recordPlaybackProgress(
            .youtubeVideo(videoID: video.id),
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            completedAt: completedAt,
            modifiedAt: modifiedAt,
            catalog: catalog
        )
    }

    /// 为已存在但缺少目录快照的进度记录回填快照（计划：最近 30 天快照回填）。
    /// 仅当该记录当前无快照、且能从本机领域对象构造出完整快照时写入；
    /// 快照版本取进度版本，不改动进度本身。返回是否有记录被更新。
    @discardableResult
    public func backfillMissingCatalogSnapshots(context: ModelContext) -> Bool {
        var changed = false
        for (recordName, state) in playbackProgress where state.catalog == nil {
            let snapshot: PlaybackCatalogSnapshot?
            if recordName.hasPrefix("playback-yt-"),
               let video = try? findYouTubeVideo(forPlaybackRecordName: recordName, in: context) {
                snapshot = Self.catalogSnapshot(
                    video: video,
                    modifiedAt: state.version.modifiedAt,
                    deviceID: deviceID
                )
            } else if recordName.hasPrefix("playback-ep-"),
                      let episode = try? findPodcastEpisode(forPlaybackRecordName: recordName, in: context),
                      let subscriptionID = episode.subscriptionID,
                      let subscription = try? context.fetch(
                        FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.id == subscriptionID })
                      ).first {
                snapshot = Self.catalogSnapshot(
                    episode: episode,
                    subscription: subscription,
                    modifiedAt: state.version.modifiedAt,
                    deviceID: deviceID
                )
            } else {
                snapshot = nil
            }
            guard let snapshot else { continue }
            var updated = state
            updated.catalog = snapshot
            playbackProgress[recordName] = updated
            changed = true
            if let engine {
                let recordID = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        }
        if changed { persistPlaybackProgress() }
        return changed
    }

    public func upsertPodcast(_ subscription: PodcastSubscription, modifiedAt: Date = Date()) {
        let recordName = SyncRecordIdentity.podcast(sourceURL: subscription.showURL)
        let previous = documents[recordName]
        var document = previous ?? SyncDocument(
            recordName: recordName,
            kind: .podcastSubscription,
            fields: [:]
        )
        let version = SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID)
        let wasDeleted = document.isDeleted
        setChangedFields([
            "sourceURL": subscription.showURL,
            "displayName": subscription.displayName,
            "feedURL": subscription.feedURL ?? "",
            "authorName": subscription.authorName ?? "",
            "summaryText": subscription.summaryText ?? "",
            "artworkURL": subscription.artworkURL ?? "",
            "artworkSource": subscription.artworkSource ?? "",
            "websiteURL": subscription.websiteURL ?? "",
            "applePodcastsURL": subscription.applePodcastsURL ?? "",
            "isEnabled": subscription.isEnabled ? "true" : "false"
        ], on: &document, version: version)
        if wasDeleted || document.fields["createdAt"] == nil {
            document.fields["createdAt"] = SyncFieldValue(
                value: Self.dateString(subscription.createdAt),
                version: wasDeleted ? version : .init(modifiedAt: subscription.createdAt, deviceID: deviceID)
            )
        }
        if document != previous { saveAndQueue(document) }
    }

    public func deletePodcast(_ subscription: PodcastSubscription, modifiedAt: Date = Date()) {
        tombstone(
            recordName: SyncRecordIdentity.podcast(sourceURL: subscription.showURL),
            kind: .podcastSubscription,
            modifiedAt: modifiedAt
        )
    }

    public func upsertYouTube(_ channel: YTChannelRecord, modifiedAt: Date = Date()) {
        let recordName = SyncRecordIdentity.youtube(channelID: channel.channelID)
        let previous = documents[recordName]
        var document = previous ?? SyncDocument(
            recordName: recordName,
            kind: .youtubeSubscription,
            fields: [:]
        )
        let version = SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID)
        let wasDeleted = document.isDeleted
        setChangedFields([
            "channelID": channel.channelID,
            "url": channel.url,
            "displayName": channel.displayName,
            "isEnabled": channel.isEnabled ? "true" : "false"
        ], on: &document, version: version)
        if wasDeleted || document.fields["createdAt"] == nil {
            document.fields["createdAt"] = SyncFieldValue(
                value: Self.dateString(channel.createdAt),
                version: wasDeleted ? version : .init(modifiedAt: channel.createdAt, deviceID: deviceID)
            )
        }
        if document != previous { saveAndQueue(document) }
    }

    public func deleteYouTube(_ channel: YTChannelRecord, modifiedAt: Date = Date()) {
        deleteYouTube(channelID: channel.channelID, modifiedAt: modifiedAt)
    }

    public func deleteYouTube(channelID: String, modifiedAt: Date = Date()) {
        tombstone(
            recordName: SyncRecordIdentity.youtube(channelID: channelID),
            kind: .youtubeSubscription,
            modifiedAt: modifiedAt
        )
    }

    /// 触发一次同步并等待最终状态（计划接口调整：等待启动中的 sync engine，返回最终同步状态）。
    /// 若 engine 尚未建立，先等待启动中的 startTask，再根据情况启动或同步。
    @discardableResult
    public func syncNow() async -> CloudSyncPhase {
        guard phase != .awaitingAccountConfirmation else { return phase }
        // 等待启动中的 sync engine（startTask 完成后 engine 才会就绪）。
        if let startTask { await startTask.value }
        guard let engine else {
            if let context = modelContext, let settings {
                start(context: context, settings: settings)
                if let startTask { await startTask.value }
            }
            // 启动后 engine 仍不可用（如无账号）→ 直接返回当前状态。
            guard self.engine != nil else { return phase }
            return await syncNow()
        }
        if case .failed = phase {
            isZoneRecoveryQueued = false
            queueAllDocuments()
        }
        phase = .syncing
        do {
            try retryPendingApplications()
            try await engine.fetchChanges()
            guard pendingApplications.isEmpty else { return phase }
            try await engine.sendChanges()
            if case .failed = phase { return phase }
            lastSuccessfulSyncAt = Date()
            phase = .synced
        } catch {
            phase = .failed(error.localizedDescription)
        }
        return phase
    }

    public func lookup(identity: SubtitleArtifactIdentity) async -> SubtitleArtifactLookupResult {
        if let startTask { await startTask.value }
        switch phase {
        case .synced, .syncing:
            await syncNow()
        case .starting:
            return .unavailable(CloudSyncKitL10n.string(
                "cloud.detail.starting",
                fallback: "Checking the account and cloud changes."
            ))
        case .noAccount:
            return .unavailable(CloudSyncKitL10n.string(
                "cloud.detail.no_account",
                fallback: "Local data remains available. Sync starts after you sign in to iCloud."
            ))
        case .awaitingAccountConfirmation:
            return .unavailable(CloudSyncKitL10n.string(
                "cloud.detail.account_changed",
                fallback: "Confirm before merging local data into the new account."
            ))
        case .failed(let message):
            return .unavailable(message)
        }

        if let envelope = artifactStore.envelope(for: identity) {
            return .ready(envelope)
        }
        if case .failed(let message) = phase {
            return .unavailable(message)
        }
        if let entry = artifactStore.entry(for: identity), !entry.metadata.isDeleted {
            try? artifactStore.removeEntry(for: identity)
            subtitleCacheRevision &+= 1
        }
        if let exactResult = await fetchArtifactDirectly(identity: identity) {
            switch exactResult {
            case .ready, .unavailable:
                return exactResult
            case .sourceOnly, .notFound:
                break
            }
        }
        if let source = artifactStore.anyEnvelope(
            contentKind: identity.contentKind,
            contentKey: identity.contentKey,
            excluding: identity.targetLanguage
        ) {
            return .sourceOnly(source)
        }
        return .notFound
    }

    public func publishReady(
        identity: SubtitleArtifactIdentity,
        segments: [LearningSegment],
        generatedAt: Date = Date()
    ) async throws {
        let envelope = SubtitleArtifactEnvelope(
            identity: identity,
            generatedAt: generatedAt,
            segments: segments
        )
        guard envelope.isComplete else { throw SubtitleArtifactValidationError.incomplete }
        let data = try envelope.encoded()
        let metadata = SubtitleArtifactMetadata(
            identity: identity,
            version: SyncFieldVersion(modifiedAt: generatedAt, deviceID: deviceID),
            sha256: SubtitleArtifactHash.sha256Hex(data),
            byteCount: Int64(data.count)
        )
        if let existing = artifactStore.entry(for: identity)?.metadata,
           SubtitleArtifactConflictPolicy.preferred(existing, metadata) == existing {
            return
        }
        try artifactStore.install(data: data, metadata: metadata)
        subtitleCacheRevision &+= 1
        queueArtifact(identity)
    }

    public func backfillReadyArtifacts(context: ModelContext) async {
        let variants = (try? context.fetch(FetchDescriptor<TranslationVariantRecord>())) ?? []
        let episodes = (try? context.fetch(FetchDescriptor<EpisodeRecord>())) ?? []
        let subscriptions = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        let videos = (try? context.fetch(FetchDescriptor<YTVideoRecord>())) ?? []
        let legacySegmentRecords = (try? context.fetch(FetchDescriptor<SegmentRecord>())) ?? []
        var episodeByID: [String: EpisodeRecord] = [:]
        var subscriptionByID: [String: PodcastSubscription] = [:]
        var videoByID: [String: YTVideoRecord] = [:]
        for episode in episodes where episodeByID[episode.id] == nil {
            episodeByID[episode.id] = episode
        }
        for subscription in subscriptions where subscriptionByID[subscription.id] == nil {
            subscriptionByID[subscription.id] = subscription
        }
        for video in videos where videoByID[video.id] == nil {
            videoByID[video.id] = video
        }
        var queuedRecordNames: Set<String> = []

        for variant in variants where variant.variantStatus == .ready {
            guard let path = variant.segmentsPath,
                  let data = try? Data(contentsOf: URL.storedFileURL(from: path)),
                  let segments = try? JSONDecoder().decode([LearningSegment].self, from: data),
                  !segments.isEmpty
            else { continue }

            let identity: SubtitleArtifactIdentity?
            switch TranslationContentKind(rawValue: variant.contentKind) {
            case .podcastEpisode:
                guard let episode = episodeByID[variant.contentID],
                      let subscriptionID = episode.subscriptionID,
                      let subscription = subscriptionByID[subscriptionID]
                else { continue }
                identity = .podcast(
                    sourceURL: subscription.showURL,
                    episodeGUID: episode.episodeGUID,
                    target: variant.target
                )
            case .youtubeVideo:
                guard let video = videoByID[variant.contentID] else { continue }
                identity = .youtube(videoID: video.id, target: variant.target)
            case nil:
                identity = nil
            }
            guard let identity else { continue }
            guard SubtitleArtifactEnvelope(
                identity: identity,
                generatedAt: variant.updatedAt,
                segments: segments
            ).isComplete else { continue }
            try? await publishReady(identity: identity, segments: segments, generatedAt: variant.updatedAt)
            queuedRecordNames.insert(identity.recordName)
        }

        // Older releases stored Simplified Chinese podcast results outside TranslationVariantRecord.
        // Backfill them during upgrade instead of waiting for every episode screen to be opened.
        let legacyRecordsByEpisode = Dictionary(grouping: legacySegmentRecords, by: \.episodeID)
        for episode in episodes {
            guard let subscriptionID = episode.subscriptionID,
                  let subscription = subscriptionByID[subscriptionID]
            else { continue }
            let identity = SubtitleArtifactIdentity.podcast(
                sourceURL: subscription.showURL,
                episodeGUID: episode.episodeGUID,
                target: .simplifiedChinese
            )
            guard !queuedRecordNames.contains(identity.recordName) else { continue }

            var segments: [LearningSegment]?
            if let segmentsURL = legacyPodcastSegmentsURLProvider?(episode.id),
               let data = try? Data(contentsOf: segmentsURL) {
                segments = try? JSONDecoder().decode([LearningSegment].self, from: data)
            }
            if segments?.isEmpty != false, let records = legacyRecordsByEpisode[episode.id], !records.isEmpty {
                segments = records.sorted { $0.sequence < $1.sequence }.map {
                    LearningSegment(
                        sequence: $0.sequence,
                        startMS: $0.startMS,
                        endMS: $0.endMS,
                        text: $0.text,
                        learningText: $0.learningText,
                        translation: $0.translation,
                        speaker: $0.speaker,
                        notes: $0.notes
                    )
                }
            }
            guard let segments else { continue }
            try? await publishReady(identity: identity, segments: segments, generatedAt: episode.updatedAt)
        }

        // Legacy YouTube records pointed directly at one completed segments file.
        for video in videos {
            let target = TranslationTargetPolicy.normalized(
                video.activeSubtitleTargetLanguage ?? TranslationTarget.simplifiedChinese.rawValue
            )
            let identity = SubtitleArtifactIdentity.youtube(videoID: video.id, target: target)
            guard !queuedRecordNames.contains(identity.recordName) else { continue }

            let candidateURL: URL?
            if let path = video.segmentsPath {
                candidateURL = URL.storedFileURL(from: path)
            } else {
                candidateURL = legacyYouTubeSegmentsURLProvider?(video.id)
            }
            guard let candidateURL,
                  let segments = try? JSONDecoder().decode(
                    [LearningSegment].self,
                    from: Data(contentsOf: candidateURL)
                  )
            else { continue }
            try? await publishReady(identity: identity, segments: segments, generatedAt: video.recordUpdatedAt)
        }
    }

    public func clearCloudSubtitleCache() async {
        let now = Date()
        for entry in artifactStore.allEntries where !entry.metadata.isDeleted {
            let tombstone = SubtitleArtifactMetadata.tombstone(
                identity: entry.metadata.identity,
                version: SyncFieldVersion(modifiedAt: now, deviceID: deviceID)
            )
            try? artifactStore.installTombstone(tombstone)
            subtitleCacheRevision &+= 1
            queueArtifact(tombstone.identity)
        }
        guard let engine else { return }
        do {
            try await engine.sendChanges()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func confirmAccountMigration() {
        guard phase == .awaitingAccountConfirmation, let currentAccountID else { return }
        defaults.set(currentAccountID, forKey: StorageKey.accountID)
        defaults.removeObject(forKey: StorageKey.engineState)
        systemFields = [:]
        persistSystemFields()
        engine = nil
        database = nil
        if let context = modelContext, let settings {
            start(context: context, settings: settings)
        }
    }

    // MARK: CKSyncEngineDelegate

    nonisolated public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, syncEngine: syncEngine)
    }

    nonisolated public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.record(for: recordID)
        }
    }

    // MARK: Engine lifecycle

    private func establishEngine() async {
        let container = CKContainer(identifier: Self.containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else {
                phase = .noAccount
                return
            }
            let accountID = try await container.userRecordID().recordName
            currentAccountID = accountID
            if SyncAccountPolicy.decision(
                previousAccountID: defaults.string(forKey: StorageKey.accountID),
                currentAccountID: accountID
            ) == .requireConfirmation {
                phase = .awaitingAccountConfirmation
                return
            }
            defaults.set(accountID, forKey: StorageKey.accountID)
            remoteNotificationRegistrar?()
            try retryPendingApplications()
            // Capture existing local values before fetching so first-run conflicts compare
            // the real local timestamps instead of allowing the fetched copy to win by order.
            seedLocalDocuments()

            let requiresFullArtifactFetch = !artifactStore.hasPersistedIndex || defaults.integer(
                forKey: StorageKey.subtitleArtifactEngineMigrationVersion
            ) < Self.currentSubtitleArtifactEngineMigrationVersion
            if requiresFullArtifactFetch {
                // Older clients advanced the shared change token while ignoring the then-unknown
                // subtitle record type. Reset once so the upgrade fetches every existing asset.
                defaults.removeObject(forKey: StorageKey.engineState)
            }
            let stateSerialization = defaults.data(forKey: StorageKey.engineState)
                .flatMap { try? decoder.decode(CKSyncEngine.State.Serialization.self, from: $0) }
            var configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: stateSerialization,
                delegate: self
            )
            configuration.automaticallySync = true
            isZoneRecoveryQueued = false
            let engine = CKSyncEngine(configuration)
            self.engine = engine
            database = container.privateCloudDatabase
            if stateSerialization == nil {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                try await engine.sendChanges()
            }
            phase = .syncing
            try await engine.fetchChanges()
            try artifactStore.ensureIndexExists()
            if requiresFullArtifactFetch {
                defaults.set(
                    Self.currentSubtitleArtifactEngineMigrationVersion,
                    forKey: StorageKey.subtitleArtifactEngineMigrationVersion
                )
            }
            guard pendingApplications.isEmpty else { return }
            if documents[Self.configurationRecordName]?.fields[AppConfigurationKey.translationTargetLanguage.rawValue] == nil {
                try settings?.promoteProvisionalTranslationTargetIfNeeded()
            }
            if let modelContext { await backfillReadyArtifacts(context: modelContext) }
            // 为已同步但缺少目录快照的进度记录回填快照（本机内容齐全时即刻生效）。
            if let modelContext { backfillMissingCatalogSnapshots(context: modelContext) }
            queueAllDocuments()
            try await engine.sendChanges()
            if case .failed = phase { return }
            lastSuccessfulSyncAt = Date()
            phase = .synced
        } catch {
            phase = Self.isNoAccount(error) ? .noAccount : .failed(error.localizedDescription)
        }
    }

    private func handle(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let update):
            if let data = try? encoder.encode(update.stateSerialization) {
                defaults.set(data, forKey: StorageKey.engineState)
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signOut:
                engine = nil
                database = nil
                phase = .noAccount
            case .switchAccounts(_, let currentUser):
                currentAccountID = currentUser.recordName
                engine = nil
                database = nil
                phase = .awaitingAccountConfirmation
            case .signIn(let currentUser):
                currentAccountID = currentUser.recordName
            @unknown default:
                phase = .failed(CloudSyncKitL10n.string("error.cloud_account_changed", fallback: "An unknown iCloud account change was detected. Reopen the app."))
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                mergeFetchedRecord(modification.record, syncEngine: syncEngine)
            }
            for deletion in changes.deletions {
                applyUnexpectedDeletion(deletion.recordID, recordType: deletion.recordType)
            }
        case .sentDatabaseChanges(let changes):
            if changes.savedZones.contains(where: { $0.zoneID == Self.zoneID }) {
                isZoneRecoveryQueued = false
            }
            if let failure = changes.failedZoneSaves.first(where: { $0.zone.zoneID == Self.zoneID }),
               Self.saveFailureKind(for: failure.error) != .transient {
                phase = .failed(failure.error.localizedDescription)
            }
        case .sentRecordZoneChanges(let changes):
            for record in changes.savedRecords {
                storeSystemFields(for: record)
            }
            var systemFieldsChanged = false
            var unresolvedError: CKError?
            let recoveryPlan = CloudRecordSaveRecoveryPolicy.plan(
                for: changes.failedRecordSaves.map {
                    CloudRecordSaveFailureContext(
                        failure: Self.saveFailureKind(for: $0.error),
                        hasSystemFields: systemFields[$0.record.recordID.recordName] != nil
                    )
                },
                isZoneRecoveryQueued: isZoneRecoveryQueued
            )
            if recoveryPlan.shouldQueueZoneSave {
                isZoneRecoveryQueued = true
                syncEngine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: Self.zoneID))
                ])
            }
            for (failure, action) in zip(changes.failedRecordSaves, recoveryPlan.actions) {
                let recordID = failure.record.recordID
                switch action {
                case .mergeServerRecord:
                    guard let serverRecord = failure.error.serverRecord else {
                        unresolvedError = unresolvedError ?? failure.error
                        continue
                    }
                    mergeFetchedRecord(serverRecord, syncEngine: syncEngine)
                case .recreateRecord:
                    systemFields.removeValue(forKey: recordID.recordName)
                    systemFieldsChanged = true
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                case .recreateZoneAndRetryRecord:
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                case .awaitAutomaticRetry:
                    break
                case .reportFailure:
                    unresolvedError = unresolvedError ?? failure.error
                }
            }

            for recordID in changes.deletedRecordIDs {
                systemFieldsChanged = systemFields.removeValue(forKey: recordID.recordName) != nil
                    || systemFieldsChanged
            }
            for (recordID, error) in changes.failedRecordDeletes {
                switch CloudRecordDeleteRecoveryPolicy.action(for: Self.saveFailureKind(for: error)) {
                case .acceptAsDeleted:
                    systemFieldsChanged = systemFields.removeValue(forKey: recordID.recordName) != nil
                        || systemFieldsChanged
                case .awaitAutomaticRetry:
                    break
                case .reportFailure:
                    unresolvedError = unresolvedError ?? error
                }
            }
            if systemFieldsChanged {
                persistSystemFields()
            }
            if let error = unresolvedError {
                phase = .failed(error.localizedDescription)
            }
        case .willFetchChanges, .willSendChanges:
            if pendingApplications.isEmpty { phase = .syncing }
        case .didFetchChanges:
            if case .failed = phase { break }
            guard pendingApplications.isEmpty else { break }
            lastSuccessfulSyncAt = Date()
            phase = .synced
        case .didSendChanges:
            if case .failed = phase { break }
            guard pendingApplications.isEmpty else { break }
            guard syncEngine.state.pendingRecordZoneChanges.isEmpty else {
                phase = .syncing
                break
            }
            lastSuccessfulSyncAt = Date()
            phase = .synced
        default:
            break
        }
    }

    // MARK: Documents

    private func seedLocalDocuments() {
        if let settings {
            var configurationDocument = documents[Self.configurationRecordName] ?? SyncDocument(
                recordName: Self.configurationRecordName,
                kind: .configuration,
                fields: [:]
            )
            for key in AppConfigurationKey.allCases {
                guard configurationDocument.fields[key.rawValue] == nil,
                      let modifiedAt = settings.fieldModificationDates[key]
                else { continue }
                configurationDocument.fields[key.rawValue] = SyncFieldValue(
                    value: settings.configuration[key],
                    version: SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID)
                )
            }
            if !configurationDocument.fields.isEmpty { saveAndQueue(configurationDocument) }
        }
        guard let modelContext else { return }
        for subscription in (try? modelContext.fetch(FetchDescriptor<PodcastSubscription>())) ?? [] {
            upsertPodcast(subscription, modifiedAt: subscription.updatedAt)
        }
        for channel in (try? modelContext.fetch(FetchDescriptor<YTChannelRecord>())) ?? [] {
            upsertYouTube(channel, modifiedAt: channel.updatedAt)
        }
    }

    private func setChangedFields(
        _ values: [String: String],
        on document: inout SyncDocument,
        version: SyncFieldVersion
    ) {
        let isRestoringDeletedDocument = document.isDeleted
        for (key, value) in values where isRestoringDeletedDocument || document.fields[key]?.value != value {
            document.fields[key] = SyncFieldValue(value: value, version: version)
        }
    }

    private func queueAllDocuments() {
        var changes = documents.values.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: $0.recordName, zoneID: Self.zoneID)
            )
        }
        changes.append(contentsOf: artifactStore.allEntries.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: $0.metadata.identity.recordName, zoneID: Self.zoneID)
            )
        })
        changes.append(contentsOf: playbackProgress.keys.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: $0, zoneID: Self.zoneID)
            )
        })
        engine?.state.add(pendingRecordZoneChanges: changes)
    }

    private func tombstone(recordName: String, kind: SyncDocumentKind, modifiedAt: Date) {
        var document = documents[recordName] ?? SyncDocument(recordName: recordName, kind: kind, fields: [:])
        document.deletionVersion = max(
            document.deletionVersion ?? .init(modifiedAt: .distantPast, deviceID: ""),
            .init(modifiedAt: modifiedAt, deviceID: deviceID)
        )
        saveAndQueue(document)
    }

    private func saveAndQueue(_ document: SyncDocument) {
        documents[document.recordName] = document
        persistDocuments()
        let recordID = CKRecord.ID(recordName: document.recordName, zoneID: Self.zoneID)
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private func queueArtifact(_ identity: SubtitleArtifactIdentity) {
        let recordID = CKRecord.ID(recordName: identity.recordName, zoneID: Self.zoneID)
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private func mergeFetchedPlaybackProgress(_ record: CKRecord, syncEngine: CKSyncEngine) {
        guard let remote = playbackProgressState(from: record) else { return }
        storeSystemFields(for: record)
        let merged = Self.mergedPlaybackProgress(
            local: playbackProgress[remote.recordName],
            remote: remote
        )
        playbackProgress[merged.recordName] = merged
        persistPlaybackProgress()
        applyOrDeferPlaybackProgress(merged)
        if merged != remote {
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
    }

    /// Last-writer-wins selection for one LCPlaybackProgress record.
    /// 进度与快照分别 LWW；保留给既有测试与调用点的语义封装。
    static func preferredPlaybackProgress(
        local: PlaybackProgressState?,
        remote: PlaybackProgressState
    ) -> PlaybackProgressState {
        mergedPlaybackProgress(local: local, remote: remote)
    }

    /// Binds a SwiftData context without starting CKSyncEngine. Used by unit tests and
    /// by `start(context:settings:)` before the engine is ready.
    func attachModelContext(_ context: ModelContext) {
        modelContext = context
    }

    /// Applies a merged progress state to SwiftData, or records it for later retry when
    /// the matching Episode/Video is not present yet.
    func applyOrDeferPlaybackProgress(_ state: PlaybackProgressState) {
        do {
            if try applyPlaybackProgressToLocalStore(state) {
                pendingPlaybackApplications.removeValue(forKey: state.recordName)
            } else {
                pendingPlaybackApplications[state.recordName] = state
            }
            persistPendingPlaybackApplications()
        } catch {
            pendingPlaybackApplications[state.recordName] = state
            persistPendingPlaybackApplications()
            phase = .failed(CloudSyncKitL10n.format(
                "error.cloud_apply_failed_detail",
                fallback: "Local data could not be applied and will be retried during the next sync.\nDetails: %@",
                error.localizedDescription
            ))
        }
    }

    /// Writes winning progress into an existing Episode/Video. Returns `false` when the
    /// matching local content is missing so the cache can be retried later. Never inserts
    /// incomplete Episode/Video records.
    func applyPlaybackProgressToLocalStore(_ state: PlaybackProgressState) throws -> Bool {
        guard let modelContext else { return false }

        if let video = try findYouTubeVideo(forPlaybackRecordName: state.recordName, in: modelContext) {
            return try writePlaybackProgress(state, to: video, in: modelContext)
        }
        if let episode = try findPodcastEpisode(forPlaybackRecordName: state.recordName, in: modelContext) {
            return try writePlaybackProgress(state, to: episode, in: modelContext)
        }
        // Keep the sync cache; content may appear after a later feed/channel refresh.
        return false
    }

    private func findYouTubeVideo(
        forPlaybackRecordName recordName: String,
        in context: ModelContext
    ) throws -> YTVideoRecord? {
        guard recordName.hasPrefix("playback-yt-") else { return nil }
        let videos = try context.fetch(FetchDescriptor<YTVideoRecord>())
        return videos.first {
            Self.playbackProgressRecordName(for: .youtubeVideo(videoID: $0.id)) == recordName
                && $0.catalogOrigin != .assistant
        }
    }

    private func findPodcastEpisode(
        forPlaybackRecordName recordName: String,
        in context: ModelContext
    ) throws -> EpisodeRecord? {
        guard recordName.hasPrefix("playback-ep-") else { return nil }
        let subscriptions = try context.fetch(FetchDescriptor<PodcastSubscription>())
        let episodes = try context.fetch(FetchDescriptor<EpisodeRecord>())
        let subscriptionByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
        return episodes.first { episode in
            guard let subscriptionID = episode.subscriptionID,
                  let subscription = subscriptionByID[subscriptionID]
            else { return false }
            return Self.playbackProgressRecordName(
                for: .podcastEpisode(
                    subscriptionSourceURL: subscription.showURL,
                    episodeGUID: episode.episodeGUID
                )
            ) == recordName
        }
    }

    private func writePlaybackProgress<T: PlaybackProgressWritable>(
        _ state: PlaybackProgressState,
        to target: T,
        in context: ModelContext
    ) throws -> Bool {
        // Defensive: never let an older remote stamp overwrite newer local SwiftData progress.
        if let localUpdated = target.playbackUpdatedAt,
           localUpdated > state.version.modifiedAt {
            return true
        }
        target.playbackPositionSeconds = state.positionSeconds
        target.playbackDurationSeconds = state.durationSeconds
        target.playbackCompletedAt = state.completedAt
        target.playbackUpdatedAt = state.version.modifiedAt
        try context.save()
        return true
    }

    private func mergeFetchedRecord(_ record: CKRecord, syncEngine: CKSyncEngine) {
        if record.recordType == Self.subtitleArtifactRecordType {
            mergeFetchedArtifact(record)
            return
        }
        if record.recordType == Self.playbackProgressRecordType {
            mergeFetchedPlaybackProgress(record, syncEngine: syncEngine)
            return
        }
        guard let remote = document(from: record) else { return }
        storeSystemFields(for: record)
        let merged = documents[remote.recordName]?.merged(with: remote) ?? remote
        documents[merged.recordName] = merged
        persistDocuments()
        do {
            try applyToLocalStore(merged)
            pendingApplications.removeValue(forKey: merged.recordName)
            persistPendingApplications()
        } catch {
            pendingApplications[merged.recordName] = merged
            persistPendingApplications()
            phase = .failed(CloudSyncKitL10n.format("error.cloud_apply_failed_detail", fallback: "Local data could not be applied and will be retried during the next sync.\nDetails: %@", error.localizedDescription))
        }
        if merged != remote {
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
    }

    private func applyUnexpectedDeletion(_ recordID: CKRecord.ID, recordType: String) {
        if recordType == Self.subtitleArtifactRecordType,
           let existing = artifactStore.entry(recordName: recordID.recordName) {
            let tombstone = SubtitleArtifactMetadata.tombstone(
                identity: existing.metadata.identity,
                version: .init(modifiedAt: Date(), deviceID: "cloudkit")
            )
            try? artifactStore.installTombstone(tombstone)
            subtitleCacheRevision &+= 1
            systemFields.removeValue(forKey: recordID.recordName)
            persistSystemFields()
            return
        }
        guard let kind = Self.kind(forRecordType: recordType) else { return }
        var document = documents[recordID.recordName] ?? SyncDocument(
            recordName: recordID.recordName,
            kind: kind,
            fields: [:]
        )
        document.deletionVersion = .init(modifiedAt: Date(), deviceID: "cloudkit")
        documents[recordID.recordName] = document
        systemFields.removeValue(forKey: recordID.recordName)
        persistDocuments()
        persistSystemFields()
        do {
            try applyToLocalStore(document)
        } catch {
            pendingApplications[document.recordName] = document
            persistPendingApplications()
            phase = .failed(CloudSyncKitL10n.format("error.cloud_apply_failed_detail", fallback: "Local data could not be applied and will be retried during the next sync.\nDetails: %@", error.localizedDescription))
        }
    }

    private func retryPendingApplications() throws {
        for (recordName, document) in Array(pendingApplications) {
            try applyToLocalStore(document)
            pendingApplications.removeValue(forKey: recordName)
            persistPendingApplications()
        }
        try retryPendingPlaybackApplications()
    }

    /// Retries progress records that were deferred because the matching Episode/Video was missing.
    func retryPendingPlaybackApplications() throws {
        for (recordName, state) in Array(pendingPlaybackApplications) {
            if try applyPlaybackProgressToLocalStore(state) {
                pendingPlaybackApplications.removeValue(forKey: recordName)
                persistPendingPlaybackApplications()
            }
        }
    }

    // MARK: 播放目录恢复（跨设备“继续播放”）

    /// 需要从网络定向补全的目标（快照缺失或不完整时）。
    public enum CatalogRecoveryTarget: Hashable, Sendable {
        /// 按订阅稳定身份 + 目标 GUID 集合发起一次 RSS 补全。
        case podcast(subscriptionIdentity: String, sourceURL: String, episodeGUIDs: Set<String>)
        /// 合并为一次 videos.list 的 video ID 集合。
        case youtube(videoIDs: Set<String>)
    }

    /// `recoverPendingPlaybackCatalog` 的结果。
    public struct CatalogRecoveryOutcome: Sendable {
        /// 已从完整快照直接物化的 recordName 数。
        public var materializedFromSnapshot: Int
        /// 尚需联网定向补全的目标。
        public var networkTargets: [CatalogRecoveryTarget]

        public init(materializedFromSnapshot: Int, networkTargets: [CatalogRecoveryTarget]) {
            self.materializedFromSnapshot = materializedFromSnapshot
            self.networkTargets = networkTargets
        }
    }

    /// 从 deferred progress 中筛选“继续播放”候选并安全物化可用快照（计划 §2/§3）。
    ///
    /// - 候选：inProgress、最近 30 天、倒序最多 20 条，排除已完成/未播/禁用/已删订阅。
    /// - 快照完整且身份一致 → 直接创建正常本地记录，并立即重放 deferred progress。
    /// - 已有本地记录 → 只应用进度，不用云端快照覆盖本地目录元数据。
    /// - 快照缺失/不完整 → 归类为网络定向补全目标，绝不创建残缺记录。
    @discardableResult
    public func recoverPendingPlaybackCatalog(context: ModelContext) -> CatalogRecoveryOutcome {
        let enabledState = sourceEnabledStates(context: context)
        let inputs = pendingPlaybackApplications.values.map { state -> PlaybackRecoveryCandidateInput in
            let (isEnabled, isDeleted) = enabledState[state.recordName] ?? (true, false)
            return PlaybackRecoveryCandidateInput(
                recordName: state.recordName,
                positionSeconds: state.positionSeconds,
                durationSeconds: state.durationSeconds,
                completedAt: state.completedAt,
                progressModifiedAt: state.version.modifiedAt,
                isSourceEnabled: isEnabled,
                isSourceDeleted: isDeleted
            )
        }
        let candidates = PlaybackRecoveryCandidatePolicy.selectCandidates(inputs, now: nowProvider())
        let candidateNames = Set(candidates.map(\.recordName))

        var materialized = 0
        var podcastGUIDsBySubscription: [String: (sourceURL: String, guids: Set<String>)] = [:]
        var youtubeVideoIDs: Set<String> = []

        for recordName in candidateNames {
            guard let state = pendingPlaybackApplications[recordName] else { continue }
            // 已有本地记录：只应用进度，不用快照覆盖本地目录。
            if (try? applyPlaybackProgressToLocalStore(state)) == true {
                pendingPlaybackApplications.removeValue(forKey: recordName)
                continue
            }
            // 无本地记录：尝试从完整快照物化。
            if let catalog = state.catalog,
               Self.catalogSnapshotRejection(catalog, forRecordName: recordName) == nil,
               materializeCatalogSnapshot(catalog, recordName: recordName, context: context) {
                if (try? applyPlaybackProgressToLocalStore(state)) == true {
                    pendingPlaybackApplications.removeValue(forKey: recordName)
                }
                // 新快照恢复成功 → 清除该 Podcast 目标可能存在的确定未命中标记。
                if case .podcast(let podcast) = catalog.content {
                    clearDefinitiveMiss(
                        subscriptionIdentity: SyncRecordIdentity.podcast(sourceURL: podcast.sourceURL),
                        episodeGUID: podcast.episodeGUID
                    )
                }
                materialized += 1
                continue
            }
            // 需要联网定向补全。
            if recordName.hasPrefix("playback-ep-"),
               let parsed = Self.parsePodcastPlaybackRecordName(recordName) {
                var entry = podcastGUIDsBySubscription[parsed.subscriptionIdentity]
                    ?? (sourceURL: parsed.sourceURL, guids: [])
                entry.guids.insert(parsed.episodeGUID)
                podcastGUIDsBySubscription[parsed.subscriptionIdentity] = entry
            } else if recordName.hasPrefix("playback-yt-"),
                      let videoID = Self.parseYouTubePlaybackRecordName(recordName) {
                youtubeVideoIDs.insert(videoID)
            }
        }
        persistPendingPlaybackApplications()

        var targets: [CatalogRecoveryTarget] = podcastGUIDsBySubscription.map { identity, entry in
            .podcast(subscriptionIdentity: identity, sourceURL: entry.sourceURL, episodeGUIDs: entry.guids)
        }
        if !youtubeVideoIDs.isEmpty {
            targets.append(.youtube(videoIDs: youtubeVideoIDs))
        }
        return CatalogRecoveryOutcome(materializedFromSnapshot: materialized, networkTargets: targets)
    }

    /// 仅从完整快照物化一条本地记录。返回是否成功创建（已存在或校验失败返回 false）。
    private func materializeCatalogSnapshot(
        _ snapshot: PlaybackCatalogSnapshot,
        recordName: String,
        context: ModelContext
    ) -> Bool {
        switch snapshot.content {
        case .podcast(let podcast):
            return materializePodcastSnapshot(podcast, recordName: recordName, context: context)
        case .youtube(let youtube):
            return materializeYouTubeSnapshot(youtube, recordName: recordName, context: context)
        }
    }

    private func materializePodcastSnapshot(
        _ podcast: PlaybackCatalogSnapshot.Content.Podcast,
        recordName: String,
        context: ModelContext
    ) -> Bool {
        // 必须具备有效订阅才能建立正常记录（计划 §3）。
        let subscriptions = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        guard let subscription = subscriptions.first(where: {
            $0.isEnabled &&
                SyncRecordIdentity.podcast(sourceURL: $0.showURL) == SyncRecordIdentity.podcast(sourceURL: podcast.sourceURL)
        }) else { return false }
        // 已存在同 GUID 记录则不重复创建。
        let episodes = (try? context.fetch(FetchDescriptor<EpisodeRecord>())) ?? []
        if episodes.contains(where: {
            $0.subscriptionID == subscription.id &&
                $0.episodeGUID.trimmingCharacters(in: .whitespacesAndNewlines) ==
                podcast.episodeGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        }) { return false }
        let episode = EpisodeRecord(
            id: UUID().uuidString,
            subscriptionID: subscription.id,
            showTitle: podcast.showTitle.isEmpty ? subscription.displayName : podcast.showTitle,
            showArtist: podcast.showArtist,
            episodeTitle: podcast.episodeTitle,
            episodeGUID: podcast.episodeGUID,
            publishedAt: podcast.publishedAt,
            enclosureURL: podcast.enclosureURL,
            status: "queued",
            pipelineStep: "discover",
            isNew: false
        )
        context.insert(episode)
        return (try? context.save()) != nil
    }

    private func materializeYouTubeSnapshot(
        _ youtube: PlaybackCatalogSnapshot.Content.YouTube,
        recordName: String,
        context: ModelContext
    ) -> Bool {
        // 必须具备有效且已同步的本地频道（计划 §3：YouTube 必须关联本机频道）。
        let channels = (try? context.fetch(FetchDescriptor<YTChannelRecord>())) ?? []
        guard let channel = channels.first(where: {
            $0.isEnabled && $0.channelID == youtube.channelID
        }) else { return false }
        let videos = (try? context.fetch(FetchDescriptor<YTVideoRecord>())) ?? []
        if videos.contains(where: { $0.id == youtube.videoID }) { return false }
        let video = YTVideoRecord(
            id: youtube.videoID,
            channelRecordID: channel.id,
            channelID: youtube.channelID,
            title: youtube.title,
            publishedAt: youtube.publishedAt,
            url: youtube.playbackURL,
            thumbnail: youtube.thumbnailURL
        )
        context.insert(video)
        return (try? context.save()) != nil
    }

    /// 计算每条进度记录对应订阅/频道的启用/删除状态（用于候选筛选）。
    private func sourceEnabledStates(context: ModelContext) -> [String: (isEnabled: Bool, isDeleted: Bool)] {
        let subscriptions = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        let channels = (try? context.fetch(FetchDescriptor<YTChannelRecord>())) ?? []
        var enabledSubscriptionIdentity: Set<String> = []
        for subscription in subscriptions where subscription.isEnabled {
            enabledSubscriptionIdentity.insert(SyncRecordIdentity.podcast(sourceURL: subscription.showURL))
        }
        var enabledChannelIDs: Set<String> = []
        for channel in channels where channel.isEnabled {
            enabledChannelIDs.insert(channel.channelID)
        }

        var result: [String: (Bool, Bool)] = [:]
        for recordName in pendingPlaybackApplications.keys {
            if let parsed = Self.parsePodcastPlaybackRecordName(recordName) {
                let isEnabled = enabledSubscriptionIdentity.contains(parsed.subscriptionIdentity)
                let isDeleted = subscriptionIsDeleted(identity: parsed.subscriptionIdentity)
                result[recordName] = (isEnabled, isDeleted)
            } else if let videoID = Self.parseYouTubePlaybackRecordName(recordName) {
                // YouTube 记录不直接携带频道；若本地存在该视频则按其频道判定，否则按存在启用频道兜底。
                let channelID = channelIDForLocalYouTubeVideo(videoID, context: context)
                let isEnabled = channelID.map { enabledChannelIDs.contains($0) } ?? !enabledChannelIDs.isEmpty
                result[recordName] = (isEnabled, false)
            }
        }
        return result
    }

    private func channelIDForLocalYouTubeVideo(_ videoID: String, context: ModelContext) -> String? {
        let videos = (try? context.fetch(FetchDescriptor<YTVideoRecord>())) ?? []
        return videos.first(where: { $0.id == videoID })?.channelID
    }

    /// 订阅是否已被 tombstone（从 documents 的 deletionVersion 判定）。
    private func subscriptionIsDeleted(identity: String) -> Bool {
        documents[identity]?.isDeleted ?? false
    }

    // MARK: Podcast 定向补全的存储与辅助（供 PodcastCatalogRecovery 扩展使用）

    /// 解析订阅稳定身份对应的本机 source URL（recordName 不含原始 URL）。
    func resolvedPodcastSourceURL(for identity: String, context: ModelContext) -> String? {
        let subscriptions = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        return subscriptions.first(where: {
            SyncRecordIdentity.podcast(sourceURL: $0.showURL) == identity
        })?.showURL
    }

    func isDefinitiveMiss(subscriptionIdentity: String, episodeGUID: String) -> Bool {
        podcastDefinitiveMisses["\(subscriptionIdentity)\n\(episodeGUID)"] != nil
    }

    func recordDefinitiveMiss(_ miss: PodcastCatalogDefinitiveMiss) {
        podcastDefinitiveMisses[miss.key] = miss
        persistPodcastDefinitiveMisses()
    }

    /// 恢复成功或收到完整快照后清除该订阅+GUID 的未命中标记（计划 §4）。
    func clearDefinitiveMiss(subscriptionIdentity: String, episodeGUID: String) {
        if podcastDefinitiveMisses.removeValue(forKey: "\(subscriptionIdentity)\n\(episodeGUID)") != nil {
            persistPodcastDefinitiveMisses()
        }
    }

    func podcastAttemptState(for identity: String) -> PodcastAttemptState {
        podcastAttemptStates[identity] ?? PodcastAttemptState(consecutiveFailures: 0, lastAttemptAt: nil)
    }

    func recordPodcastAttemptFailure(for identity: String, now: Date) {
        var state = podcastAttemptState(for: identity)
        state.consecutiveFailures += 1
        state.lastAttemptAt = now
        podcastAttemptStates[identity] = state
        persistPodcastAttemptStates()
    }

    func resetPodcastAttemptState(for identity: String) {
        if podcastAttemptStates.removeValue(forKey: identity) != nil {
            persistPodcastAttemptStates()
        }
    }

    /// 测试/扩展辅助：读取 deferred 进度快照（值拷贝）。
    func pendingPlaybackApplicationsSnapshot() -> [String: PlaybackProgressState] {
        pendingPlaybackApplications
    }

    /// 移除一条 deferred 进度（恢复成功后）。
    func removePendingPlaybackApplication(recordName: String) {
        if pendingPlaybackApplications.removeValue(forKey: recordName) != nil {
            persistPendingPlaybackApplications()
        }
    }

    private func persistPodcastDefinitiveMisses() {
        if podcastDefinitiveMisses.isEmpty {
            defaults.removeObject(forKey: StorageKey.podcastDefinitiveMisses)
            return
        }
        if let data = try? encoder.encode(podcastDefinitiveMisses) {
            defaults.set(data, forKey: StorageKey.podcastDefinitiveMisses)
        }
    }

    private func persistPodcastAttemptStates() {
        if podcastAttemptStates.isEmpty {
            defaults.removeObject(forKey: StorageKey.podcastAttemptStates)
            return
        }
        if let data = try? encoder.encode(podcastAttemptStates) {
            defaults.set(data, forKey: StorageKey.podcastAttemptStates)
        }
    }

    /// 解析 Podcast 进度 recordName → (订阅稳定身份, 源 URL, GUID)。
    /// recordName 形如 `playback-ep-<subscriptionIdentity>-<guid>`，其中 identity 自身含前缀 `podcast-<sha>`。
    static func parsePodcastPlaybackRecordName(
        _ recordName: String
    ) -> (subscriptionIdentity: String, sourceURL: String, episodeGUID: String)? {
        guard recordName.hasPrefix("playback-ep-") else { return nil }
        let body = String(recordName.dropFirst("playback-ep-".count))
        // identity 固定为 `podcast-` + 64 位 sha256 hex。
        guard body.hasPrefix("podcast-"), body.count > "podcast-".count + 64 + 1 else { return nil }
        let identity = String(body.prefix("podcast-".count + 64))
        let guid = String(body.dropFirst("podcast-".count + 64 + 1))
        guard !guid.isEmpty else { return nil }
        // recordName 不含原始 URL；sourceURL 在物化/RSS 阶段由订阅记录解析，这里返回空串占位。
        return (identity, "", guid)
    }

    /// 解析 YouTube 进度 recordName → videoID。
    static func parseYouTubePlaybackRecordName(_ recordName: String) -> String? {
        guard recordName.hasPrefix("playback-yt-") else { return nil }
        let videoID = String(recordName.dropFirst("playback-yt-".count))
        return videoID.isEmpty ? nil : videoID
    }

    /// Number of progress records waiting for local Episode/Video content. Exposed for tests.
    var pendingPlaybackApplicationCount: Int {
        pendingPlaybackApplications.count
    }

    /// 测试辅助：读取指定 recordName 的本地进度状态（含目录快照）。
    func playbackProgressStateForTesting(recordName: String) -> PlaybackProgressState? {
        playbackProgress[recordName]
    }

    private func applyToLocalStore(_ document: SyncDocument) throws {
        switch document.kind {
        case .configuration:
            var values: [AppConfigurationKey: String] = [:]
            for (rawKey, field) in document.fields {
                if let key = AppConfigurationKey(rawValue: rawKey) { values[key] = field.value }
            }
            try settings?.applySyncedValues(values)
        case .podcastSubscription:
            try applyPodcast(document)
        case .youtubeSubscription:
            try applyYouTube(document)
        }
    }

    private func applyPodcast(_ document: SyncDocument) throws {
        guard let modelContext else { return }
        let subscriptions = try modelContext.fetch(FetchDescriptor<PodcastSubscription>())
        let existing = subscriptions.first {
            SyncRecordIdentity.podcast(sourceURL: $0.showURL) == document.recordName
        }
        if document.isDeleted {
            if let existing { modelContext.delete(existing); try modelContext.save() }
            return
        }
        guard let sourceURL = document.fields["sourceURL"]?.value else { return }
        let subscription = existing ?? PodcastSubscription(
            showURL: sourceURL,
            displayName: document.fields["displayName"]?.value ?? sourceURL,
            createdAt: Self.date(document.fields["createdAt"]?.value) ?? Date()
        )
        if existing == nil { modelContext.insert(subscription) }
        subscription.showURL = sourceURL
        subscription.displayName = document.fields["displayName"]?.value ?? subscription.displayName
        subscription.feedURL = Self.nilIfEmpty(document.fields["feedURL"]?.value) ?? subscription.feedURL
        subscription.authorName = Self.nilIfEmpty(document.fields["authorName"]?.value) ?? subscription.authorName
        subscription.summaryText = Self.nilIfEmpty(document.fields["summaryText"]?.value) ?? subscription.summaryText
        subscription.artworkURL = Self.nilIfEmpty(document.fields["artworkURL"]?.value) ?? subscription.artworkURL
        if let rawArtworkSource = Self.nilIfEmpty(document.fields["artworkSource"]?.value),
           let artworkSource = PodcastArtworkSource(rawValue: rawArtworkSource) {
            subscription.artworkSource = artworkSource.rawValue
        }
        subscription.websiteURL = Self.nilIfEmpty(document.fields["websiteURL"]?.value) ?? subscription.websiteURL
        subscription.applePodcastsURL = Self.nilIfEmpty(document.fields["applePodcastsURL"]?.value) ?? subscription.applePodcastsURL
        subscription.isEnabled = document.fields["isEnabled"]?.value != "false"
        subscription.updatedAt = max(subscription.updatedAt, Self.latestVersionDate(in: document) ?? .distantPast)
        try modelContext.save()
    }

    private func applyYouTube(_ document: SyncDocument) throws {
        guard let modelContext else { return }
        let channels = try modelContext.fetch(FetchDescriptor<YTChannelRecord>())
        let existing = channels.first {
            SyncRecordIdentity.youtube(channelID: $0.channelID) == document.recordName
        }
        if document.isDeleted {
            if let existing {
                modelContext.delete(existing)
                try modelContext.save()
            }
            return
        }
        guard let channelID = document.fields["channelID"]?.value,
              let url = document.fields["url"]?.value
        else { return }
        let channel = existing ?? YTChannelRecord(
            id: channelID,
            channelID: channelID,
            url: url,
            displayName: document.fields["displayName"]?.value ?? channelID,
            createdAt: Self.date(document.fields["createdAt"]?.value) ?? Date()
        )
        if existing == nil { modelContext.insert(channel) }
        channel.url = url
        channel.displayName = document.fields["displayName"]?.value ?? channel.displayName
        channel.isEnabled = document.fields["isEnabled"]?.value != "false"
        channel.updatedAt = max(channel.updatedAt, Self.latestVersionDate(in: document) ?? .distantPast)
        try modelContext.save()
    }

    // MARK: CloudKit coding

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        if let entry = artifactStore.entry(recordName: recordID.recordName) {
            return artifactRecord(for: entry, recordID: recordID)
        }
        if let state = playbackProgress[recordID.recordName] {
            return playbackProgressRecord(for: state, recordID: recordID)
        }
        guard let document = documents[recordID.recordName] else { return nil }
        let record = decodedSystemRecord(recordName: recordID.recordName)
            ?? CKRecord(recordType: Self.recordType(for: document.kind), recordID: recordID)
        for (key, field) in document.fields {
            let valueKey = Self.valueField(key)
            if document.kind == .configuration,
               AppConfigurationKey(rawValue: key)?.isSecret == true {
                record.encryptedValues[valueKey] = field.value as NSString
            } else {
                record[valueKey] = field.value as NSString
            }
            record[Self.modifiedAtField(key)] = field.version.modifiedAt as NSDate
            record[Self.deviceIDField(key)] = field.version.deviceID as NSString
        }
        if let deletionVersion = document.deletionVersion {
            record["deletionModifiedAt"] = deletionVersion.modifiedAt as NSDate
            record["deletionDeviceID"] = deletionVersion.deviceID as NSString
        }
        return record
    }

    private func playbackProgressRecord(
        for state: PlaybackProgressState,
        recordID: CKRecord.ID
    ) -> CKRecord {
        let record = decodedSystemRecord(recordName: recordID.recordName)
            ?? CKRecord(recordType: Self.playbackProgressRecordType, recordID: recordID)
        record["positionSeconds"] = state.positionSeconds.map { $0 as NSNumber }
        record["durationSeconds"] = state.durationSeconds.map { $0 as NSNumber }
        record["completedAt"] = state.completedAt.map { $0 as NSDate }
        record["modifiedAt"] = state.version.modifiedAt as NSDate
        record["deviceID"] = state.version.deviceID as NSString
        if let catalog = state.catalog,
           let data = try? encoder.encode(catalog) {
            record["catalogSnapshot"] = data as NSData
        } else {
            record["catalogSnapshot"] = nil
        }
        return record
    }

    private func artifactRecord(
        for entry: SubtitleArtifactLocalEntry,
        recordID: CKRecord.ID
    ) -> CKRecord? {
        let metadata = entry.metadata
        let record = decodedSystemRecord(recordName: recordID.recordName)
            ?? CKRecord(recordType: Self.subtitleArtifactRecordType, recordID: recordID)
        record["contentKind"] = metadata.identity.contentKind.rawValue as NSString
        record["contentKey"] = metadata.identity.contentKey as NSString
        record["targetLanguage"] = metadata.identity.targetLanguage as NSString
        record["schemaVersion"] = SubtitleArtifactIdentity.schemaVersion as NSNumber
        record["modifiedAt"] = metadata.version.modifiedAt as NSDate
        record["deviceID"] = metadata.version.deviceID as NSString
        record["isDeleted"] = metadata.isDeleted as NSNumber
        record["byteCount"] = metadata.byteCount as NSNumber
        if metadata.isDeleted {
            record["sha256"] = nil
            record["payload"] = nil
        } else {
            guard let sha256 = metadata.sha256,
                  let payloadURL = artifactStore.verifiedPayloadURL(for: metadata.identity)
            else { return nil }
            record["sha256"] = sha256 as NSString
            record["payload"] = CKAsset(fileURL: payloadURL)
        }
        return record
    }

    private func fetchArtifactDirectly(
        identity: SubtitleArtifactIdentity
    ) async -> SubtitleArtifactLookupResult? {
        guard let database else {
            return .unavailable(CloudSyncKitL10n.string(
                "cloud.detail.starting",
                fallback: "Checking the account and cloud changes."
            ))
        }
        let recordID = CKRecord.ID(recordName: identity.recordName, zoneID: Self.zoneID)
        do {
            let record = try await database.record(for: recordID)
            mergeFetchedArtifact(record)
            if let envelope = artifactStore.envelope(for: identity) {
                return .ready(envelope)
            }
            if case .failed(let message) = phase {
                return .unavailable(message)
            }
            return .notFound
        } catch let error as CKError where error.code == .unknownItem {
            return .notFound
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func mergeFetchedArtifact(_ record: CKRecord) {
        guard let remote = artifactMetadata(from: record) else {
            phase = .failed(CloudSyncKitL10n.string("cloud.status.failed", fallback: "iCloud Sync Failed"))
            return
        }
        storeSystemFields(for: record)
        let local = artifactStore.entry(for: remote.identity)?.metadata
        if let local,
           SubtitleArtifactConflictPolicy.preferred(local, remote) == local,
           local != remote {
            queueArtifact(local.identity)
            return
        }

        do {
            if remote.isDeleted {
                try artifactStore.installTombstone(remote)
            } else {
                guard let asset = record["payload"] as? CKAsset,
                      let url = asset.fileURL
                else { throw SubtitleArtifactValidationError.invalidPayload }
                let data = try Data(contentsOf: url)
                try artifactStore.install(data: data, metadata: remote)
            }
            subtitleCacheRevision &+= 1
        } catch {
            phase = .failed(CloudSyncKitL10n.format(
                "error.cloud_apply_failed_detail",
                fallback: "Local data could not be applied and will be retried during the next sync.\nDetails: %@",
                error.localizedDescription
            ))
        }
    }

    private func playbackProgressState(from record: CKRecord) -> PlaybackProgressState? {
        guard record.recordType == Self.playbackProgressRecordType,
              let modifiedAt = record["modifiedAt"] as? Date,
              let deviceID = record["deviceID"] as? String
        else { return nil }
        // 旧格式记录没有 catalogSnapshot 字段，解码失败按无快照处理（不阻塞进度）。
        var catalog: PlaybackCatalogSnapshot?
        if let data = record["catalogSnapshot"] as? Data,
           let decoded = try? decoder.decode(PlaybackCatalogSnapshot.self, from: data),
           Self.catalogSnapshotRejection(decoded, forRecordName: record.recordID.recordName) == nil {
            catalog = decoded
        }
        return PlaybackProgressState(
            recordName: record.recordID.recordName,
            positionSeconds: (record["positionSeconds"] as? NSNumber)?.doubleValue,
            durationSeconds: (record["durationSeconds"] as? NSNumber)?.doubleValue,
            completedAt: record["completedAt"] as? Date,
            version: SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID),
            catalog: catalog
        )
    }

    private func artifactMetadata(from record: CKRecord) -> SubtitleArtifactMetadata? {
        guard record.recordType == Self.subtitleArtifactRecordType,
              let rawKind = record["contentKind"] as? String,
              let kind = TranslationContentKind(rawValue: rawKind),
              let contentKey = record["contentKey"] as? String,
              let targetLanguage = record["targetLanguage"] as? String,
              let schemaVersion = record["schemaVersion"] as? NSNumber,
              schemaVersion.intValue == SubtitleArtifactIdentity.schemaVersion,
              let modifiedAt = record["modifiedAt"] as? Date,
              let deviceID = record["deviceID"] as? String,
              let deletedNumber = record["isDeleted"] as? NSNumber,
              let byteCountNumber = record["byteCount"] as? NSNumber
        else { return nil }
        let identity = SubtitleArtifactIdentity(
            contentKind: kind,
            contentKey: contentKey,
            targetLanguage: targetLanguage
        )
        guard identity.recordName == record.recordID.recordName else { return nil }
        let version = SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID)
        if deletedNumber.boolValue {
            return .tombstone(identity: identity, version: version)
        }
        guard let sha256 = record["sha256"] as? String,
              byteCountNumber.int64Value > 0
        else { return nil }
        return SubtitleArtifactMetadata(
            identity: identity,
            version: version,
            sha256: sha256,
            byteCount: byteCountNumber.int64Value
        )
    }

    private func document(from record: CKRecord) -> SyncDocument? {
        guard let kind = Self.kind(forRecordType: record.recordType) else { return nil }
        var fields: [String: SyncFieldValue] = [:]
        for key in Self.fieldKeys(for: kind) {
            let valueKey = Self.valueField(key)
            let value: String?
            if kind == .configuration,
               AppConfigurationKey(rawValue: key)?.isSecret == true {
                value = record.encryptedValues[valueKey] as? String
            } else {
                value = record[valueKey] as? String
            }
            guard let value,
                  let modifiedAt = record[Self.modifiedAtField(key)] as? Date,
                  let deviceID = record[Self.deviceIDField(key)] as? String
            else { continue }
            fields[key] = SyncFieldValue(
                value: value,
                version: .init(modifiedAt: modifiedAt, deviceID: deviceID)
            )
        }
        let deletionVersion: SyncFieldVersion?
        if let modifiedAt = record["deletionModifiedAt"] as? Date,
           let deviceID = record["deletionDeviceID"] as? String {
            deletionVersion = .init(modifiedAt: modifiedAt, deviceID: deviceID)
        } else {
            deletionVersion = nil
        }
        return SyncDocument(
            recordName: record.recordID.recordName,
            kind: kind,
            fields: fields,
            deletionVersion: deletionVersion
        )
    }

    private func storeSystemFields(for record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        systemFields[record.recordID.recordName] = archiver.encodedData
        persistSystemFields()
    }

    private func decodedSystemRecord(recordName: String) -> CKRecord? {
        guard let data = systemFields[recordName],
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    private func persistDocuments() {
        let partition = SyncDocumentPersistencePartition.partition(documents)
        do {
            let ordinaryData = try encoder.encode(partition.ordinary)
            try persistSecure(
                partition.secure,
                account: SecureStorageAccount.configurationDocuments
            )
            defaults.set(ordinaryData, forKey: StorageKey.documents)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func persistSystemFields() {
        if let data = try? encoder.encode(systemFields) { defaults.set(data, forKey: StorageKey.systemFields) }
    }

    private func persistPlaybackProgress() {
        if let data = try? encoder.encode(playbackProgress) {
            defaults.set(data, forKey: StorageKey.playbackProgress)
        }
    }

    private func persistPendingPlaybackApplications() {
        if pendingPlaybackApplications.isEmpty {
            defaults.removeObject(forKey: StorageKey.pendingPlaybackApplications)
            return
        }
        if let data = try? encoder.encode(pendingPlaybackApplications) {
            defaults.set(data, forKey: StorageKey.pendingPlaybackApplications)
        }
    }

    private func persistPendingApplications() {
        let partition = SyncDocumentPersistencePartition.partition(pendingApplications)
        do {
            let ordinaryData = try encoder.encode(partition.ordinary)
            try persistSecure(
                partition.secure,
                account: SecureStorageAccount.pendingConfigurationApplications
            )
            defaults.set(ordinaryData, forKey: StorageKey.pendingApplications)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func persistSecure(_ documents: [String: SyncDocument], account: String) throws {
        if documents.isEmpty {
            try keychain.deleteData(account: account)
        } else {
            try keychain.writeData(encoder.encode(documents), account: account)
        }
    }

    private static func recordType(for kind: SyncDocumentKind) -> String {
        switch kind {
        case .configuration: "LCConfiguration"
        case .podcastSubscription: "LCPodcastSubscription"
        case .youtubeSubscription: "LCYouTubeSubscription"
        }
    }

    private static func kind(forRecordType value: String) -> SyncDocumentKind? {
        switch value {
        case recordType(for: .configuration): .configuration
        case recordType(for: .podcastSubscription): .podcastSubscription
        case recordType(for: .youtubeSubscription): .youtubeSubscription
        default: nil
        }
    }

    private static func fieldKeys(for kind: SyncDocumentKind) -> [String] {
        switch kind {
        case .configuration: AppConfigurationKey.allCases.map(\.rawValue)
        case .podcastSubscription:
            [
                "sourceURL",
                "displayName",
                "feedURL",
                "authorName",
                "summaryText",
                "artworkURL",
                "artworkSource",
                "websiteURL",
                "applePodcastsURL",
                "isEnabled",
                "createdAt"
            ]
        case .youtubeSubscription: ["channelID", "url", "displayName", "isEnabled", "createdAt"]
        }
    }

    private static func valueField(_ key: String) -> String { "value_\(key)" }
    private static func modifiedAtField(_ key: String) -> String { "modifiedAt_\(key)" }
    private static func deviceIDField(_ key: String) -> String { "deviceID_\(key)" }

    private static func latestVersionDate(in document: SyncDocument) -> Date? {
        document.fields.values.map(\.version.modifiedAt).max()
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func isNoAccount(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return error.code == .notAuthenticated || error.code == .accountTemporarilyUnavailable
    }

    private static func saveFailureKind(for error: CKError) -> CloudOperationFailureKind {
        switch error.code {
        case .serverRecordChanged:
            .serverRecordChanged
        case .unknownItem:
            .recordMissing
        case .zoneNotFound, .userDeletedZone:
            .zoneMissing
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .serverResponseLost, .zoneBusy, .accountTemporarilyUnavailable, .operationCancelled:
            .transient
        default:
            .terminal
        }
    }
}

/// Shared playback fields on EpisodeRecord / YTVideoRecord for remote progress writeback.
private protocol PlaybackProgressWritable: AnyObject {
    var playbackPositionSeconds: Double? { get set }
    var playbackDurationSeconds: Double? { get set }
    var playbackCompletedAt: Date? { get set }
    var playbackUpdatedAt: Date? { get set }
}

extension EpisodeRecord: PlaybackProgressWritable {}
extension YTVideoRecord: PlaybackProgressWritable {}
