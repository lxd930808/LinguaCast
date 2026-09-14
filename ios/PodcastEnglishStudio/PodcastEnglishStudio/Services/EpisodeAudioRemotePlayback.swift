import CloudSyncKit
import Foundation
import PlayerKit

// WP12 app 侧胶水：把 CloudSyncKit 的签名 URL 获取接到 PlayerKit 的远程播放缝上。
// PlayerKit 本身不依赖 CloudSyncKit；签名 URL 仅存在于内存，永不持久化；
// 本文件不触碰任何字幕生成状态（WP14 负责在 ViewModel 中接线）。
enum EpisodeAudioRemotePlayback {

    /// 为云端 job 构造 PlayerKit 播放源解析器：本地可用文件优先，
    /// 否则通过 content gateway 拉取新的签名播放 URL。
    static func makeSourceResolver(
        client: CloudContentJobClient,
        jobID: String
    ) -> AudioPlaybackSourceResolver {
        AudioPlaybackSourceResolver {
            let response = try await client.fetchAudioPlaybackURL(jobID: jobID)
            return .remote(response.url, expiresAt: response.expiresAt)
        }
    }

    /// 远程 host 白名单策略。传 nil 表示接受任意 HTTPS host
    /// （签名 URL 的 host 由服务端决定）；传入具体集合则收敛到白名单。
    static func makeHostPolicy(
        allowedSignedURLHosts: Set<String>? = nil
    ) -> RemoteAudioHostPolicy {
        RemoteAudioHostPolicy(allowedHosts: allowedSignedURLHosts)
    }

    /// 接线刷新回调：远程 item 401/403/失败时重新拉取签名 URL 并调用
    /// replaceSourcePreservingPosition 恢复位置；刷新失败保持最后位置，
    /// 仅通过 onRefreshFailure 上报（由 app 映射为播放错误）。
    @MainActor
    static func installSourceRefreshHandling(
        on controller: AudioPlaybackController,
        resolver: AudioPlaybackSourceResolver,
        onRefreshFailure: (@MainActor (Error) -> Void)? = nil
    ) {
        controller.onSourceRefreshRequired = { _ in
            Task { @MainActor in
                do {
                    let fresh = try await resolver.resolve(preferredLocalFile: nil)
                    controller.replaceSourcePreservingPosition(fresh)
                } catch {
                    onRefreshFailure?(error)
                }
            }
        }
    }
}
