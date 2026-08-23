import Foundation
import Observation
import SwiftData
import PodcastEnglishStudioCore
import DomainModels

/// “同步并恢复”编排（计划 §6 生命周期编排）。
///
/// 对外只暴露一次 `synchronizeAndRecover` 操作：
/// 1. 等待 CKSyncEngine 启动及同步结束（`syncNow`）。
/// 2. 用精简快照物化可恢复的“继续播放”条目。
/// 3. 对缺快照的记录做定向网络补全（Podcast RSS / YouTube videos.list）。
/// 4. 再次应用 deferred progress。
///
/// 重复触发复用同一个进行中的任务（任务去重）；手动下拉可绕过错误退避，
/// 但不能绕过 30 天与 20 条限制（这两者在 `recoverPendingPlaybackCatalog` 内强制）。
@MainActor
@Observable
public final class PlaybackCatalogRecoveryCoordinator {
    public enum Trigger: Sendable {
        /// App 首次启动完成 / 回到前台：自动路径，尊重退避与确定未命中。
        case automatic
        /// 用户手动下拉刷新：可绕过确定未命中与退避，但仍受 30 天 / 20 条限制。
        case manualRefresh
    }

    /// 目录恢复自身的成败，与 CloudKit 同步状态分离记录（计划：失败分离）。
    public enum RecoveryError: LocalizedError, Sendable {
        case syncUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .syncUnavailable(let message): message
            }
        }
    }

    public struct Outcome: Sendable {
        public var syncPhase: CloudSyncPhase
        public var materializedFromSnapshot: Int
        public var podcastRecovered: Int
        public var youTubeRecovered: Int
        /// 目录恢复阶段是否发生过错误（不影响已成功的云同步状态）。
        public var recoveryError: String?

        public init(
            syncPhase: CloudSyncPhase,
            materializedFromSnapshot: Int,
            podcastRecovered: Int,
            youTubeRecovered: Int,
            recoveryError: String?
        ) {
            self.syncPhase = syncPhase
            self.materializedFromSnapshot = materializedFromSnapshot
            self.podcastRecovered = podcastRecovered
            self.youTubeRecovered = youTubeRecovered
            self.recoveryError = recoveryError
        }
    }

    private let cloudSync: CloudSyncCoordinator
    @ObservationIgnored private let contextProvider: @MainActor () -> ModelContext?
    @ObservationIgnored private var inFlightTask: Task<Outcome, Never>?

    public init(
        cloudSync: CloudSyncCoordinator,
        contextProvider: @escaping @MainActor () -> ModelContext?
    ) {
        self.cloudSync = cloudSync
        self.contextProvider = contextProvider
    }

    /// 是否已有进行中的恢复任务（供 UI 判断与测试）。
    public var isRecovering: Bool { inFlightTask != nil }

    /// 同步并恢复“继续播放”目录。重复触发复用同一进行中任务。
    @discardableResult
    public func synchronizeAndRecover(trigger: Trigger = .automatic) async -> Outcome {
        if let inFlightTask {
            return await inFlightTask.value
        }
        let task = Task<Outcome, Never> { [weak self] in
            guard let self else {
                return Outcome(
                    syncPhase: .failed("coordinator deallocated"),
                    materializedFromSnapshot: 0,
                    podcastRecovered: 0,
                    youTubeRecovered: 0,
                    recoveryError: nil
                )
            }
            return await self.performRecovery(trigger: trigger)
        }
        inFlightTask = task
        let outcome = await task.value
        inFlightTask = nil
        return outcome
    }

    private func performRecovery(trigger: Trigger) async -> Outcome {
        guard let context = contextProvider() else {
            return Outcome(
                syncPhase: cloudSync.phase,
                materializedFromSnapshot: 0,
                podcastRecovered: 0,
                youTubeRecovered: 0,
                recoveryError: RecoveryError.syncUnavailable("local store unavailable").errorDescription
            )
        }

        // 1. 等待同步结束。云同步失败不阻断目录恢复（失败分离）。
        let syncPhase = await cloudSync.syncNow()

        // 2. 用精简快照物化 + 收集需联网的目标。
        let outcome = cloudSync.recoverPendingPlaybackCatalog(context: context)

        // 3. 定向网络补全。
        var podcastRecovered = 0
        var youTubeRecovered = 0
        let bypassMisses = trigger == .manualRefresh

        let podcastRequests = outcome.networkTargets.compactMap { target -> CloudSyncCoordinator.PodcastCatalogRecoveryRequest? in
            guard case .podcast(let identity, _, let guids) = target else { return nil }
            return CloudSyncCoordinator.PodcastCatalogRecoveryRequest(
                subscriptionIdentity: identity,
                episodeGUIDs: guids
            )
        }
        if !podcastRequests.isEmpty {
            let result = await cloudSync.recoverPodcastCatalog(
                targets: podcastRequests,
                context: context,
                bypassMisses: bypassMisses
            )
            podcastRecovered = result.insertedEpisodes
        }

        let youTubeVideoIDs = outcome.networkTargets.reduce(into: Set<String>()) { acc, target in
            if case .youtube(let ids) = target { acc.formUnion(ids) }
        }
        if !youTubeVideoIDs.isEmpty {
            let result = await cloudSync.recoverYouTubeCatalog(videoIDs: youTubeVideoIDs, context: context)
            youTubeRecovered = result.insertedVideos
        }

        // 4. 再次应用 deferred progress（快照物化与网络补全后可能仍有遗漏）。
        try? cloudSync.retryPendingPlaybackApplications()

        return Outcome(
            syncPhase: syncPhase,
            materializedFromSnapshot: outcome.materializedFromSnapshot,
            podcastRecovered: podcastRecovered,
            youTubeRecovered: youTubeRecovered,
            recoveryError: nil
        )
    }
}
