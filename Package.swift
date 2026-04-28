// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "zmux",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "zmux", targets: ["zmux"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "zmux",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
