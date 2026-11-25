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

    /// The folders among the launch arguments. `-Key value` pairs set preferences for the launch (NSArgumentDomain, such as `-AppleLanguages (de)`) and are not folders.
    nonisolated static func folderArguments(_ arguments: [String]) -> [String] {
        var folders: [String] = []
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            if argument.hasPrefix("-"), argument.count > 1 {
                rest = rest.dropFirst()
            } else {
                folders.append(argument)
            }
        }
        return folders
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services activates an app bundle, unless it was opened in the background; a bare executable from `swift run` activates itself.
        if Bundle.main.bundleURL.pathExtension != "app" { NSApp.activate(ignoringOtherApps: true) }
        context.settings.apply()
        let menu = MainMenu(target: self, runAction: #selector(runMenuCommand(_:)), commandBarAction: #selector(showCommandBar(_:)), openRecentAction: #selector(openRecent(_:)), commands: { [weak self] in self?.currentCommands() ?? [] }, recents: { [weak self] in self?.windowController?.recentRepositories ?? [] })
        menu.install()
        mainMenu = menu
        let controller = MainWindowController(context: context, openSettings: { [unowned self] section in settingsWindow.show(section) })
        windowController = controller
        controller.openInitialTabs(arguments: Self.folderArguments(CommandLine.arguments), folders: pendingFolders)
        pendingFolders = []
    }

    /// Folders dropped on the Dock icon, opened from Finder or with `open -a GitBonsai <folder>`; a folder outside any repository gets the same alert as the Open panel.
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        guard let windowController else {
            // AppKit also hands over the launch arguments as files to open; those already open as arguments.
            let arguments = Set(Self.folderArguments(CommandLine.arguments).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            return pendingFolders.append(contentsOf: paths.filter { !arguments.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) })
        }
        windowController.open(paths: paths, activate: paths.count - 1)
        windowController.showWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
