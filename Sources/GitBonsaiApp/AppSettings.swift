import Foundation

/// User preferences shared across the app. The settings window edits them; features read them where they need them.
/// Screenshot runs use their own defaults domain so they never see or change the user's choices.
@MainActor
enum AppSettings {
    private static var defaults: UserDefaults {
        ScreenshotHarness.isActive ? UserDefaults(suiteName: "app.gitbonsai.harness") ?? .standard : .standard
    }

    /// The app that opens files for editing; nil uses the system's default app for the file.
    static var externalEditor: URL? {
        get { defaults.url(forKey: "externalEditor") }
        set { defaults.set(newValue, forKey: "externalEditor") }
    }

    /// The terminal app for "Open in Terminal"; nil uses Terminal.
    static var terminalApp: URL? {
        get { defaults.url(forKey: "terminalApp") }
        set { defaults.set(newValue, forKey: "terminalApp") }
    }

    /// A git binary chosen by the user; nil finds one on its own (`GitRunner.defaultGitPath`).
    static var gitPath: String? {
        get { defaults.string(forKey: "gitPath") }
        set { defaults.set(newValue, forKey: "gitPath") }
    }

    /// Minutes between automatic fetches; 0 turns automatic fetching off.
    static var autoFetchMinutes: Int {
        get { defaults.object(forKey: "autoFetchMinutes") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "autoFetchMinutes") }
    }
}
