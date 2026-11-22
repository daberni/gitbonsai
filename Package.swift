// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitBonsai",
    // macOS records the SDK of a SwiftPM build as this version and draws windows in the current style only from 26 on.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GitEngine", targets: ["GitEngine"]),
        .library(name: "GraphLayout", targets: ["GraphLayout"]),
        .library(name: "Avatars", targets: ["Avatars"]),
        .executable(name: "GitBonsaiApp", targets: ["GitBonsaiApp"]),
    ],
    targets: [
        .target(name: "GitEngine"),
        .target(name: "GraphLayout", dependencies: ["GitEngine"]),
        .target(name: "Avatars"),
        .executableTarget(name: "GitBonsaiApp", dependencies: ["GitEngine", "GraphLayout", "Avatars"]),
        .testTarget(name: "GitEngineTests", dependencies: ["GitEngine", "GraphLayout"]),
        .testTarget(name: "GraphLayoutTests", dependencies: ["GraphLayout", "GitEngine"]),
        .testTarget(name: "AvatarsTests", dependencies: ["Avatars"]),
    ],
    swiftLanguageModes: [.v6]
)
