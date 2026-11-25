import AppKit

/// One entry of a context menu as data: what it says, whether and why it is disabled, and what it runs or opens. `MenuAdapter` turns entries into `NSMenuItem`s; tests read them directly.
struct MenuEntry {
    enum Content {
        case action(@MainActor () -> Void)
        case submenu([[MenuEntry]])
        /// A disabled line that names what the menu is about.
        case header
        /// A menu bar entry that runs the command of that id; the menu bar enables it from the tab's commands.
        case command(String)
        /// A menu bar entry AppKit implements, sent along the responder chain.
        case selector(Selector)
        /// A menu bar entry AppKit or the window fills: Open Recent, Services, the command bar.
        case system(SystemEntry)
    }

    enum SystemEntry: Equatable {
        case recent, services, commandBar
    }

    var title: RefString
    /// Shown after the title as a pill, such as "Default".
    var marker: String?
    var toolTip: String?
    /// Why the entry cannot run now; a disabled entry shows it as its tooltip.
    var disabledReason: String?
    var shortcut: CommandShortcut?
    /// Shows a checkmark, as an option that is on.
    var isChecked = false
    /// Replaces the entry before it while these modifier keys are held, as "Copy full path" for "Copy path" with ⌥.
    var alternateModifiers: NSEvent.ModifierFlags?
    /// The entry moves HEAD or rewrites history, so it waits while git is in the middle of a merge, rebase, cherry-pick or revert; see `CommandRules.movingHead`.
    var movesHead = false
    var content: Content

    init(_ title: LocalizedStringResource, action: @escaping @MainActor () -> Void) {
        self.init(RefString(title), action: action)
    }

    init(_ title: RefString, action: @escaping @MainActor () -> Void) {
        self.title = title
        content = .action(action)
    }

    init(_ title: RefString, submenu groups: [[MenuEntry]]) {
        self.title = title
        content = .submenu(groups)
    }

    init(_ title: LocalizedStringResource, submenu groups: [[MenuEntry]]) {
        self.init(RefString(title), submenu: groups)
    }

    init(_ title: RefString, content: Content) {
        self.title = title
        self.content = content
    }

    static func header(_ title: LocalizedStringResource) -> MenuEntry {
        var entry = MenuEntry(RefString(title), submenu: [])
        entry.content = .header
        return entry
    }

    /// An entry that shows why it cannot run, or runs `action` when `reason` is nil.
    static func action(_ title: LocalizedStringResource, disabledBecause reason: String?, action: @escaping @MainActor () -> Void) -> MenuEntry {
        var entry = MenuEntry(title, action: action)
        entry.disabledReason = reason
        return entry
    }

    var isEnabled: Bool {
        if case .header = content { return false }
        return disabledReason == nil
    }

    /// The title as a person reads it, without the pills' marks; what tests match entries by.
    var plainTitle: String { title.plain }

    /// The same entry, marked as one that moves HEAD or rewrites history.
    var movingHead: MenuEntry {
        var entry = self
        entry.movesHead = true
        return entry
    }

    /// Disables every entry that moves HEAD, in submenus too, with `reason` as its tooltip.
    static func blockingHeadMoves(_ groups: [[MenuEntry]], because reason: String?) -> [[MenuEntry]] {
        guard let reason else { return groups }
        return groups.map { group in
            group.map { entry in
                var entry = entry
                if case .submenu(let inner) = entry.content { entry.content = .submenu(blockingHeadMoves(inner, because: reason)) }
                if entry.movesHead, entry.disabledReason == nil { entry.disabledReason = reason }
                return entry
            }
        }
    }

    var submenu: [[MenuEntry]]? {
        if case .submenu(let groups) = content { groups } else { nil }
    }
}

/// Where a context menu opens. It decides what a subject's menu leaves to its neighbours: in the history the commit section offers Copy SHA, Create Worktree… and the detached checkout.
enum MenuContext: Equatable {
    case sidebar
    /// The menu of one ref pill of a history row.
    case historyPill
    /// The menu of a whole history row; `refs` are the pills it shows.
    case historyRow(refs: [PillRef])

    var isHistory: Bool { self != .sidebar }
}

