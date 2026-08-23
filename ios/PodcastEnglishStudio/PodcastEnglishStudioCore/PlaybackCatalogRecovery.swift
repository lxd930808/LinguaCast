import Foundation

// MARK: - 播放目录快照（跨设备“继续播放”恢复）
//
// 设计目标（见 .cursor/plans/跨设备“继续播放”目录恢复开发计划.md）：
// 新设备无需联网即可从一条 LCPlaybackProgress 记录恢复出可播放的“继续播放”条目。
// 快照是可选的、自包含的精简元数据，与播放进度共用一条 CloudKit 记录但**独立 LWW**。
//
// 关键约束：
// - 只同步可播放所需的最小元数据；绝不同步本地路径、pipeline 状态、字幕行或翻译记录。
// - 旧客户端写入不带快照的新进度时，不得清除已有快照（快照与进度分别比较版本）。
// - 快照身份必须能从 record name 复算并一致，否则只丢弃快照、保留合法进度。

/// 一条可播放内容的精简目录快照。
public struct PlaybackCatalogSnapshot: Codable, Hashable, Sendable {
    /// 当前快照结构版本。未来字段演进时递增，旧客户端按缺失字段解码。
    public static let currentSchemaVersion = 1

    public enum Content: Codable, Hashable, Sendable {
        case podcast(Podcast)
        case youtube(YouTube)

        public struct Podcast: Codable, Hashable, Sendable {
            /// 归一化前的订阅 source URL（用于重建稳定身份与匹配本地订阅）。
            public var sourceURL: String
            public var episodeGUID: String
            public var episodeTitle: String
            public var showTitle: String
            public var showArtist: String
            public var enclosureURL: String
            public var publishedAt: Date?

            public init(
                sourceURL: String,
                episodeGUID: String,
                episodeTitle: String,
                showTitle: String,
                showArtist: String = "",
                enclosureURL: String,
                publishedAt: Date? = nil
            ) {
                self.sourceURL = sourceURL
                self.episodeGUID = episodeGUID
                self.episodeTitle = episodeTitle
                self.showTitle = showTitle
                self.showArtist = showArtist
                self.enclosureURL = enclosureURL
                self.publishedAt = publishedAt
            }
        }

        public struct YouTube: Codable, Hashable, Sendable {
            public var videoID: String
            public var channelID: String
            public var title: String
            public var playbackURL: String
            public var thumbnailURL: String?
            public var publishedAt: Date?

            public init(
                videoID: String,
                channelID: String,
                title: String,
                playbackURL: String,
                thumbnailURL: String? = nil,
                publishedAt: Date? = nil
            ) {
                self.videoID = videoID
                self.channelID = channelID
                self.title = title
                self.playbackURL = playbackURL
                self.thumbnailURL = thumbnailURL
                self.publishedAt = publishedAt
            }
        }
    }

    public var schemaVersion: Int
    public var content: Content
    /// 快照自身的 LWW 版本，独立于播放进度版本。
    public var modifiedAt: Date
    public var deviceID: String

    public init(
        schemaVersion: Int = PlaybackCatalogSnapshot.currentSchemaVersion,
        content: Content,
        modifiedAt: Date,
        deviceID: String
    ) {
        self.schemaVersion = schemaVersion
        self.content = content
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }

    public var version: SyncFieldVersion {
        SyncFieldVersion(modifiedAt: modifiedAt, deviceID: deviceID)
    }
}

/// 快照完整性 / 身份校验的判定结果。
public enum PlaybackCatalogSnapshotRejection: Equatable, Sendable {
    /// 快照身份与 record name 复算结果不一致。
    case identityMismatch
    /// 快照缺少恢复出可播放条目所必需的字段。
    case incomplete
    /// 快照 schema 版本高于本客户端能理解的版本。
    case unsupportedSchema(found: Int, supported: Int)
}

public enum PlaybackCatalogSnapshotPolicy {
    /// 判断快照内容是否具备恢复出“可播放条目”的最小字段。
    ///
    /// - Podcast 必须：GUID 非空、标题非空、enclosure URL 可解析为 http(s)。
    /// - YouTube 必须：video ID 非空、标题非空、播放 URL 可解析。
    /// 订阅/频道是否有效由恢复流程另行校验，这里只看快照自包含的内容完整性。
    public static func completenessRejection(
        _ snapshot: PlaybackCatalogSnapshot
    ) -> PlaybackCatalogSnapshotRejection? {
        guard snapshot.schemaVersion <= PlaybackCatalogSnapshot.currentSchemaVersion else {
            return .unsupportedSchema(
                found: snapshot.schemaVersion,
                supported: PlaybackCatalogSnapshot.currentSchemaVersion
            )
        }
        switch snapshot.content {
        case .podcast(let podcast):
            guard !podcast.episodeGUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !podcast.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isPlayableRemoteURL(podcast.enclosureURL)
            else { return .incomplete }
            return nil
        case .youtube(let youtube):
            guard !youtube.videoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !youtube.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isPlayableRemoteURL(youtube.playbackURL)
            else { return .incomplete }
            return nil
        }
    }

