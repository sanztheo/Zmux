// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZMUXAuthCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ZMUXAuthCore",
            targets: ["ZMUXAuthCore"]
        ),
    ],
    targets: [
        .target(
            name: "ZMUXAuthCore"
        ),
        .testTarget(
            name: "ZMUXAuthCoreTests",
            dependencies: ["ZMUXAuthCore"]
        ),
    ]
)
