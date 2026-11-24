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

    /// What "Resolve…" of a conflicted file opens.
    enum ConflictResolver: String, CaseIterable {
        /// GitBonsai's own merge window.
        case gitBonsai
        /// The tool `git mergetool --gui` opens; the merge window where none is set.
        case mergeTool
    }

    private static var defaults: UserDefaults { ScreenshotHarness.defaults }

    /// Bundle id of the editor or terminal "Open in editor" and "Open in terminal" use; nil takes the first shown one. `ExternalApps.preferred(_:)` resolves it.
    static func defaultApp(_ kind: ExternalApps.Kind) -> String? {
        defaults.string(forKey: "default\(kind.settingsKey)")
    }

    static func setDefaultApp(_ id: String?, _ kind: ExternalApps.Kind) {
        store(id, forKey: "default\(kind.settingsKey)")
    }

    /// Bundle ids the command bar leaves out of "Open in editor with…" and "Open in terminal with…".
    static func hiddenApps(_ kind: ExternalApps.Kind) -> [String] {
        defaults.stringArray(forKey: "hidden\(kind.settingsKey)s") ?? []
    }

    static func setHiddenApps(_ ids: [String], _ kind: ExternalApps.Kind) {
        store(ids, forKey: "hidden\(kind.settingsKey)s")
    }

    /// Apps added in the settings that the app does not find on its own.
    static func addedApps(_ kind: ExternalApps.Kind) -> [URL] {
        (defaults.stringArray(forKey: "added\(kind.settingsKey)s") ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func setAddedApps(_ urls: [URL], _ kind: ExternalApps.Kind) {
        store(urls.map(\.path), forKey: "added\(kind.settingsKey)s")
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

    /// GitBonsai's merge window until the user chooses a merge tool in the settings, whatever git's config names.
    static var conflictResolver: ConflictResolver {
        get { defaults.string(forKey: "conflictResolver").flatMap(ConflictResolver.init) ?? .gitBonsai }
        set { store(newValue == .gitBonsai ? nil : newValue.rawValue, forKey: "conflictResolver") }
    }

    /// Light or dark for every window, or whatever the system uses.
    static var appearance: Appearance {
        get { defaults.string(forKey: "appearance").flatMap(Appearance.init) ?? .system }
        set {
            store(newValue.rawValue, forKey: "appearance")
            NSApp.appearance = newValue.nsAppearance
        }
    }

    /// The interface language from the next launch on. A choice other than the system's is stored as the app's own `AppleLanguages`, the way the system settings store a language per app;
    /// harness runs keep it in their own domain and never touch it, `GITBONSAI_LANGUAGE` picks theirs.
    static var language: AppLanguage.Choice {
        get { defaults.string(forKey: "language").flatMap(AppLanguage.Choice.init) ?? .system }
        set {
            store(newValue == .system ? nil : newValue.rawValue, forKey: "language")
            guard !ScreenshotHarness.isActive else { return }
            if newValue == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") } else { UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages") }
        }
    }

    /// How the history sorts commits across branches; open tabs read the history again when it changes.
    static var historyOrder: HistoryOrder {
        get { defaults.string(forKey: "historyOrder").flatMap(HistoryOrder.init) ?? .date }
        set { store(newValue == .date ? nil : newValue.rawValue, forKey: "historyOrder") }
    }

    /// Plain initials, or pictures from the remote host and optionally Gravatar; by default pictures from the remote host only. Harness runs show initials unless `GITBONSAI_AVATARS` asks for pictures.
    static var avatarMode: AvatarMode {
        get {
            let stored = AvatarMode.stored(defaults.string(forKey: "avatarMode"), legacyEnabled: defaults.object(forKey: "avatarsEnabled") as? Bool, legacySources: defaults.string(forKey: "avatarSources"))
            return stored ?? (ScreenshotHarness.isActive ? .initialsOnly : .remoteHost)
        }
        set {
            defaults.removeObject(forKey: "avatarsEnabled")
            defaults.removeObject(forKey: "avatarSources")
            store(newValue.rawValue, forKey: "avatarMode")
        }
    }

    /// The name the About window shows as holder of a commercial license; nothing checks it.
    static var licensee: String? {
        get { defaults.string(forKey: "licensee").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        set { store(newValue?.isEmpty == true ? nil : newValue, forKey: "licensee") }
    }

    /// The settings section shown last, so the window opens there again; view state, so changing it notifies no one.
    static var lastSettingsSection: String? {
        get { defaults.string(forKey: "lastSettingsSection") }
        set { defaults.set(newValue, forKey: "lastSettingsSection") }
    }

    /// Hands the stored choices to AppKit and the git engine; called once at launch, before the first window.
    static func apply() {
        NSApp.appearance = appearance.nsAppearance
        GitRunner.preferredGitPath = gitPath
        ScreenshotHarness.applyAvatarSwitches()
        ScreenshotHarness.applyHistoryOrderSwitch()
    }

    private static func store(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

extension ExternalApps.Kind {
    /// The middle of the defaults keys: `defaultEditor`, `hiddenTerminals`, `addedEditors`.
    var settingsKey: String {
        switch self {
        case .editor: "Editor"
        case .terminal: "Terminal"
        }
    }
}
