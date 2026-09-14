import Foundation

// WP12 — 远程播客音频播放源。
// PlayerKit 不依赖任何网络 client / CloudSyncKit：远程 URL 的获取与刷新
// 全部通过 app 注入的闭包完成（见 AudioPlaybackSourceResolver 与
// AudioPlaybackController.onSourceRefreshRequired）。签名 URL 只存在于内存，
// 永不持久化。

/// 音频播放来源：本地文件或带过期时间的远程（签名）URL。
public enum AudioPlaybackSource: Equatable, Sendable {
    case localFile(URL)
    case remote(URL, expiresAt: Date)

    public var url: URL {
        switch self {
        case .localFile(let url): return url
        case .remote(let url, _): return url
        }
    }

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// 远程播放源校验策略：仅允许 HTTPS，并可按 host 白名单收敛。
/// allowedHosts 为 nil 时允许任意 HTTPS host（默认）；否则按小写 host 精确匹配。
public struct RemoteAudioHostPolicy: Sendable, Equatable {
    public var allowedHosts: Set<String>?

    public init(allowedHosts: Set<String>? = nil) {
        self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
    }

    /// 默认策略：接受任意 HTTPS host。
    public static let anySecureHost = RemoteAudioHostPolicy()

    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return false }
        guard let allowedHosts else { return true }
        return allowedHosts.contains(host)
    }
}

/// 远程 item 失败的错误分类，供 PlayerKit 与 app 层区分“离线”与“鉴权/传输”失败。
/// 只读 NSError 链，不发起任何网络请求。
public enum AudioPlaybackFailureClassifier {
    /// 离线/不可达类错误（无网络、连接丢失、DNS 失败等）。
    public static func isOffline(_ error: Error?) -> Bool {
        containsURLCode(
            in: error,
            codes: [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorTimedOut
            ]
        )
    }

    /// 鉴权类失败（对应 HTTP 401/403 的常见映射）。
    public static func isAuthorizationFailure(_ error: Error?) -> Bool {
        containsURLCode(
            in: error,
            codes: [
                NSURLErrorUserAuthenticationRequired,
                NSURLErrorUserCancelledAuthentication,
                NSURLErrorNoPermissionsToReadFile
            ]
        )
    }

    private static func containsURLCode(in error: Error?, codes: [Int]) -> Bool {
        var current = error as NSError?
        while let nsError = current {
            if nsError.domain == NSURLErrorDomain, codes.contains(nsError.code) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// 播放来源解析：本地可用文件优先；否则调用 app 注入的 provider 获取
/// 新鲜远程（签名）source。PlayerKit 自身不做任何网络请求。
/// 解析失败（如离线且无本地副本）抛出 ResolutionError，由 app 映射为
/// 播放错误；本类型不触碰任何字幕生成状态，也不持久化签名 URL。
public struct AudioPlaybackSourceResolver: Sendable {
    public enum ResolutionError: Error, Equatable, LocalizedError {
        case noPlayableSource(underlying: String)

        public var errorDescription: String? {
            switch self {
            case .noPlayableSource(let underlying): return underlying
            }
        }
    }

    private let remoteSourceProvider: @Sendable () async throws -> AudioPlaybackSource

    public init(remoteSourceProvider: @escaping @Sendable () async throws -> AudioPlaybackSource) {
        self.remoteSourceProvider = remoteSourceProvider
    }

    /// 本地文件存在且非空时直接返回 .localFile；否则请求远程 source。
    public func resolve(preferredLocalFile: URL?) async throws -> AudioPlaybackSource {
        if let url = preferredLocalFile, Self.isUsableLocalFile(url) {
            return .localFile(url)
        }
        do {
            return try await remoteSourceProvider()
        } catch {
            throw ResolutionError.noPlayableSource(underlying: error.localizedDescription)
        }
    }

    static func isUsableLocalFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.fileSystemPath) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
    }
}
