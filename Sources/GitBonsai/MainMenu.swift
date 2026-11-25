import AppKit

/// The menu bar, generated from the command registry: every git and window action is a `CommandSpec` and runs the same `Command` as the command bar, with the same shortcut and enabled state.
/// Only what AppKit itself implements (text editing, Hide, Services, Minimize, Full Screen) stays a plain selector. AppKit asks for an update before it opens a menu and before it matches a key equivalent; enabling goes through the target's `validateMenuItem`.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate {
    enum Entry {
        /// Always listed; disabled from its spec while the tab offers no such command, as in the empty tab.
        case command(CommandSpec)
        /// Every command whose id starts with the prefix and is not placed on its own elsewhere: per remote, per pull mode, the running operation.
        case family(String)
        /// An action AppKit implements, sent along the responder chain.
        case standard(LocalizedStringResource, Selector, CommandShortcut?)
        case separator
        case recent
        case services
        case commandBar
    }

    struct Section {
        /// The menus AppKit fills itself: the window list and the help search.
        enum Role {
            case plain, window, help
        }

        let title: LocalizedStringResource
        var role: Role = .plain
        let entries: [Entry]
    }

    static let sections: [Section] = [
        Section(title: .verbatim("GitBonsai"), entries: [
            .standard(LocalizedStringResource("menu.app.about", defaultValue: "About GitBonsai", bundle: .module), #selector(AppDelegate.showAbout(_:)), nil),
            .separator,
            .command(.settings),
            .separator,
            .services,
            .separator,
            .standard(LocalizedStringResource("menu.app.hide", defaultValue: "Hide GitBonsai", bundle: .module), #selector(NSApplication.hide(_:)), CommandShortcut("h")),
            .standard(LocalizedStringResource("menu.app.hideOthers", defaultValue: "Hide Others", bundle: .module), #selector(NSApplication.hideOtherApplications(_:)), CommandShortcut("h", [.command, .option])),
            .standard(LocalizedStringResource("menu.app.showAll", defaultValue: "Show All", bundle: .module), #selector(NSApplication.unhideAllApplications(_:)), nil),
            .separator,
            .standard(LocalizedStringResource("menu.app.quit", defaultValue: "Quit GitBonsai", bundle: .module), #selector(NSApplication.terminate(_:)), CommandShortcut("q")),
        ]),
        Section(title: LocalizedStringResource("menu.file.title", defaultValue: "File", bundle: .module, comment: "The File menu."), entries: [
            .command(.newTab),
            .command(.openRepository),
            .command(.clone),
            .recent,
            .separator,
            .command(.closeTab),
            .standard(LocalizedStringResource("menu.file.closeWindow", defaultValue: "Close Window", bundle: .module), #selector(NSWindow.performClose(_:)), CommandShortcut("w", [.command, .shift])),
        ]),
        Section(title: LocalizedStringResource("menu.edit.title", defaultValue: "Edit", bundle: .module), entries: [
            .standard(LocalizedStringResource("menu.edit.undo", defaultValue: "Undo", bundle: .module), Selector(("undo:")), CommandShortcut("z")),
            .standard(LocalizedStringResource("menu.edit.redo", defaultValue: "Redo", bundle: .module), Selector(("redo:")), CommandShortcut("z", [.command, .shift])),
            .separator,
            .standard(LocalizedStringResource("menu.edit.cut", defaultValue: "Cut", bundle: .module), #selector(NSText.cut(_:)), CommandShortcut("x")),
            .standard(LocalizedStringResource("menu.edit.copy", defaultValue: "Copy", bundle: .module), #selector(NSText.copy(_:)), CommandShortcut("c")),
            .standard(LocalizedStringResource("menu.edit.paste", defaultValue: "Paste", bundle: .module), #selector(NSText.paste(_:)), CommandShortcut("v")),
            .standard(LocalizedStringResource("menu.edit.selectAll", defaultValue: "Select All", bundle: .module), #selector(NSText.selectAll(_:)), CommandShortcut("a")),
            .separator,
            .command(.search),
        ]),
        Section(title: LocalizedStringResource("menu.view.title", defaultValue: "View", bundle: .module, comment: "The View menu."), entries: [
            .commandBar,
            .command(.goToRef),
            .command(.goToParent),
            .command(.goToChild),
            .separator,
            .command(.toggleSidebar),
            .command(.toggleDetail),
            .separator,
            .standard(LocalizedStringResource("menu.view.enterFullScreen", defaultValue: "Enter Full Screen", bundle: .module), #selector(NSWindow.toggleFullScreen(_:)), CommandShortcut("f", [.command, .control])),
        ]),
        Section(title: LocalizedStringResource("menu.repository.title", defaultValue: "Repository", bundle: .module, comment: "The Repository menu."), entries: [
            .command(.fetchAll),
            .family("fetch."),
            .command(.fetchTags),
            .separator,
            .command(.pull),
            .family("pull."),
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
            .command(.commitAll),
            .command(.amend),
            .command(.editMessage),
            .command(.squash),
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
        Section(title: LocalizedStringResource("menu.branch.title", defaultValue: "Branch", bundle: .module, comment: "The Branch menu."), entries: [
            .command(.newBranch),
            .command(.checkout),
            .command(.switchWorktree),
            .separator,
            .command(.fastForward),
            .command(.rebaseInteractive),
            .family("operation."),
            .family("conflict."),
        ]),
        Section(title: LocalizedStringResource("menu.window.title", defaultValue: "Window", bundle: .module), role: .window, entries: [
            .standard(LocalizedStringResource("menu.window.minimize", defaultValue: "Minimize", bundle: .module), #selector(NSWindow.performMiniaturize(_:)), CommandShortcut("m")),
            .standard(LocalizedStringResource("menu.window.zoom", defaultValue: "Zoom", bundle: .module), #selector(NSWindow.performZoom(_:)), nil),
            .separator,
            .command(.nextTab),
            .command(.previousTab),
            .command(.switchTab),
            .separator,
            .standard(LocalizedStringResource("menu.window.bringAllToFront", defaultValue: "Bring All to Front", bundle: .module), #selector(NSApplication.arrangeInFront(_:)), nil),
        ]),
        Section(title: LocalizedStringResource("menu.help.title", defaultValue: "Help", bundle: .module), role: .help, entries: []),
    ]

    /// Ids placed on their own somewhere; a family leaves them out.
    private static let placedIDs: Set<String> = Set(sections.flatMap(\.entries).compactMap { entry in
        switch entry {
        case .command(let spec): spec.id
        default: nil
        }
    })

    private let commands: () -> [Command]
    private let recents: () -> [String]
    private weak var target: AnyObject?
    private let runAction: Selector
    private let commandBarAction: Selector
    private let openRecentAction: Selector
    private var menus: [ObjectIdentifier: Section] = [:]
    private let recentMenu = NSMenu(title: String(localized: "menu.file.openRecent", defaultValue: "Open Recent", bundle: .module))

    /// `target` receives `runAction` with the command id as the item's `representedObject`, `commandBarAction`, and `openRecentAction` with the path as `representedObject`.
    init(target: AnyObject, runAction: Selector, commandBarAction: Selector, openRecentAction: Selector, commands: @escaping () -> [Command], recents: @escaping () -> [String]) {
        self.target = target
        self.openRecentAction = openRecentAction
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
            let title = section.title.text
            let menu = NSMenu(title: title)
            menu.delegate = self
            menus[ObjectIdentifier(menu)] = section
            for item in items(for: section, commands: [:], order: []) { menu.addItem(item) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            bar.addItem(holder)
            switch section.role {
            case .window: NSApp.windowsMenu = menu
            case .help: NSApp.helpMenu = menu
            case .plain: break
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
            item.title = byID[id]?.title ?? spec.title.text
            item.toolTip = byID[id]?.disabledReason
        }
    }

    private static func isRebuilt(_ section: Section) -> Bool {
        section.entries.contains { entry in
            switch entry {
            case .family: true
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

    // MARK: Entries

    /// A section's entries as data, in groups between its separators: commands with the tab's current titles, shortcuts and disabled reasons; families only as far as the tab offers them.
    static func groups(for section: Section, commands: [String: Command], order: [String]) -> [[MenuEntry]] {
        var groups: [[MenuEntry]] = [[]]
        func add(_ entry: MenuEntry) { groups[groups.count - 1].append(entry) }
        for entry in section.entries {
            switch entry {
            case .command(let spec):
                add(commands[spec.id].map(Self.entry(for:)) ?? Self.entry(title: spec.title.text, id: spec.id, shortcut: spec.shortcut))
            case .family(let prefix):
                order.filter { $0.hasPrefix(prefix) && !Self.placedIDs.contains($0) }.compactMap { commands[$0] }.forEach { add(Self.entry(for: $0)) }
            case .standard(let title, let action, let shortcut):
                var item = MenuEntry(RefString(title), content: .selector(action))
                item.shortcut = shortcut
                add(item)
            case .separator:
                groups.append([])
            case .recent:
                add(MenuEntry(RefString(verbatim: String(localized: "menu.file.openRecent", defaultValue: "Open Recent", bundle: .module)), content: .system(.recent)))
            case .services:
                add(MenuEntry(RefString(verbatim: String(localized: "menu.app.services", defaultValue: "Services", bundle: .module, comment: "The Services submenu of the app menu.")), content: .system(.services)))
            case .commandBar:
                var item = MenuEntry(RefString(verbatim: String(localized: "menu.view.commandBar", defaultValue: "Command bar…", bundle: .module)), content: .system(.commandBar))
                item.shortcut = .commandBar
                add(item)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    private static func entry(for command: Command) -> MenuEntry {
        var item = entry(title: command.title, id: command.id, shortcut: command.shortcut)
        item.disabledReason = command.disabledReason
        return item
    }

    private static func entry(title: String, id: String, shortcut: CommandShortcut?) -> MenuEntry {
        var item = MenuEntry(RefString(verbatim: title), content: .command(id))
        item.shortcut = shortcut
        return item
    }

    // MARK: Items

    /// Commands go to `target`, which enables them in `validateMenuItem`; AppKit's own entries go along the responder chain.
    private func items(for section: Section, commands: [String: Command], order: [String]) -> [NSMenuItem] {
        Self.groups(for: section, commands: commands, order: order).enumerated().flatMap { offset, group in (offset > 0 ? [NSMenuItem.separator()] : []) + group.map(item(for:)) }
    }

    private func item(for entry: MenuEntry) -> NSMenuItem {
        let item: NSMenuItem
        switch entry.content {
        case .command(let id):
            item = NSMenuItem(title: entry.title.plain, action: runAction, keyEquivalent: "")
            item.target = target
            item.representedObject = id
            item.toolTip = entry.disabledReason
        case .selector(let action):
            item = NSMenuItem(title: entry.title.plain, action: action, keyEquivalent: "")
        case .system(.recent):
            item = NSMenuItem(title: recentMenu.title, action: nil, keyEquivalent: "")
            item.submenu = recentMenu
        case .system(.services):
            let services = NSMenu(title: entry.title.plain)
            NSApp.servicesMenu = services
            item = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
            item.submenu = services
        case .system(.commandBar):
            item = NSMenuItem(title: entry.title.plain, action: commandBarAction, keyEquivalent: "")
            item.target = target
        case .action, .submenu, .header:
            return MenuAdapter.item(entry)
        }
        item.keyEquivalent = entry.shortcut?.key ?? ""
        item.keyEquivalentModifierMask = entry.shortcut?.modifiers ?? []
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

    private func fillRecents() {
        recentMenu.removeAllItems()
        let paths = recents()
        for path in paths {
            let item = NSMenuItem(title: (path as NSString).abbreviatingWithTildeInPath, action: openRecentAction, keyEquivalent: "")
            item.target = target
            item.representedObject = path
            recentMenu.addItem(item)
        }
        if paths.isEmpty {
            let empty = NSMenuItem(title: String(localized: "menu.file.noRecents", defaultValue: "Nothing opened yet", bundle: .module, comment: "The empty Open Recent menu."), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        }
    }
}
