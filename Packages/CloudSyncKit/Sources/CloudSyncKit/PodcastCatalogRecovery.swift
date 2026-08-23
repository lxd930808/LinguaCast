import Foundation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels

/// Podcast RSS 拉取抽象（计划 §4 定向补全）。由 app 层注入真实实现，
/// 测试注入假实现。返回原始 feed 数据；解析在 CloudSyncKit 内用 PodcastFeedParser 完成。
public protocol PodcastFeedDataFetching: Sendable {
    /// 拉取订阅 source URL 对应的 RSS 原始数据。
    /// 实现需自行处理 Apple Podcasts 链接 → feedURL 的解析与重试。
    func fetchFeedData(sourceURL: String) async throws -> Data
}

/// Podcast 定向补全的一次调用结果（供测试与失败提示）。
public struct PodcastCatalogRecoveryResult: Sendable {
    /// 本机插入的 Episode 数。
    public var insertedEpisodes: Int
    /// 命中并重新应用进度的 recordName 数。
    public var reappliedProgress: Int
    /// 本次新记录的确定未命中（订阅身份 + GUID）。
    public var definitiveMisses: [PodcastCatalogDefinitiveMiss]
    /// 因退避窗口被跳过、未发起请求的订阅身份。
    public var backoffSkipped: [String]

    public init(
        insertedEpisodes: Int,
        reappliedProgress: Int,
        definitiveMisses: [PodcastCatalogDefinitiveMiss],
        backoffSkipped: [String]
    ) {
        self.insertedEpisodes = insertedEpisodes
        self.reappliedProgress = reappliedProgress
        self.definitiveMisses = definitiveMisses
        self.backoffSkipped = backoffSkipped
    }
}

public enum PodcastCatalogRecoveryError: LocalizedError, Equatable, Sendable {
    case noFetcher

    public var errorDescription: String? {
        switch self {
        case .noFetcher: "Podcast feed fetcher is not configured."
        }
    }
}

@MainActor
extension CloudSyncCoordinator {

    // MARK: - Podcast 定向 RSS 补全（计划 §4）

    /// 对没有完整快照的 Podcast 记录做定向 RSS 补全。
    ///
    /// - 同一恢复任务内一个订阅只请求一次（由 `targets` 已按订阅分组保证，此处再防御去重）。
    /// - 同一 RSS 处理多个目标 GUID，命中与未命中分别记录。
    /// - 命中 → 插入 Episode 并立即重放 deferred progress。
    /// - RSS 成功解析但 GUID 不存在 → 持久化“确定未命中”，停止后续自动重试。
    /// - RSS 失败/超时/5xx → 记录失败并按 15 分钟 / 1 小时 / 6 小时退避（不误判为确定未命中）。
    /// - 已被持久化的确定未命中自动跳过；手动刷新经 `bypassMisses` 重新尝试。
    @discardableResult
    func recoverPodcastCatalog(
        targets: [PodcastCatalogRecoveryRequest],
        context: ModelContext,
        bypassMisses: Bool
    ) async -> PodcastCatalogRecoveryResult {
        guard let fetcher = podcastFeedFetcher else {
            return PodcastCatalogRecoveryResult(insertedEpisodes: 0, reappliedProgress: 0, definitiveMisses: [], backoffSkipped: [])
        }

        var inserted = 0
        var reapplied = 0
        var newMisses: [PodcastCatalogDefinitiveMiss] = []
        var backoffSkipped: [String] = []
        var requestedThisPass: Set<String> = []

        for target in targets {
            let identity = target.subscriptionIdentity
            // 同一恢复任务内，一个订阅最多请求一次。
            guard requestedThisPass.insert(identity).inserted else { continue }

            // 过滤掉已确定未命中的 GUID（手动刷新可绕过）。
            let pendingGUIDs = target.episodeGUIDs.filter { guid in
                bypassMisses || !isDefinitiveMiss(subscriptionIdentity: identity, episodeGUID: guid)
            }
            guard !pendingGUIDs.isEmpty else { continue }

            // 退避窗口：未到时跳过该订阅。
            let attempt = podcastAttemptState(for: identity)
            guard PodcastCatalogMissPolicy.mayAttempt(
                consecutiveFailures: attempt.consecutiveFailures,
                lastAttemptAt: attempt.lastAttemptAt,
                now: nowProvider()
            ) else {
                backoffSkipped.append(identity)
                continue
            }

            guard let sourceURL = resolvedPodcastSourceURL(for: identity, context: context) else {
                continue
            }

            do {
                let data = try await fetcher.fetchFeedData(sourceURL: sourceURL)
                let feed = try PodcastFeedParser().parse(data: data)
                let byGUID = Dictionary(grouping: feed.episodes, by: {
                    $0.guid.trimmingCharacters(in: .whitespacesAndNewlines)
                })

                var hitAny = false
                for guid in pendingGUIDs {
                    let key = guid.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let info = byGUID[key]?.first {
                        if insertPodcastEpisode(from: info, subscriptionIdentity: identity, context: context) {
                            inserted += 1
                        }
                        // 命中后清除该 GUID 可能存在的未命中标记（计划 §4：恢复后清除）。
                        clearDefinitiveMiss(subscriptionIdentity: identity, episodeGUID: guid)
                        hitAny = true
                    } else {
                        // RSS 成功解析但目标 GUID 不存在 → 确定未命中。
                        let miss = PodcastCatalogDefinitiveMiss(
                            subscriptionIdentity: identity,
                            episodeGUID: guid,
                            recordedAt: nowProvider()
                        )
                        recordDefinitiveMiss(miss)
                        newMisses.append(miss)
                    }
                }
                // 本订阅请求成功 → 重置退避。
                resetPodcastAttemptState(for: identity)
                if hitAny {
                    reapplied += reapplyPendingProgress(forSubscriptionIdentity: identity, context: context)
                }
            } catch {
                // 临时网络/服务器错误 → 退避，不标记确定未命中。
                recordPodcastAttemptFailure(for: identity, now: nowProvider())
            }
        }

        return PodcastCatalogRecoveryResult(
            insertedEpisodes: inserted,
            reappliedProgress: reapplied,
            definitiveMisses: newMisses,
            backoffSkipped: backoffSkipped
        )
    }

