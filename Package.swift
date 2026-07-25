// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftMind",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftMindCore", targets: ["SwiftMindCore"])
    ],
    targets: [
        .target(
            name: "SwiftMindCore",
            path: "Sources/SwiftMindCore"
        ),
        .testTarget(
            name: "SwiftMindCoreTests",
            dependencies: ["SwiftMindCore"],
            path: "Tests/SwiftMindCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
