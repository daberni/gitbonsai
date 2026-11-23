import AppKit
import UniformTypeIdentifiers

/// An editor or terminal the app knows how to open a folder in.
struct ExternalApp: Equatable {
    /// How the app takes a folder. Most accept it as a document; a few only through their command-line binary or a URL scheme.
    enum Opening: Equatable {
        /// `NSWorkspace.open(_:withApplicationAt:)` with the folder URL.
        case document
        /// The app's binary inside the bundle, with these arguments before the folder path.
        case binary(String, arguments: [String])
        /// A URL scheme that takes the folder's path as `path` query item.
        case urlScheme(String)
    }

    let name: String
    let bundleID: String
    var opening: Opening = .document

    /// Where the app is installed, or nil.
    @MainActor var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
}

/// Finds editors and terminals and opens files and folders in them, as chosen in the settings.
/// Under the screenshot harness it prints what it would open instead of launching anything.
@MainActor
enum ExternalApps {
    static let terminalBundleID = "com.apple.Terminal"

    /// Terminals in the order the settings list them. Terminal, iTerm2 and Ghostty open a dropped folder in a new window there; Warp takes its `warp://action/new_window?path=` URL;
    /// kitty, WezTerm and Alacritty ignore a folder handed to the app, so their own binary starts a window in it.
    static let terminals: [ExternalApp] = [
        ExternalApp(name: "Terminal", bundleID: terminalBundleID),
        ExternalApp(name: "iTerm2", bundleID: "com.googlecode.iterm2"),
        ExternalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        ExternalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable", opening: .urlScheme("warp://action/new_window")),
        ExternalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty", opening: .binary("kitty", arguments: ["--single-instance", "--directory"])),
        ExternalApp(name: "WezTerm", bundleID: "com.github.wez.wezterm", opening: .binary("wezterm", arguments: ["start", "--cwd"])),
        ExternalApp(name: "Alacritty", bundleID: "org.alacritty", opening: .binary("alacritty", arguments: ["--working-directory"])),
    ]

