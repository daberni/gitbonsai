// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitBonsai",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitEngine", targets: ["GitEngine"]),
    ],
    targets: [
        .target(name: "GitEngine"),
        .testTarget(name: "GitEngineTests", dependencies: ["GitEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
