import Foundation
import DomainModels

@MainActor
final class PlaybackDeepLinkCoordinator {
    static let shared = PlaybackDeepLinkCoordinator()

    private(set) var pending: PlayerDeepLink?

    func handle(_ url: URL) -> PlayerDeepLink? {
        guard let target = PlayerDeepLink.parse(url) else { return nil }
        pending = target
        return target
    }

    func handle(target: AssistantPlayerTarget) -> PlayerDeepLink {
        let link = PlayerDeepLink(contentKey: target.contentKey, startMs: max(0, target.startMs))
        pending = link
        return link
    }

    func consumePending() -> PlayerDeepLink? {
        let value = pending
        pending = nil
        return value
    }
}
