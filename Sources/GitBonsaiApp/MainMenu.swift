import AppKit

/// The menu bar, generated from the command registry: every git and window action is a `CommandSpec` and runs the same `Command` as the command bar, with the same shortcut and enabled state.
/// Only what AppKit itself implements (text editing, Hide, Services, Minimize, Full Screen) stays a plain selector. AppKit asks for an update before it opens a menu and before it matches a key equivalent; enabling goes through the target's `validateMenuItem`.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate {
    enum Entry {
        /// Always listed; disabled from its spec while the tab offers no such command, as in the empty tab.
        case command(CommandSpec)
        /// Listed only while the tab offers it, such as "Upstream setzen und pullen …".
        case ifPresent(CommandSpec)
        /// Every command whose id starts with the prefix and is not placed on its own elsewhere: per remote, per pull mode, the running operation.
        case family(String)
        /// An action AppKit implements, sent along the responder chain.
        case standard(String, Selector, CommandShortcut?)
        case separator
        case recent
        case services
        case commandBar
    }

    struct Section {
        let title: String
        let entries: [Entry]
    }

    static let sections: [Section] = [
        Section(title: "GitBonsai", entries: [
            .standard("Über GitBonsai", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), nil),
            .separator,
            .command(.settings),
            .separator,
            .services,
            .separator,
            .standard("GitBonsai ausblenden", #selector(NSApplication.hide(_:)), CommandShortcut("h")),
            .standard("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), CommandShortcut("h", [.command, .option])),
            .standard("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:)), nil),
            .separator,
            .standard("GitBonsai beenden", #selector(NSApplication.terminate(_:)), CommandShortcut("q")),
        ]),
        Section(title: "Ablage", entries: [
            .command(.newTab),
            .command(.openRepository),
            .command(.clone),
            .recent,
            .separator,
            .command(.closeTab),
            .standard("Fenster schließen", #selector(NSWindow.performClose(_:)), CommandShortcut("w", [.command, .shift])),
        ]),
        Section(title: "Bearbeiten", entries: [
            .standard("Widerrufen", Selector(("undo:")), CommandShortcut("z")),
            .standard("Wiederholen", Selector(("redo:")), CommandShortcut("z", [.command, .shift])),
            .separator,
            .standard("Ausschneiden", #selector(NSText.cut(_:)), CommandShortcut("x")),
            .standard("Kopieren", #selector(NSText.copy(_:)), CommandShortcut("c")),
            .standard("Einsetzen", #selector(NSText.paste(_:)), CommandShortcut("v")),
            .standard("Alles auswählen", #selector(NSText.selectAll(_:)), CommandShortcut("a")),
            .separator,
            .command(.search),
        ]),
        Section(title: "Darstellung", entries: [
            .commandBar,
            .separator,
            .command(.toggleSidebar),
            .command(.toggleDetail),
            .separator,
            .standard("Vollbild", #selector(NSWindow.toggleFullScreen(_:)), CommandShortcut("f", [.command, .control])),
        ]),
        Section(title: "Repository", entries: [
            .command(.fetchAll),
            .family("fetch."),
            .command(.fetchTags),
            .separator,
            .command(.pull),
            .family("pull."),
            .ifPresent(.setUpstreamAndPull),
            .separator,
            .command(.push),
            .family("push.tags."),
            .separator,
            .command(.stash),
            .command(.stashWithMessage),
            .command(.stashStaged),
            .command(.pop),
            .separator,
            .command(.commit),
            .command(.amend),
            .command(.editMessage),
            .command(.stageAll),
            .command(.unstageAll),
            .command(.discardAll),
            .separator,
            .command(.openTerminal),
            .command(.chooseTerminal),
            .command(.openEditor),
            .command(.chooseEditor),
            .command(.revealInFinder),
            .separator,
            .command(.copyBranch),
            .command(.copyHead),
        ]),
        Section(title: "Branch", entries: [
            .command(.newBranch),
            .command(.checkout),
            .command(.switchWorktree),
            .separator,
            .command(.rebaseInteractive),
            .family("operation."),
        ]),
        Section(title: "Fenster", entries: [
            .standard("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), CommandShortcut("m")),
            .standard("Zoomen", #selector(NSWindow.performZoom(_:)), nil),
            .separator,
            .command(.nextTab),
            .command(.previousTab),
            .command(.switchTab),
            .separator,
            .standard("Alle nach vorne bringen", #selector(NSApplication.arrangeInFront(_:)), nil),
        ]),
        Section(title: "Hilfe", entries: []),
    ]

    /// Ids placed on their own somewhere; a family leaves them out.
    private static let placedIDs: Set<String> = Set(sections.flatMap(\.entries).compactMap { entry in
        switch entry {
        case .command(let spec), .ifPresent(let spec): spec.id
        default: nil
        }
    })

    private let commands: () -> [Command]
    private let recents: () -> [String]
    private weak var target: AnyObject?
    private let runAction: Selector
    private let commandBarAction: Selector
    private var menus: [ObjectIdentifier: Section] = [:]
    private let recentMenu = NSMenu(title: "Zuletzt verwendet")

    /// `target` receives `runAction` with the command id as the item's `representedObject`, and `commandBarAction`.
    init(target: AnyObject, runAction: Selector, commandBarAction: Selector, commands: @escaping () -> [Command], recents: @escaping () -> [String]) {
        self.target = target
        self.runAction = runAction
        self.commandBarAction = commandBarAction
        self.commands = commands
        self.recents = recents
        super.init()
        recentMenu.delegate = self
    }

    /// Builds the menu bar and hands the Services, Window and Help menus to AppKit.
    func install() {
        let bar = NSMenu()
        for section in Self.sections {
            let menu = NSMenu(title: section.title)
            menu.delegate = self
            menus[ObjectIdentifier(menu)] = section
            for item in items(for: section, commands: [:], order: []) { menu.addItem(item) }
            let holder = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            bar.addItem(holder)
            switch section.title {
            case "Fenster": NSApp.windowsMenu = menu
            case "Hilfe": NSApp.helpMenu = menu
            default: break
            }
        }
        NSApp.mainMenu = bar
    }

    // MARK: NSMenuDelegate

    /// A section with families is rebuilt, since its entries change with the remotes or the running operation; the others keep their items, so AppKit's window list and submenus stay, and only take the commands' current titles.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentMenu { return fillRecents() }
        guard let section = menus[ObjectIdentifier(menu)] else { return }
        let live = commands()
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if Self.isRebuilt(section) {
            menu.removeAllItems()
            for item in items(for: section, commands: byID, order: live.map(\.id)) { menu.addItem(item) }
            return
        }
        for item in menu.items {
            guard let id = item.representedObject as? String, let spec = Self.spec(id: id) else { continue }
            item.title = byID[id]?.title ?? spec.title
            item.toolTip = byID[id]?.disabledReason
        }
    }

    private static func isRebuilt(_ section: Section) -> Bool {
        section.entries.contains { entry in
            switch entry {
            case .family, .ifPresent: true
            default: false
            }
        }
    }

    private static func spec(id: String) -> CommandSpec? {
        for entry in sections.flatMap(\.entries) {
            if case .command(let spec) = entry, spec.id == id { return spec }
        }
        return nil
    }

    // MARK: Items

    private func items(for section: Section, commands: [String: Command], order: [String]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for entry in section.entries {
            switch entry {
            case .command(let spec):
                items.append(commands[spec.id].map(item(for:)) ?? item(title: spec.title, id: spec.id, shortcut: spec.shortcut))
            case .ifPresent(let spec):
                if let command = commands[spec.id] { items.append(item(for: command)) }
            case .family(let prefix):
                items += order.filter { $0.hasPrefix(prefix) && !Self.placedIDs.contains($0) }.compactMap { commands[$0] }.map(item(for:))
            case .standard(let title, let action, let shortcut):
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.key ?? "")
                entry.keyEquivalentModifierMask = shortcut?.modifiers ?? []
                items.append(entry)
            case .separator:
                items.append(.separator())
            case .recent:
                let holder = NSMenuItem(title: recentMenu.title, action: nil, keyEquivalent: "")
                holder.submenu = recentMenu
                items.append(holder)
            case .services:
                let services = NSMenu(title: "Dienste")
                NSApp.servicesMenu = services
                let holder = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
                holder.submenu = services
                items.append(holder)
            case .commandBar:
                let entry = NSMenuItem(title: "Befehlsleiste …", action: commandBarAction, keyEquivalent: CommandShortcut.commandBar.key)
                entry.keyEquivalentModifierMask = CommandShortcut.commandBar.modifiers
                entry.target = target
                items.append(entry)
            }
        }
        return Self.trimmedSeparators(items)
    }

    private func item(for command: Command) -> NSMenuItem {
        item(title: command.title, id: command.id, shortcut: command.shortcut, toolTip: command.disabledReason)
    }

    private func item(title: String, id: String, shortcut: CommandShortcut?, toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: runAction, keyEquivalent: shortcut?.key ?? "")
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        item.target = target
        item.representedObject = id
        item.toolTip = toolTip
        return item
    }

    /// The shortcut as the menu bar shows it. AppKit adapts key equivalents to the keyboard layout (⇧⌘] reads ⇧⌘Ä on a German keyboard), so the command bar asks the menu instead of drawing its own.
    static func displayedShortcut(of id: String) -> String? {
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? [] where item.representedObject as? String == id && !item.keyEquivalent.isEmpty {
                return CommandShortcut(item.keyEquivalent, item.keyEquivalentModifierMask).display
            }
        }
        return nil
    }

    /// No separator at either end or twice in a row, as happens when a family or an optional entry is empty.
    static func trimmedSeparators(_ items: [NSMenuItem]) -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        for item in items {
            if item.isSeparatorItem, result.last?.isSeparatorItem ?? true { continue }
            result.append(item)
        }
        while result.last?.isSeparatorItem == true { result.removeLast() }
        return result
    }

    private func fillRecents() {
        recentMenu.removeAllItems()
        let paths = recents()
        for path in paths {
            let item = NSMenuItem(title: (path as NSString).abbreviatingWithTildeInPath, action: #selector(MainWindowController.openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            recentMenu.addItem(item)
        }
        if paths.isEmpty {
            let empty = NSMenuItem(title: "Noch nichts geöffnet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        }
    }
}
