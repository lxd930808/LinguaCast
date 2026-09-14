// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodcastEnglishStudio",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PodcastEnglishStudioCore", targets: ["PodcastEnglishStudioCore"])
    ],
    targets: [
        .target(
            name: "PodcastEnglishStudioCore",
            path: "PodcastEnglishStudioCore"
        ),
        .testTarget(
            name: "PodcastEnglishStudioTests",
            dependencies: ["PodcastEnglishStudioCore"],
            path: "PodcastEnglishStudioTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