/// The groups every ref and commit menu shares, in the order they show. Ref and commit sections fill the same groups, so a combined menu zips them by meaning instead of stacking one section above the other.
struct MenuSections {
    /// Other refs of the row, each as a pill submenu; they lead the menu.
    var refs: [MenuEntry] = []
    /// Checkout, Switch to Worktree, Checkout Commit (detached).
    var goThere: [MenuEntry] = []
    /// Pull, Push, Push Tag.
    var sync: [MenuEntry] = []
    /// Moves or changes the current branch: Fast-Forward, Merge, Rebase, Cherry-Pick, Reset, Revert.
    var integrate: [MenuEntry] = []
    /// Delete, Delete Branches…, Drop Commit.
    var remove: [MenuEntry] = []
    /// Branch, Worktree, Tag.
    var create: [MenuEntry] = []
    /// Rename, Upstream, Edit Message, Move up/down.
    var change: [MenuEntry] = []
    /// Copy name, Copy SHA, Save Patch.
    var copy: [MenuEntry] = []

    var groups: [[MenuEntry]] { [refs, goThere, sync, integrate, remove, create, change, copy] }

    var isEmpty: Bool { groups.allSatisfy(\.isEmpty) }

    static func + (lhs: MenuSections, rhs: MenuSections) -> MenuSections {
        MenuSections(refs: lhs.refs + rhs.refs, goThere: lhs.goThere + rhs.goThere, sync: lhs.sync + rhs.sync, integrate: lhs.integrate + rhs.integrate, remove: lhs.remove + rhs.remove, create: lhs.create + rhs.create, change: lhs.change + rhs.change, copy: lhs.copy + rhs.copy)
    }
}

/// Turns menu data into `NSMenuItem`s: non-empty groups with a separator between neighbours.
@MainActor
enum MenuAdapter {
    static func items(_ groups: [[MenuEntry]]) -> [NSMenuItem] {
        groups.filter { !$0.isEmpty }.enumerated().flatMap { offset, group in (offset > 0 ? [NSMenuItem.separator()] : []) + group.map(item) }.pairingAlternates()
    }

    /// A menu that keeps the entries' own enabled state instead of asking targets.
    static func menu(_ groups: [[MenuEntry]]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items(groups).forEach(menu.addItem)
        return menu
    }

    static func item(_ entry: MenuEntry) -> NSMenuItem {
        let item: NSMenuItem
        switch entry.content {
        case .action(let action):
            item = entry.isEnabled ? ActionMenuItem(entry.title, handler: action) : NSMenuItem(title: entry.title.plain, action: nil, keyEquivalent: "")
        case .submenu(let groups):
            item = NSMenuItem(title: entry.title.plain, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            items(groups).forEach(submenu.addItem)
            item.submenu = submenu
        case .header, .command, .selector, .system:
            // Menu bar entries need the menu bar's target; `MainMenu` makes those.
            item = NSMenuItem(title: entry.title.plain, action: nil, keyEquivalent: "")
        }
        if let marker = entry.marker { item.setTitle(entry.title, marker: marker) } else { item.setTitle(entry.title) }
        item.isEnabled = entry.isEnabled
        item.toolTip = entry.disabledReason ?? entry.toolTip
        if let shortcut = entry.shortcut {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        if entry.isChecked { item.state = .on }
        if let modifiers = entry.alternateModifiers {
            item.keyEquivalentModifierMask = modifiers
            item.isAlternate = true
        }
        return item
    }
}

/// "Copy <SHA>", copying the full SHA.
extension MenuEntry {
    @MainActor static func copySHA(_ sha: String, to pasteboard: Pasteboard) -> MenuEntry {
        MenuEntry(LocalizedStringResource("commit.menu.copySHA", defaultValue: "Copy \(RefName.commit(sha))", bundle: .module)) { pasteboard.copy(sha) }
    }
}

private extension Array where Element == NSMenuItem {
    /// AppKit pairs an alternate with the item before it only when that item's modifiers differ, so the plain one gets none.
    func pairingAlternates() -> [NSMenuItem] {
        for (index, item) in enumerated() where item.isAlternate && index > 0 {
            self[index - 1].keyEquivalentModifierMask = []
        }
        return self
    }
}
