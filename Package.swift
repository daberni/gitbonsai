// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitBonsai",
    // macOS records the SDK of a SwiftPM build as this version and draws windows in the current style only from 26 on.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GitEngine", targets: ["GitEngine"]),
        .library(name: "GraphLayout", targets: ["GraphLayout"]),
        .executable(name: "GitBonsaiApp", targets: ["GitBonsaiApp"]),
    ],
    targets: [
        .target(name: "GitEngine"),
        .target(name: "GraphLayout", dependencies: ["GitEngine"]),
        .executableTarget(name: "GitBonsaiApp", dependencies: ["GitEngine", "GraphLayout"]),
        .testTarget(name: "GitEngineTests", dependencies: ["GitEngine"]),
        .testTarget(name: "GraphLayoutTests", dependencies: ["GraphLayout", "GitEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
