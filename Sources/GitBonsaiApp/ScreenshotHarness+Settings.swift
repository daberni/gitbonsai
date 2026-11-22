import AppKit
import GitEngine

/// Harness switches for the settings window and automatic fetching.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SETTINGS=general|git|appearance|fetch` opens the settings on that section and captures the settings window instead of the main window.
    static var settingsSection: SettingsWindowController.Section? {
        environment["GITBONSAI_SETTINGS"].flatMap(SettingsWindowController.Section.init)
    }

    static func openSettingsIfAsked() {
        guard isActive, let section = settingsSection else { return }
        let settings = SettingsWindowController.shared
        settings.show(section)
        if runsInBackground { hideWindows() }
        if let window = settings.window { captureAndQuit(window: window) }
    }

    /// The main window is not captured while the settings window is.
    static func capturesSettingsInstead(of window: NSWindow) -> Bool {
        settingsSection != nil && window !== SettingsWindowController.shared.window
    }

    /// `GITBONSAI_AUTO_FETCH=<seconds>` lets the repository tabs fetch on their own at that interval during a harness run, which otherwise never fetches by itself.
    static var autoFetchSeconds: TimeInterval? {
        environment["GITBONSAI_AUTO_FETCH"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }

    static func traceAutoFetch() {
        guard isActive else { return }
        FileHandle.standardError.write(Data("auto-fetch with \(GitRunner.defaultGitPath())\n".utf8))
    }
}
