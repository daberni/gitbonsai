import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ScreenshotHarness.isActive { NSApp.activate(ignoringOtherApps: true) }
        ScreenshotHarness.applyAppearance()
        NSApp.mainMenu = makeMenu()
        let controller = MainWindowController(store: SessionStore.standard())
        windowController = controller
        controller.showWindow(nil)
        // The capture renders the views itself, so the window can stay behind everything else.
        if ScreenshotHarness.isActive { controller.window?.orderBack(nil) }
        controller.openInitialTabs(arguments: Array(CommandLine.arguments.dropFirst()))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }

        let recent = submenu("Zuletzt verwendet", [])
        recent.submenu?.delegate = self

        let menu = NSMenu()
        menu.addItem(submenu("GitBonsai", [
            item("GitBonsai ausblenden", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("GitBonsai beenden", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        menu.addItem(submenu("Ablage", [
            item("Neuer Tab", #selector(MainWindowController.newTab(_:)), "t"),
            item("Repository öffnen …", #selector(MainWindowController.openRepository(_:)), "o"),
            recent,
            .separator(),
            item("Tab schließen", #selector(MainWindowController.closeTab(_:)), "w"),
        ]))
        menu.addItem(submenu("Bearbeiten", [
            item("Ausschneiden", #selector(NSText.cut(_:)), "x"),
            item("Kopieren", #selector(NSText.copy(_:)), "c"),
            item("Einsetzen", #selector(NSText.paste(_:)), "v"),
            item("Alles auswählen", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = submenu("Fenster", [
            item("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
            item("Nächster Tab", #selector(MainWindowController.selectNextTab(_:)), "}"),
            item("Vorheriger Tab", #selector(MainWindowController.selectPreviousTab(_:)), "{"),
        ])
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paths = windowController?.recentRepositories ?? []
        for path in paths {
            let item = NSMenuItem(title: (path as NSString).abbreviatingWithTildeInPath, action: #selector(MainWindowController.openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            menu.addItem(item)
        }
        if paths.isEmpty {
            let empty = NSMenuItem(title: "Noch nichts geöffnet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }
}
