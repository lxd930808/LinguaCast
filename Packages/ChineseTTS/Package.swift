// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChineseTTS",
    platforms: [.macOS("15.0"), .iOS("17.0"), .tvOS("17.0")],
    products: [.library(name: "KokoroPipeline", targets: ["KokoroPipeline"]), .library(name: "ChineseFrontend", targets: ["ChineseFrontend"]), .library(name: "ChineseSynthesis", targets: ["ChineseSynthesis"])],
    targets: [
        .target(name: "KokoroPipeline"),
        .target(name: "ChineseFrontend"),
        .target(name: "ChineseSynthesis", dependencies: ["ChineseFrontend", "KokoroPipeline"]),
        .testTarget(name: "KokoroPipelineTests", dependencies: ["KokoroPipeline"]),
        .testTarget(name: "ChineseSynthesisStoreTests", dependencies: ["ChineseSynthesis"])
    ]
)
