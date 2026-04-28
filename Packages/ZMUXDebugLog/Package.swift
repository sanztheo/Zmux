// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ZMUXDebugLog",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ZMUXDebugLog",
            targets: ["ZMUXDebugLog"]
        ),
    ],
    targets: [
        .target(
            name: "ZMUXDebugLog",
            path: "Sources/ZMUXDebugLog"
        ),
        .testTarget(
            name: "ZMUXDebugLogTests",
            dependencies: ["ZMUXDebugLog"],
            path: "Tests/ZMUXDebugLogTests"
        ),
    ]
)
