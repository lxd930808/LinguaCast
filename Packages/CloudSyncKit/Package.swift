// swift-tools-version: 5.9
import PackageDescription

// CloudSyncKit —— iCloud 同步层（CKSyncEngine 协调器 + 设置配置集群）。
// 依赖 PodcastEnglishStudioCore（CloudSyncCore：SyncDocument / SubtitleArtifact 等纯逻辑）
// 与 DomainModels（SwiftData @Model 实体）。自身不引入 UIKit/SwiftUI：
// 远程通知注册由 app 侧通过 remoteNotificationRegistrar 回调注入；
// 本地化通过包内最小 CloudSyncKitL10n 回调 app 主 bundle，避免反向依赖 app 层。
let package = Package(
    name: "CloudSyncKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CloudSyncKit", targets: ["CloudSyncKit"])
    ],
    dependencies: [
        // 本地 Core 包（根 ios/PodcastEnglishStudio/Package.swift 提供 PodcastEnglishStudioCore 产品）。
        .package(path: "../../ios/PodcastEnglishStudio"),
        // 共享 SwiftData @Model 底座。
        .package(path: "../DomainModels")
    ],
    targets: [
        .target(
            name: "CloudSyncKit",
            dependencies: [
                .product(name: "PodcastEnglishStudioCore", package: "PodcastEnglishStudio"),
                .product(name: "DomainModels", package: "DomainModels")
            ],
            path: "Sources/CloudSyncKit"
        ),
        .testTarget(
            name: "CloudSyncKitTests",
            dependencies: ["CloudSyncKit"],
            path: "Tests/CloudSyncKitTests"
        )
    ]
)
