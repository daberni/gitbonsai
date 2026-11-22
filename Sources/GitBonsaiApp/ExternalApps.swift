import AppKit

/// Opens files and folders in the editor and terminal chosen in the settings.
@MainActor
enum ExternalApps {
    static let terminalBundleID = "com.apple.Terminal"

    /// The terminal "Open in Terminal" uses: the chosen one, otherwise Terminal.
    static var terminal: URL? {
        AppSettings.terminalApp ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID)
    }

    /// Opens a file in the chosen editor, or in the system's default app for it.
    static func openInEditor(_ file: URL) {
        if let editor = AppSettings.externalEditor {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    /// Opens a folder in the chosen terminal app.
    static func openInTerminal(_ folder: URL) {
        guard let terminal else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
