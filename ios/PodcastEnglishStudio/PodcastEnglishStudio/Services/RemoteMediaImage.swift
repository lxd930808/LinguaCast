import Kingfisher
import SwiftUI
import UIKit

enum RemoteMediaImagePhase {
    case empty
    case success(Image)
    case failure
}

/// Shared remote image view backed by Kingfisher. Replaces `AsyncImage` for Podcast and
/// YouTube artwork while preserving placeholder / crop / corner-radius responsibility in callers.
struct RemoteMediaImage<Content: View>: View {
    var url: URL?
    var displaySize: CGSize
    @ViewBuilder var content: (RemoteMediaImagePhase) -> Content

    @State private var phase: RemoteMediaImagePhase = .empty
    @State private var loadedURL: String?

    var body: some View {
        content(effectivePhase)
            .task(id: taskID) {
                await load()
            }
    }

    private var taskID: String {
        url?.absoluteString ?? ""
    }

    private var effectivePhase: RemoteMediaImagePhase {
        guard let url else { return .failure }
        if loadedURL != url.absoluteString {
            return .empty
        }
        return phase
    }

    private var pixelSize: CGSize {
        let scale = max(UIScreen.main.scale, 1)
        return CGSize(
            width: max(displaySize.width * scale, 1),
            height: max(displaySize.height * scale, 1)
        )
    }

    private func load() async {
        guard let url else {
            phase = .failure
            loadedURL = nil
            return
        }
        let absolute = url.absoluteString
        phase = .empty
        loadedURL = absolute
        let processor = DownsamplingImageProcessor(size: pixelSize)
        let options: KingfisherOptionsInfo = [
            .processor(processor),
            .cacheOriginalImage,
            .backgroundDecode
        ]
        do {
            let result = try await KingfisherManager.shared.retrieveImage(with: url, options: options)
            guard !Task.isCancelled, loadedURL == absolute else { return }
            phase = .success(Image(uiImage: result.image))
        } catch {
            guard !Task.isCancelled, loadedURL == absolute else { return }
            phase = .failure
        }
    }
}