    /// 仅 http(s) 的远程 URL 才可播放（排除本地路径、空串、相对路径）。
    private static func isPlayableRemoteURL(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return false }
        return true
    }
}

// MARK: - 恢复候选筛选

/// 播放目录恢复的筛选输入。与 CloudSyncKit 解耦的纯值类型，便于在 Core 层单测。
public struct PlaybackRecoveryCandidateInput: Equatable, Sendable {
    public var recordName: String
    public var positionSeconds: Double?
    public var durationSeconds: Double?
    public var completedAt: Date?
    public var progressModifiedAt: Date
    /// 对应订阅/频道在本机是否处于启用状态（未知视为启用，由调用方提供准确值）。
    public var isSourceEnabled: Bool
    /// 对应订阅/频道是否已被删除（tombstone）。
    public var isSourceDeleted: Bool

    public init(
        recordName: String,
        positionSeconds: Double?,
        durationSeconds: Double?,
        completedAt: Date?,
        progressModifiedAt: Date,
        isSourceEnabled: Bool = true,
        isSourceDeleted: Bool = false
    ) {
        self.recordName = recordName
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.completedAt = completedAt
        self.progressModifiedAt = progressModifiedAt
        self.isSourceEnabled = isSourceEnabled
        self.isSourceDeleted = isSourceDeleted
    }
}

public enum PlaybackRecoveryCandidatePolicy {
    /// 自动恢复只覆盖最近 30 天内更新过的进行中记录。
    public static let recencyWindow: TimeInterval = 30 * 24 * 60 * 60
    /// 一次最多恢复的记录数。
    public static let maximumRestoredCount = 20

    /// 从进度记录中筛选“继续播放”恢复候选。
    ///
    /// 规则（计划 §2）：
    /// - `PlaybackListPolicy == .inProgress`（复用统一播放分类，排除已完成与未播放）。
    /// - 进度更新时间在最近 30 天内（以注入时钟 `now` 判定）。
    /// - 排除禁用订阅与已删除订阅。
    /// - 按更新时间倒序，最多取 `maximumRestoredCount` 条。
    public static func selectCandidates(
        _ inputs: [PlaybackRecoveryCandidateInput],
        now: Date,
        recencyWindow: TimeInterval = PlaybackRecoveryCandidatePolicy.recencyWindow,
        maximumCount: Int = PlaybackRecoveryCandidatePolicy.maximumRestoredCount
    ) -> [PlaybackRecoveryCandidateInput] {
        let cutoff = now.addingTimeInterval(-recencyWindow)
        let eligible = inputs.filter { input in
            guard !input.isSourceDeleted, input.isSourceEnabled else { return false }
            guard input.progressModifiedAt >= cutoff else { return false }
            let category = PlaybackListPolicy.category(
                playbackPosition: input.positionSeconds,
                duration: input.durationSeconds,
                completedAt: input.completedAt
            )
            return category == .inProgress
        }
        return eligible
            .sorted { lhs, rhs in
                if lhs.progressModifiedAt != rhs.progressModifiedAt {
                    return lhs.progressModifiedAt > rhs.progressModifiedAt
                }
                return lhs.recordName < rhs.recordName
            }
            .prefix(maximumCount)
            .map { $0 }
    }
}

// MARK: - Podcast 定向补全的退避与未命中策略

public enum PodcastCatalogMissPolicy {
    /// 同一恢复任务内一个订阅只请求一次；失败按 15 分钟 / 1 小时 / 最长 6 小时退避。
    public static let backoffSchedule: [TimeInterval] = [15 * 60, 60 * 60, 6 * 60 * 60]

    /// 根据已连续失败次数返回下一次允许重试的间隔（超出档位后固定在最长档）。
    public static func backoffInterval(consecutiveFailures: Int) -> TimeInterval {
        let index = max(0, min(consecutiveFailures - 1, backoffSchedule.count - 1))
        return backoffSchedule[index]
    }

    /// 判断某订阅在给定失败计数与上次尝试时间下，此刻是否允许再次发起 RSS 请求。
    public static func mayAttempt(
        consecutiveFailures: Int,
        lastAttemptAt: Date?,
        now: Date
    ) -> Bool {
        guard consecutiveFailures > 0, let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= backoffInterval(consecutiveFailures: consecutiveFailures)
    }
}

/// “确定未命中”标记：RSS 成功解析但目标 GUID 不存在时持久化，停止后续自动重试。
public struct PodcastCatalogDefinitiveMiss: Codable, Hashable, Sendable {
    /// 订阅稳定身份（SyncRecordIdentity.podcast 的输出），用于跨设备/跨重启对齐。
    public var subscriptionIdentity: String
    public var episodeGUID: String
    public var recordedAt: Date

    public init(subscriptionIdentity: String, episodeGUID: String, recordedAt: Date) {
        self.subscriptionIdentity = subscriptionIdentity
        self.episodeGUID = episodeGUID
        self.recordedAt = recordedAt
    }

    public var key: String { "\(subscriptionIdentity)\n\(episodeGUID)" }
}
