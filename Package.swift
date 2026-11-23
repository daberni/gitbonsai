// swift-tools-version: 6.0
import Foundation
import PackageDescription

// A bare executable (swift run, harness runs) has no Info.plist, and without CFBundleLocalizations in the main bundle macOS shows every resource bundle in the development language.
// The linker embeds this one; GitBonsai.app carries the same keys in its own Info.plist, which takes precedence.
let embeddedInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/GitBonsaiApp/Support/Info.plist").path

let package = Package(
    name: "GitBonsai",
    defaultLocalization: "en",
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
        .executableTarget(
            name: "GitBonsaiApp",
            dependencies: ["GitEngine", "GraphLayout", "Avatars"],
            exclude: ["Support"],
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", embeddedInfoPlist])]
        ),
        .testTarget(name: "GitEngineTests", dependencies: ["GitEngine", "GraphLayout"]),
        .testTarget(name: "GraphLayoutTests", dependencies: ["GraphLayout", "GitEngine"]),
        .testTarget(name: "AvatarsTests", dependencies: ["Avatars"]),
        .testTarget(name: "LocalizationTests"),
        .testTarget(name: "GitBonsaiAppTests", dependencies: ["GitBonsaiApp"]),
    ],
    swiftLanguageModes: [.v6]
)