    /// 将 RSS 中匹配到的 Episode 插入本地（复用 queued/discover 默认状态）。
    /// 已存在同 GUID 记录时不重复插入。返回是否新插入。
    private func insertPodcastEpisode(
        from info: PodcastEpisodeInfo,
        subscriptionIdentity: String,
        context: ModelContext
    ) -> Bool {
        let subscriptions = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
        guard let subscription = subscriptions.first(where: {
            SyncRecordIdentity.podcast(sourceURL: $0.showURL) == subscriptionIdentity
        }) else { return false }

        let episodes = (try? context.fetch(FetchDescriptor<EpisodeRecord>())) ?? []
        let guid = info.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if episodes.contains(where: {
            $0.subscriptionID == subscription.id &&
                $0.episodeGUID.trimmingCharacters(in: .whitespacesAndNewlines) == guid
        }) { return false }

        let episode = EpisodeRecord(
            id: UUID().uuidString,
            subscriptionID: subscription.id,
            showTitle: subscription.displayName,
            showArtist: "",
            episodeTitle: info.title,
            episodeGUID: info.guid,
            publishedAt: info.publishedAt,
            enclosureURL: info.enclosureURL.absoluteString,
            artworkURL: info.artworkURL?.absoluteString,
            summaryText: info.summary,
            mediaDurationSeconds: info.durationSeconds,
            seasonNumber: info.seasonNumber,
            episodeNumber: info.episodeNumber,
            episodeWebsiteURL: info.link?.absoluteString,
            status: "queued",
            pipelineStep: "discover",
            isNew: false
        )
        context.insert(episode)
        return (try? context.save()) != nil
    }

    /// 命中后重放该订阅下所有仍 deferred 的进度。返回成功应用的条数。
    private func reapplyPendingProgress(forSubscriptionIdentity identity: String, context: ModelContext) -> Int {
        var count = 0
        for (recordName, state) in pendingPlaybackApplicationsSnapshot()
        where Self.parsePodcastPlaybackRecordName(recordName)?.subscriptionIdentity == identity {
            if (try? applyPlaybackProgressToLocalStore(state)) == true {
                removePendingPlaybackApplication(recordName: recordName)
                count += 1
            }
        }
        return count
    }
}
