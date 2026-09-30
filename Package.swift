// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShoutFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ShoutFlow",
            targets: ["ShoutFlow"]
        ),
        .library(
            name: "ShoutFlowCore",
            targets: ["ShoutFlowCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ShoutFlowCore",
            dependencies: [],
            path: "Sources/ShoutFlowCore"
        ),
        .executableTarget(
            name: "ShoutFlow",
            dependencies: ["ShoutFlowCore"],
            path: "Sources/ShoutFlowApp"
        ),
        .testTarget(
            name: "ShoutFlowTests",
            dependencies: ["ShoutFlowCore"],
            path: "Tests/ShoutFlowTests"
        )
    ]
)
