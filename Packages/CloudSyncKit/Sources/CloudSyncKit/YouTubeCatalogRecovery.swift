import Foundation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels

/// YouTube 视频详情拉取抽象（计划 §5 定向补全）。由 app 层注入真实实现（包装
/// YouTube Data API `videos.list`），测试注入假实现。
public protocol YouTubeVideoDetailsFetching: Sendable {
    /// 按 video ID 批量拉取视频详情。实现内部应合并为一次 `videos.list` 请求。
    /// 返回以 video ID 为键的详情；缺失/已删除/不可用的 ID 不在结果中。
    func fetchVideoDetails(videoIDs: Set<String>) async throws -> [String: YouTubeVideoDetails]
}

/// 一条 YouTube 视频的精简详情（仅恢复“继续播放”所需）。
public struct YouTubeVideoDetails: Equatable, Sendable {
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

/// YouTube 定向补全的一次调用结果。
public struct YouTubeCatalogRecoveryResult: Sendable {
    /// 本机插入的 Video 数。
    public var insertedVideos: Int
    /// 命中并重新应用进度的 recordName 数。
    public var reappliedProgress: Int
    /// 因频道未订阅/未启用/不匹配而跳过、未创建占位记录的 video ID。
    public var skippedVideoIDs: Set<String>

    public init(insertedVideos: Int, reappliedProgress: Int, skippedVideoIDs: Set<String>) {
        self.insertedVideos = insertedVideos
        self.reappliedProgress = reappliedProgress
        self.skippedVideoIDs = skippedVideoIDs
    }
}

@MainActor
extension CloudSyncCoordinator {

    // MARK: - YouTube 定向补全（计划 §5）

    /// 对旧版 YouTube 进度做定向补全。
    ///
    /// - 缺失的 video ID 合并为一次 `videos.list`（由 fetcher 实现保证）。
    /// - 不刷新频道目录、不扫描 uploads playlist。
    /// - 返回结果必须属于本机已同步且启用的频道，否则不创建占位记录。
    /// - 视频插入后立即重放 deferred progress。
    /// - API key 缺失 / 配额不足 / 视频删除 / 频道不匹配时不创建占位记录（由 fetcher 抛出或省略结果表示）。
    @discardableResult
    func recoverYouTubeCatalog(
        videoIDs: Set<String>,
        context: ModelContext
    ) async -> YouTubeCatalogRecoveryResult {
        guard let fetcher = youTubeVideoDetailsFetcher, !videoIDs.isEmpty else {
            return YouTubeCatalogRecoveryResult(insertedVideos: 0, reappliedProgress: 0, skippedVideoIDs: [])
        }

        let channels = (try? context.fetch(FetchDescriptor<YTChannelRecord>())) ?? []
        let enabledChannelByID = Dictionary(
            channels.filter(\.isEnabled).map { ($0.channelID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let details: [String: YouTubeVideoDetails]
        do {
            details = try await fetcher.fetchVideoDetails(videoIDs: videoIDs)
        } catch {
            // 拉取失败（含配额/网络）：不创建任何记录，全部留待下次。
            return YouTubeCatalogRecoveryResult(insertedVideos: 0, reappliedProgress: 0, skippedVideoIDs: [])
        }

        var inserted = 0
        var skipped: Set<String> = []
        var insertedVideoIDs: Set<String> = []
        let existingVideos = (try? context.fetch(FetchDescriptor<YTVideoRecord>())) ?? []
        let existingIDs = Set(existingVideos.map(\.id))

        for videoID in videoIDs {
            guard let detail = details[videoID] else {
                // 视频删除 / 不可用 → 跳过。
                skipped.insert(videoID)
                continue
            }
            // 频道必须本机已订阅且启用，否则拒绝（不创建占位记录）。
            guard let channel = enabledChannelByID[detail.channelID] else {
                skipped.insert(videoID)
                continue
            }
            guard !existingIDs.contains(videoID) else { continue }
            let video = YTVideoRecord(
                id: detail.videoID,
                channelRecordID: channel.id,
                channelID: detail.channelID,
                title: detail.title,
                publishedAt: detail.publishedAt,
                url: detail.playbackURL,
                thumbnail: detail.thumbnailURL
            )
            context.insert(video)
            insertedVideoIDs.insert(videoID)
            inserted += 1
        }
        if inserted > 0 {
            try? context.save()
        }

        // 命中后立即重放这些 video 的 deferred progress。
        var reapplied = 0
        for videoID in insertedVideoIDs {
            let recordName = Self.playbackProgressRecordName(for: .youtubeVideo(videoID: videoID))
            if let state = pendingPlaybackApplicationsSnapshot()[recordName],
               (try? applyPlaybackProgressToLocalStore(state)) == true {
                removePendingPlaybackApplication(recordName: recordName)
                reapplied += 1
            }
        }

        return YouTubeCatalogRecoveryResult(
            insertedVideos: inserted,
            reappliedProgress: reapplied,
            skippedVideoIDs: skipped
        )
    }
}
