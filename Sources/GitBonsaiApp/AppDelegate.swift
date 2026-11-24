import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let context: AppContext
    private var windowController: MainWindowController?
    private lazy var settingsWindow = SettingsWindowController(settings: context.settings)
    private var mainMenu: MainMenu?
    /// Folders from Finder or `open -a` that arrive before the window exists; launch opens them after the saved session.
    private var pendingFolders: [String] = []

    init(context: AppContext) {
        self.context = context
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // harness: the launched app always activates; the harness keeps it out of the way by launching it hidden.
        if !ScreenshotHarness.runsInBackground { NSApp.activate(ignoringOtherApps: true) }
        // harness: run folders belong to the harness process, which removes its own.
        ScreenshotHarness.removeStaleRunFolders()
        // harness: the harness drives the app through Accessibility and reads nothing from inside it.
        ScreenshotHarness.attach(context) { [unowned self] in settingsWindow }
        context.settings.apply()
        // harness: replaced by the launch argument `-AppleInterfaceStyle Dark` and the stored appearance in the harness's defaults domain.
        ScreenshotHarness.applyAppearance()
        let menu = MainMenu(target: self, runAction: #selector(runMenuCommand(_:)), commandBarAction: #selector(showCommandBar(_:)), openRecentAction: #selector(openRecent(_:)), commands: { [weak self] in self?.currentCommands() ?? [] }, recents: { [weak self] in self?.windowController?.recentRepositories ?? [] })
        menu.install()
        mainMenu = menu
        let controller = MainWindowController(context: context, openSettings: { [unowned self] section in settingsWindow.show(section) })
        windowController = controller
        // harness: the harness launches the app hidden and captures its windows with ScreenCaptureKit, so nothing needs to be invisible.
        if ScreenshotHarness.runsInBackground {
            ScreenshotHarness.keepWindowsInvisible()
            controller.window?.alphaValue = 0
            controller.window?.ignoresMouseEvents = true
        }
        controller.openInitialTabs(arguments: Array(CommandLine.arguments.dropFirst()), folders: pendingFolders)
        pendingFolders = []
        // harness: opens the windows through the menu bar via Accessibility and captures them with ScreenCaptureKit.
        ScreenshotHarness.openSettingsIfAsked()
        ScreenshotHarness.openAboutIfAsked()
    }

    /// Folders dropped on the Dock icon, opened from Finder or with `open -a GitBonsai <folder>`; a folder outside any repository gets the same alert as the Open panel.
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        guard let windowController else {
            // AppKit also hands over the launch arguments as files to open; those already open as arguments.
            let arguments = Set(CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            return pendingFolders.append(contentsOf: paths.filter { !arguments.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) })
        }
        windowController.open(paths: paths, activate: paths.count - 1)
        windowController.showWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // harness: the harness process removes its run folder and pasteboard after the app quits.
        ScreenshotHarness.cleanUpRun()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Commands

    @objc func showAbout(_ sender: Any?) {
        AboutPanel.show(licensee: context.settings.licensee)
    }

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
