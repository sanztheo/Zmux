// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZMUXWorkstream",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ZMUXWorkstream",
            targets: ["ZMUXWorkstream"]
        ),
    ],
    targets: [
        .target(
            name: "ZMUXWorkstream"
        ),
        .testTarget(
            name: "ZMUXWorkstreamTests",
            dependencies: ["ZMUXWorkstream"]
        ),
    ]
)
