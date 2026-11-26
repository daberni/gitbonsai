// swift-tools-version: 6.0
import Foundation
import PackageDescription

// A bare executable (swift run) has no Info.plist, and without CFBundleLocalizations in the main bundle macOS shows every resource bundle in the development language.
// The linker embeds this one; GitBonsai.app carries the same keys in its own Info.plist, which takes precedence.
let embeddedInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/GitBonsai/Support/Info.plist").path

let embedInfoPlist: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", embeddedInfoPlist])]

let package = Package(
    name: "GitBonsai",
    defaultLocalization: "en",
    // macOS records the SDK of a SwiftPM build as this version and draws windows in the current style only from 26 on.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GitEngine", targets: ["GitEngine"]),
        .library(name: "GraphLayout", targets: ["GraphLayout"]),
        .library(name: "Avatars", targets: ["Avatars"]),
        .library(name: "TextViewerModel", targets: ["TextViewerModel"]),
        .executable(name: "GitBonsai", targets: ["GitBonsai"]),
    ],
    // Text viewer: CodeEditTextView draws the text; tree-sitter and the grammars below highlight it. Licenses are listed in docs/third-party-licenses.md.
    dependencies: [
        .package(url: "https://github.com/CodeEditApp/CodeEditTextView", exact: "0.12.1"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp", exact: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
        .package(url: "https://github.com/fwcd/tree-sitter-kotlin", exact: "0.3.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-php", exact: "0.25.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-diff", exact: "0.2.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.4"),
        // No releases yet; pinned to a reviewed commit.
        .package(url: "https://github.com/mdovale/tree-sitter-less", revision: "02988c765d30adb0476657b5d220e8dfde1c07d3"),
    ],
    targets: [
        .target(name: "GitEngine"),
        .target(name: "GraphLayout", dependencies: ["GitEngine"]),
        .target(name: "Avatars"),
        // External scanners of grammars whose manifests leave them out when built as a dependency (see its header); upstream C, compiled without warnings of ours.
        .target(name: "TreeSitterSCSS", exclude: ["LICENSE"], cSettings: [.unsafeFlags(["-w"])]),
        .target(name: "TreeSitterXML", exclude: ["LICENSE"], cSettings: [.headerSearchPath("."), .unsafeFlags(["-w"])]),
        .target(name: "TreeSitterProperties", exclude: ["LICENSE"], cSettings: [.unsafeFlags(["-w"])]),
        .target(name: "TreeSitterScanners", exclude: ["yaml/schema.core.c"], cSettings: [.unsafeFlags(["-w"])]),
        // The text viewer's model: lines, encodings, selection, find and highlighting, without AppKit.
        .target(name: "TextViewerModel", dependencies: ["TreeSitterScanners", "TreeSitterSCSS", "TreeSitterXML", "TreeSitterProperties", .product(name: "TreeSitterLess", package: "tree-sitter-less"), .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"), .product(name: "TreeSitterSwift", package: "tree-sitter-swift"), .product(name: "TreeSitterC", package: "tree-sitter-c"), .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"), .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"), .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"), .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"), .product(name: "TreeSitterPython", package: "tree-sitter-python"), .product(name: "TreeSitterGo", package: "tree-sitter-go"), .product(name: "TreeSitterRust", package: "tree-sitter-rust"), .product(name: "TreeSitterJava", package: "tree-sitter-java"), .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin"), .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"), .product(name: "TreeSitterPHP", package: "tree-sitter-php"), .product(name: "TreeSitterBash", package: "tree-sitter-bash"), .product(name: "TreeSitterJSON", package: "tree-sitter-json"), .product(name: "TreeSitterCSS", package: "tree-sitter-css"), .product(name: "TreeSitterHTML", package: "tree-sitter-html"), .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"), .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"), .product(name: "TreeSitterDiff", package: "tree-sitter-diff")], resources: [.copy("Resources/queries")]),
        // The app; tests reach it through `@testable import GitBonsai`.
        .executableTarget(name: "GitBonsai", dependencies: ["GitEngine", "GraphLayout", "Avatars", "TextViewerModel", .product(name: "CodeEditTextView", package: "CodeEditTextView")], exclude: ["Support"], resources: [.process("Resources")], linkerSettings: embedInfoPlist),
        // Performance budgets: `swift run -c release Benchmarks`, kept out of `swift test`. Engine work runs in process; the app's own paths are measured from outside through its signposts.
        .executableTarget(name: "Benchmarks", dependencies: ["GitEngine", "GraphLayout", "TextViewerModel"], path: "Benchmarks", exclude: ["baseline.json"]),
        .testTarget(name: "GitEngineTests", dependencies: ["GitEngine", "GraphLayout"]),
        .testTarget(name: "GraphLayoutTests", dependencies: ["GraphLayout", "GitEngine"]),
        .testTarget(name: "AvatarsTests", dependencies: ["Avatars"]),
        .testTarget(name: "TextViewerModelTests", dependencies: ["TextViewerModel"]),
        .testTarget(name: "LocalizationTests"),
        .testTarget(name: "GitBonsaiTests", dependencies: ["GitBonsai", "GitEngine", "Avatars"]),
    ],
    swiftLanguageModes: [.v6]
)
