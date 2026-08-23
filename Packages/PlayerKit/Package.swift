// swift-tools-version: 5.9
import PackageDescription

// PlayerKit —— 音频播放控制层（AVFoundation + Observation）。
// 依赖 PodcastEnglishStudioCore 的播放策略（PlaybackSeekPolicy /
// EpisodePlaybackSegmentPolicy / EpisodePlaybackSegmentIndex / LearningSegment 等），
// 自身不引入 SwiftUI/SwiftData。本地化通过包内最小 L10n 回调查 app 主 bundle，
// 避免反向依赖 app 层。
let package = Package(
    name: "PlayerKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"])
    ],
    dependencies: [
        // 本地 Core 包（根 ios/PodcastEnglishStudio/Package.swift 提供 PodcastEnglishStudioCore 产品）。
        .package(path: "../../ios/PodcastEnglishStudio")
    ],
    targets: [
        .target(
            name: "PlayerKit",
            dependencies: [
                .product(name: "PodcastEnglishStudioCore", package: "PodcastEnglishStudio")
            ],
            path: "Sources/PlayerKit"
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit"],
            path: "Tests/PlayerKitTests"
        )
    ]
)
