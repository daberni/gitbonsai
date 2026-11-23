import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController?
    private var mainMenu: MainMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ScreenshotHarness.runsInBackground { NSApp.activate(ignoringOtherApps: true) }
        ScreenshotHarness.removeStaleRunFolders()
        AppSettings.apply()
        ScreenshotHarness.applyAppearance()
        ScreenshotHarness.applyRepositoryFolders()
        let menu = MainMenu(target: self, runAction: #selector(runMenuCommand(_:)), commandBarAction: #selector(showCommandBar(_:)), commands: { [weak self] in self?.currentCommands() ?? [] }, recents: { [weak self] in self?.windowController?.recentRepositories ?? [] })
        menu.install()
        mainMenu = menu
        let controller = MainWindowController(store: SessionStore.standard())
        windowController = controller
        if ScreenshotHarness.runsInBackground {
            ScreenshotHarness.keepWindowsInvisible()
            controller.window?.alphaValue = 0
            controller.window?.ignoresMouseEvents = true
        }
        controller.openInitialTabs(arguments: Array(CommandLine.arguments.dropFirst()))
        ScreenshotHarness.openSettingsIfAsked()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenshotHarness.cleanUpRun()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Commands

    /// The command bar and the menu's command items target the delegate, so they also work while the window is not key.
    @objc func showCommandBar(_ sender: Any?) {
        windowController?.showCommandBar(sender)
    }

    @objc func runMenuCommand(_ sender: NSMenuItem) {
        cachedCommands = nil
        if sender.representedObject as? String == CommandSpec.closeTab.id, let window = auxiliaryKeyWindow {
            return window.performClose(sender)
        }
        windowController?.runMenuCommand(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runMenuCommand(_:)), let id = menuItem.representedObject as? String else { return true }
        if id == CommandSpec.closeTab.id, let window = auxiliaryKeyWindow { return window.styleMask.contains(.closable) }
        return currentCommands().first { $0.id == id }?.isEnabled ?? false
    }

    /// ⌘W closes the tab only in the main window; in the settings or any other window that has the focus it closes that window, as `performClose:` does everywhere on macOS.
    private var auxiliaryKeyWindow: NSWindow? {
        guard let key = NSApp.keyWindow, key !== windowController?.window else { return nil }
        return key
    }

    /// A ⌘ key press updates and validates every menu at once; they share one list of commands for a moment, so the tab's state is read once.
    private var cachedCommands: (time: TimeInterval, commands: [Command])?

    private func currentCommands() -> [Command] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedCommands, now - cachedCommands.time < 0.2 { return cachedCommands.commands }
        let commands = windowController?.allCommands() ?? []
        cachedCommands = (now, commands)
        return commands
    }
}
