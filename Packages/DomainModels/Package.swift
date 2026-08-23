// swift-tools-version: 5.9
import PackageDescription

// DomainModels —— SwiftData @Model 实体与共享 DTO 的共享底座。
// 依赖 PodcastEnglishStudioCore（纯逻辑：TranslationTarget / TranslationVariant 等枚举与策略），
// 自身不引入 UIKit/CloudKit。app 与后续 PlayerKit/CloudSyncKit 均以它为共享枢纽，
// 避免每个包各自拖 SwiftData。
let package = Package(
    name: "DomainModels",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DomainModels", targets: ["DomainModels"])
    ],
    dependencies: [
        // 本地 Core 包（根 ios/PodcastEnglishStudio/Package.swift 提供 PodcastEnglishStudioCore 产品）。
        .package(path: "../../ios/PodcastEnglishStudio")
    ],
    targets: [
        .target(
            name: "DomainModels",
            dependencies: [
                .product(name: "PodcastEnglishStudioCore", package: "PodcastEnglishStudio")
            ],
            path: "Sources/DomainModels"
        ),
        .testTarget(
            name: "DomainModelsTests",
            dependencies: ["DomainModels"],
            path: "Tests/DomainModelsTests"
        )
    ]
)