    /// Editors in the order the settings list them. All of them open a folder handed to the app as a project or workspace.
    static let editors: [ExternalApp] = [
        ExternalApp(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        ExternalApp(name: "Visual Studio Code Insiders", bundleID: "com.microsoft.VSCodeInsiders"),
        ExternalApp(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        ExternalApp(name: "Windsurf", bundleID: "com.exafunction.windsurf"),
        ExternalApp(name: "Zed", bundleID: "dev.zed.Zed"),
        ExternalApp(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        ExternalApp(name: "Nova", bundleID: "com.panic.Nova"),
        ExternalApp(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        ExternalApp(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        ExternalApp(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        ExternalApp(name: "IntelliJ IDEA CE", bundleID: "com.jetbrains.intellij.ce"),
        ExternalApp(name: "WebStorm", bundleID: "com.jetbrains.WebStorm"),
        ExternalApp(name: "PyCharm", bundleID: "com.jetbrains.pycharm"),
        ExternalApp(name: "PyCharm CE", bundleID: "com.jetbrains.pycharm.ce"),
        ExternalApp(name: "GoLand", bundleID: "com.jetbrains.goland"),
        ExternalApp(name: "Android Studio", bundleID: "com.google.android.studio"),
        ExternalApp(name: "Fleet", bundleID: "com.jetbrains.fleet"),
    ]

    /// Further terminals and editors that are found by bundle id when installed; they take a folder as a document.
    static let moreTerminals: [ExternalApp] = [
        ExternalApp(name: "Warp Preview", bundleID: "dev.warp.Warp-Preview", opening: .urlScheme("warp://action/new_window")),
        ExternalApp(name: "Hyper", bundleID: "co.zeit.hyper"),
        ExternalApp(name: "Tabby", bundleID: "org.tabby"),
        ExternalApp(name: "Rio", bundleID: "com.raphaelamorim.rio"),
        ExternalApp(name: "Wave", bundleID: "dev.commandline.waveterm"),
    ]

    static let moreEditors: [ExternalApp] = [
        ExternalApp(name: "VSCodium", bundleID: "com.vscodium"),
        ExternalApp(name: "Code - OSS", bundleID: "com.visualstudio.code.oss"),
        ExternalApp(name: "Zed Preview", bundleID: "dev.zed.Zed-Preview"),
        ExternalApp(name: "Sublime Text 3", bundleID: "com.sublimetext.3"),
        ExternalApp(name: "TextMate", bundleID: "com.macromates.TextMate"),
        ExternalApp(name: "CotEditor", bundleID: "com.coteditor.CotEditor"),
        ExternalApp(name: "MacVim", bundleID: "org.vim.MacVim"),
        ExternalApp(name: "Emacs", bundleID: "org.gnu.Emacs"),
        ExternalApp(name: "Rider", bundleID: "com.jetbrains.rider"),
        ExternalApp(name: "CLion", bundleID: "com.jetbrains.CLion"),
        ExternalApp(name: "PhpStorm", bundleID: "com.jetbrains.PhpStorm"),
        ExternalApp(name: "RubyMine", bundleID: "com.jetbrains.rubymine"),
        ExternalApp(name: "RustRover", bundleID: "com.jetbrains.rustrover"),
    ]

    /// Editors and terminals are chosen the same way: detected apps, apps added in the settings, which of them the command bar offers, and a default.
    enum Kind: CaseIterable {
        case editor, terminal

        @MainActor var catalog: [ExternalApp] {
            switch self {
            case .editor: ExternalApps.editors + ExternalApps.moreEditors
            case .terminal: ExternalApps.terminals + ExternalApps.moreTerminals
            }
        }
    }

    struct Choice {
        let app: ExternalApp
        let url: URL
        let isShown: Bool
    }

    /// Installed apps of the catalog, then apps the system lists as able to run a shell script file (terminals only; for editors that list is mostly browsers and office apps), then the ones added in the settings.
    static func choices(_ kind: Kind) -> [Choice] {
        let hidden = Set(AppSettings.hiddenApps(kind))
        var found: [(ExternalApp, URL)] = kind.catalog.compactMap { app in app.url.map { (app, $0) } }
        func add(_ url: URL) {
            guard let app = app(at: url), !found.contains(where: { $0.0.bundleID == app.bundleID }) else { return }
            found.append((app, url))
        }
        if kind == .terminal { NSWorkspace.shared.urlsForApplications(toOpen: .unixExecutable).forEach(add) }
        AppSettings.addedApps(kind).forEach(add)
        return found.map { Choice(app: $0.0, url: $0.1, isShown: !hidden.contains($0.0.bundleID)) }
    }

    /// The apps the command bar lists under "Open in editor with…" and "Open in terminal with…".
    static func shown(_ kind: Kind) -> [Choice] {
        choices(kind).filter(\.isShown)
    }

    /// The default from the settings when it is installed, otherwise the first shown app.
    static func preferred(_ kind: Kind) -> Choice? {
        let choices = choices(kind)
        if let id = AppSettings.defaultApp(kind), let chosen = choices.first(where: { $0.app.bundleID == id }) { return chosen }
        return choices.first(where: \.isShown)
    }

    /// The editor for a repository. This is the one place to ask; a per-repository choice (`gitbonsai.editor` in git config) would be looked up here first.
    static func editor(forRepository path: String?) -> Choice? {
        preferred(.editor)
    }

    static func terminal() -> Choice? {
        preferred(.terminal)
    }

    /// The app at `url` as an entry, with the catalog's way of opening when it is a known app.
    static func app(at url: URL) -> ExternalApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let known = Kind.allCases.flatMap(\.catalog).first { $0.bundleID == id }
        return known ?? ExternalApp(name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), bundleID: id)
    }

    static func openInTerminal(_ folder: URL) {
        guard let terminal = terminal() else { return }
        open(folder, in: terminal.app, at: terminal.url)
    }

    // MARK: Opening

    /// Shows the items selected in a Finder window. Harness runs print what they would reveal instead.
    static func reveal(_ items: [URL]) {
        if ScreenshotHarness.isActive { return ScreenshotHarness.reportOpening("Finder", "reveal \(items.map(\.path).joined(separator: " "))") }
        NSWorkspace.shared.activateFileViewerSelecting(items)
    }

    /// Opens the item with the app the system assigns to it. Harness runs print what they would open instead.
    static func openWithDefaultApp(_ item: URL) {
        if ScreenshotHarness.isActive { return ScreenshotHarness.reportOpening("default app", "open \(item.path)") }
        NSWorkspace.shared.open(item)
    }

    /// Hands the file or folder to the app the way it supports.
    static func open(_ item: URL, in app: ExternalApp, at appURL: URL, completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        let plan = plan(for: item, in: app, at: appURL)
        if ScreenshotHarness.isActive { return ScreenshotHarness.reportOpening(app.name, plan.description) }
        switch plan {
        case .document(let items, let application):
            NSWorkspace.shared.open(items, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                Task { @MainActor in completion?(error) }
            }
        case .url(let url, let application):
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                Task { @MainActor in completion?(error) }
            }
        case .process(let binary, let arguments):
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            do {
                try process.run()
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    enum Plan: CustomStringConvertible {
        case document([URL], application: URL)
        case url(URL, application: URL)
        case process(URL, arguments: [String])

        var description: String {
            switch self {
            case .document(let items, let application): "open \(items.map(\.path).joined(separator: " ")) with \(application.path)"
            case .url(let url, let application): "open \(url.absoluteString) with \(application.path)"
            case .process(let binary, let arguments): "run \(([binary.path] + arguments).joined(separator: " "))"
            }
        }
    }

    static func plan(for item: URL, in app: ExternalApp, at appURL: URL) -> Plan {
        switch app.opening {
        case .document:
            return .document([item], application: appURL)
        case .binary(let name, let arguments):
            return .process(appURL.appendingPathComponent("Contents/MacOS/\(name)"), arguments: arguments + [item.path])
        case .urlScheme(let base):
            var components = URLComponents(string: base)
            components?.queryItems = [URLQueryItem(name: "path", value: item.path)]
            guard let url = components?.url else { return .document([item], application: appURL) }
            return .url(url, application: appURL)
        }
    }
}
