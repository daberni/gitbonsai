import AppKit

/// Harness switches for the About window and the licensee shown there.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_ABOUT=1` opens the About window and captures it instead of the main window.
    static var capturesAbout: Bool {
        isActive && environment["GITBONSAI_ABOUT"] == "1"
    }

    /// `GITBONSAI_LICENSEE=<name>` stores the licensee in the run's defaults before any window reads it.
    static func applyLicensee() {
        guard isActive, let name = environment["GITBONSAI_LICENSEE"] else { return }
        AppSettings.licensee = name
    }

    /// The About panel the run captures; AppKit creates it on first show.
    static var aboutPanel: NSWindow?

    static func openAboutIfAsked() {
        guard capturesAbout else { return }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        AboutPanel.show()
        if runsInBackground { hideWindows() }
        guard let panel = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) }) else { return print("about: no panel") }
        aboutPanel = panel
        after(0.5) { captureAndQuit(window: panel) }
    }
}
