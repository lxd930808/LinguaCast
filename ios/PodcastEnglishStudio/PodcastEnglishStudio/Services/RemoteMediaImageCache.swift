import Foundation
import Kingfisher
import UIKit

/// Configures the shared Kingfisher cache used by `RemoteMediaImage` and artwork prefetch.
enum RemoteMediaImageCache {
    static let memoryLimitBytes = 32 * 1024 * 1024
    static let diskLimitBytes = 150 * 1024 * 1024
    static let diskExpirationDays = 30

    /// Call once at app launch. UI tests use an isolated memory-only cache so historical
    /// disk entries cannot affect screenshots or network-blocked scenarios.
    static func configure(forUITesting: Bool) {
        let cache: ImageCache
        if forUITesting {
            cache = ImageCache(name: "LinguaCast.RemoteMedia.UITest")
            cache.memoryStorage.config.totalCostLimit = memoryLimitBytes
            cache.diskStorage.config.sizeLimit = 0
            cache.diskStorage.config.expiration = .expired
            cache.clearDiskCache()
        } else {
            cache = ImageCache.default
            cache.memoryStorage.config.totalCostLimit = memoryLimitBytes
            cache.diskStorage.config.sizeLimit = UInt(diskLimitBytes)
            cache.diskStorage.config.expiration = .days(diskExpirationDays)
        }
        KingfisherManager.shared.cache = cache
    }

    static var shared: ImageCache {
        KingfisherManager.shared.cache
    }
}
