// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftMind",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftMindCore", targets: ["SwiftMindCore"]),
        .executable(name: "swiftmind", targets: ["SwiftMindCLI"])
    ],
    targets: [
        .target(
            name: "SwiftMindCore",
            path: "Sources/SwiftMindCore"
        ),
        .executableTarget(
            name: "SwiftMindCLI",
            dependencies: ["SwiftMindCore"],
            path: "Sources/SwiftMindCLI"
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
