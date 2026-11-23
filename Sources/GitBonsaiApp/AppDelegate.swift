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
        let menu = MainMenu(target: self, runAction: #selector(runMenuCommand(_:)), commandBarAction: #selector(showCommandBar(_:)), openRecentAction: #selector(openRecent(_:)), commands: { [weak self] in self?.currentCommands() ?? [] }, recents: { [weak self] in self?.windowController?.recentRepositories ?? [] })
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
        guard !mainWindowShowsSheet else { return NSSound.beep() }
        windowController?.showCommandBar(sender)
    }

    @objc func runMenuCommand(_ sender: NSMenuItem) {
        cachedCommands = nil
        if sender.representedObject as? String == CommandSpec.closeTab.id, let window = auxiliaryKeyWindow {
            return window.performClose(sender)
        }
        guard !mainWindowShowsSheet || Self.runsBesideSheets(sender) else { return NSSound.beep() }
        windowController?.runMenuCommand(sender)
    }

    /// Targets the delegate, so Open Recent also works while another window, such as the settings, is key.
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let windowController else { return }
        windowController.showWindow(nil)
        windowController.open(paths: [path], activate: 0)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showCommandBar(_:)) || menuItem.action == #selector(openRecent(_:)) { return !mainWindowShowsSheet }
        guard menuItem.action == #selector(runMenuCommand(_:)), let id = menuItem.representedObject as? String else { return true }
        if id == CommandSpec.closeTab.id, let window = auxiliaryKeyWindow { return window.styleMask.contains(.closable) }
        if mainWindowShowsSheet, !Self.runsBesideSheets(menuItem) { return false }
        return currentCommands().first { $0.id == id }?.isEnabled ?? false
    }

    /// While a sheet asks something in the main window, its tab must not change underneath: only commands that open another window stay.
    private var mainWindowShowsSheet: Bool { windowController?.window?.attachedSheet != nil }

    private static func runsBesideSheets(_ item: NSMenuItem) -> Bool {
        item.representedObject as? String == CommandSpec.settings.id
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
