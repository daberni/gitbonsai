import AppKit
import Avatars
import GitEngine

/// User preferences shared across the app. The settings window edits them; features read them where they need them.
/// Screenshot runs use their own defaults domain so they never see or change the user's choices.
@MainActor
enum AppSettings {
    /// Posted after any preference changed, so open windows and timers can follow at once.
    static let didChange = Notification.Name("AppSettings.didChange")

    enum Appearance: String, CaseIterable {
        case system, light, dark

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private static var defaults: UserDefaults {
        ScreenshotHarness.isActive ? UserDefaults(suiteName: "app.gitbonsai.harness") ?? .standard : .standard
    }

    /// The app that opens files for editing; nil uses the system's default app for the file.
    static var externalEditor: URL? {
        get { defaults.url(forKey: "externalEditor") }
        set { store(newValue, forKey: "externalEditor") }
    }

    /// The terminal app for "Open in Terminal"; nil uses Terminal.
    static var terminalApp: URL? {
        get { defaults.url(forKey: "terminalApp") }
        set { store(newValue, forKey: "terminalApp") }
    }

    /// A git binary chosen by the user; nil finds one on its own (`GitRunner.defaultGitPath`). Repositories opened afterwards use it.
    static var gitPath: String? {
        get { defaults.string(forKey: "gitPath").flatMap { $0.isEmpty ? nil : $0 } }
        set {
            store(newValue?.isEmpty == true ? nil : newValue, forKey: "gitPath")
            GitRunner.preferredGitPath = gitPath
        }
    }

    /// Minutes between automatic fetches of the visible repository; 0 turns them off. Until the user chooses, it is `AutoFetchPolicy.defaultIntervalMinutes`.
    static var autoFetchMinutes: Int {
        get { AutoFetchPolicy.intervalMinutes(stored: defaults.object(forKey: "autoFetchMinutes") as? Int) }
        set { store(newValue, forKey: "autoFetchMinutes") }
    }

    /// Whether a repository fetches when the app becomes active or its tab becomes visible, at most once per `AutoFetchPolicy.activationThreshold`.
    static var fetchOnActivation: Bool {
        get { defaults.object(forKey: "fetchOnActivation") as? Bool ?? true }
        set { store(newValue, forKey: "fetchOnActivation") }
    }

    /// Folders searched for repositories to suggest on the empty tab. Until the user edits the list it holds `~/Developer` when that folder exists.
    static var repositoryFolders: [String] {
        get {
            if let stored = defaults.stringArray(forKey: "repositoryFolders") { return stored }
            let developer = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
            return FileManager.default.fileExists(atPath: developer) ? [developer] : []
        }
        set { store(newValue, forKey: "repositoryFolders") }
    }

    /// Light or dark for every window, or whatever the system uses.
    static var appearance: Appearance {
        get { defaults.string(forKey: "appearance").flatMap(Appearance.init) ?? .system }
        set {
            store(newValue.rawValue, forKey: "appearance")
            NSApp.appearance = newValue.nsAppearance
        }
    }

    /// Whether author avatars are loaded from the network. Harness runs keep them off unless `GITBONSAI_AVATARS` turns them on.
    static var avatarsEnabled: Bool {
        get { defaults.object(forKey: "avatarsEnabled") as? Bool ?? !ScreenshotHarness.isActive }
        set { store(newValue, forKey: "avatarsEnabled") }
    }

    /// Which services may be asked for an avatar; by default only the host of the repository's remote.
    static var avatarSources: AvatarSources {
        get { defaults.string(forKey: "avatarSources").flatMap(AvatarSources.init) ?? .remoteHost }
        set { store(newValue.rawValue, forKey: "avatarSources") }
    }

    /// Hands the stored choices to AppKit and the git engine; called once at launch, before the first window.
    static func apply() {
        NSApp.appearance = appearance.nsAppearance
        GitRunner.preferredGitPath = gitPath
        ScreenshotHarness.applyAvatarSwitches()
    }

    private static func store(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
