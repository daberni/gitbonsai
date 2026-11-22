// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitBonsai",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitEngine", targets: ["GitEngine"]),
        .library(name: "GraphLayout", targets: ["GraphLayout"]),
    ],
    targets: [
        .target(name: "GitEngine"),
        .target(name: "GraphLayout", dependencies: ["GitEngine"]),
        .testTarget(name: "GitEngineTests", dependencies: ["GitEngine"]),
        .testTarget(name: "GraphLayoutTests", dependencies: ["GraphLayout", "GitEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
