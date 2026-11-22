import AppKit

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

    // MARK: Editors

    /// Detected editors and the ones added in the settings, each with whether the command bar offers it.
    static func editorChoices() -> [(app: ExternalApp, url: URL, isShown: Bool)] {
        let hidden = Set(AppSettings.hiddenEditors)
        let detected = editors.compactMap { app in app.url.map { (app, $0) } }
        let added = AppSettings.addedEditors.compactMap { url -> (ExternalApp, URL)? in
            guard let app = app(at: url), !detected.contains(where: { $0.0.bundleID == app.bundleID }) else { return nil }
            return (app, url)
        }
        return (detected + added).map { (app: $0.0, url: $0.1, isShown: !hidden.contains($0.0.bundleID)) }
    }

    /// The editors the command bar lists under "Im Editor öffnen …".
    static func shownEditors() -> [(app: ExternalApp, url: URL)] {
        editorChoices().filter(\.isShown).map { ($0.app, $0.url) }
    }

    /// The editor for a repository: the default from the settings when it is installed, otherwise the first shown one.
    /// This is the one place to ask; a per-repository choice (`gitbonsai.editor` in git config) would be looked up here first.
    static func editor(forRepository path: String?) -> (app: ExternalApp, url: URL)? {
        let choices = editorChoices()
        if let id = AppSettings.defaultEditor, let chosen = choices.first(where: { $0.app.bundleID == id }) { return (chosen.app, chosen.url) }
        return choices.first(where: \.isShown).map { ($0.app, $0.url) }
    }

    /// The app at `url` as an editor entry, named by its bundle.
    static func app(at url: URL) -> ExternalApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let known = (editors + terminals).first { $0.bundleID == id }
        return known ?? ExternalApp(name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), bundleID: id)
    }

    // MARK: Terminals

    static func installedTerminals() -> [(app: ExternalApp, url: URL)] {
        terminals.compactMap { app in app.url.map { (app, $0) } }
    }

    /// The terminal "Open in Terminal" uses: the chosen one, otherwise Terminal.
    static func terminal() -> (app: ExternalApp, url: URL)? {
        if let chosen = AppSettings.terminalApp { return app(at: chosen).map { ($0, chosen) } }
        return terminals[0].url.map { (terminals[0], $0) }
    }

    static func openInTerminal(_ folder: URL) {
        guard let terminal = terminal() else { return }
        open(folder, in: terminal.app, at: terminal.url)
    }

    // MARK: Opening

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
