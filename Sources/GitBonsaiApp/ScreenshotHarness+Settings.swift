import AppKit
import GitEngine

/// Harness switches for the settings window.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SETTINGS=general|git|appearance|fetch|avatars` opens the settings on that section and captures the settings window instead of the main window.
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
}
