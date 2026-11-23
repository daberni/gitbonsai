import AppKit
import GitEngine

/// One entry of the command bar. Every action the bar offers is declared as a `Command` by the controller that owns it, through `CommandProvider`.
/// A command either runs at once or continues in the bar with a second list of commands, such as the branches to check out.
@MainActor
struct Command {
    enum Scope {
        /// Offered in every tab, the empty one included.
        case app
        /// Offered only in a repository tab.
        case repository
    }

    enum Action {
        case run(@MainActor () -> Void)
        /// Opens a second list in the bar; the closure builds its entries when the step opens.
        case choose(placeholder: LocalizedStringResource, @MainActor () -> [Command])
    }

    /// Stable across launches; recently used commands are remembered by it.
    let id: String
    let title: String
    var keywords: [String] = []
    var glyph: CommandGlyph
    var shortcut: CommandShortcut? = nil
    var scope: Scope = .repository
    /// Muted text after the title: the branch, remote or repository the command acts on.
    var context: String? = nil
    /// Why the command cannot run now; the bar shows it greyed out with this text instead of hiding it.
    var disabledReason: String? = nil
    let action: Action
    /// Set on the entries of "Go to Ref…": the bar ranks such a list by ref name and draws the name as a pill.
    var ref: RefEntry? = nil

    var isEnabled: Bool { disabledReason == nil }

    init(id: String, title: LocalizedStringResource, keywords: [String] = [], glyph: CommandGlyph, shortcut: CommandShortcut? = nil, scope: Scope = .repository, context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: LocalizedStringResource? = nil, action: Action) {
        self.id = id
        self.title = title.text
        self.keywords = keywords
        self.glyph = glyph
        self.shortcut = shortcut
        self.scope = scope
        self.context = context
        self.disabledReason = (disabledReason ?? blocker?.reason)?.text
        self.action = action
    }

    init(id: String, title: LocalizedStringResource, keywords: [String] = [], glyph: CommandGlyph, shortcut: CommandShortcut? = nil, scope: Scope = .repository, context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: LocalizedStringResource? = nil, run: @escaping @MainActor () -> Void) {
        self.init(id: id, title: title, keywords: keywords, glyph: glyph, shortcut: shortcut, scope: scope, context: context, blocker: blocker, disabledReason: disabledReason, action: .run(run))
    }
}

/// A ref listed by "Go to Ref…": ⏎ runs the command's action, ⌥⏎ the checkout, unless `checkoutBlocked` says why it cannot.
@MainActor
struct RefEntry {
    let target: RefJump.Target
    let pill: PillModel
    let strand: NSColor
    var checkoutBlocked: String? = nil
    let checkout: @MainActor () -> Void
}

extension Command {
    /// Splits a comma-separated list of search words from the catalog. The English words always count, so git's own terms find a command in every language; a translation adds its own words.
    static func searchWords(_ list: LocalizedStringResource) -> [String] {
        let english = list.key.split(separator: ",")
        let translated = list.text.split(separator: ",")
        var words: [String] = []
        for word in english + translated {
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !words.contains(trimmed) { words.append(trimmed) }
        }
        return words
    }
}

/// Anything that offers commands: the window for app-wide ones, a tab's controllers for repository ones.
@MainActor
protocol CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command]
}

/// What a command row draws before its title.
enum CommandGlyph {
    case glyph(Glyph)
    case symbol(String)
    /// An app's own icon, for editors and terminals.
    case app(URL)
}

/// A key equivalent of the main menu, shown on the right of a command row.
/// The menu and the bar read the same values, so a shortcut can only change in one place.
struct CommandShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌥⇧⌘S", in the order macOS menus draw the modifiers.
    var display: String {
        var text = ""
        // A key that needs shift to type, such as "}", carries it in the key itself.
        let shifted = modifiers.contains(.shift) || Self.shiftedKeys[key] != nil
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if shifted { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let names = ["\r": "↩", "\u{1b}": "⎋"]
        return text + (names[key] ?? Self.shiftedKeys[key] ?? key.uppercased())
    }

    private static let shiftedKeys = ["{": "[", "}": "]"]

    static let commandBar = CommandShortcut("p", [.command, .shift])
    static let settings = CommandShortcut(",")
    static let newTab = CommandShortcut("t")
    static let openRepository = CommandShortcut("o")
    /// ⇧⌘O as Open Quickly in Xcode; ⌘O stays Open Repository as in every document app.
    static let goToRef = CommandShortcut("o", [.command, .shift])
    static let clone = CommandShortcut("n", [.command, .option])
    static let closeTab = CommandShortcut("w")
    static let nextTab = CommandShortcut("}")
    static let previousTab = CommandShortcut("{")
    static let fetch = CommandShortcut("f", [.command, .shift])
    static let pull = CommandShortcut("l", [.command, .shift])
    static let push = CommandShortcut("u", [.command, .shift])
    static let newBranch = CommandShortcut("b")
    static let stash = CommandShortcut("s", [.command, .shift])
    static let pop = CommandShortcut("s", [.command, .shift, .option])
    static let search = CommandShortcut("f")
    /// The commit form takes ⌘⏎ itself while it shows; elsewhere the menu item brings the form up.
    static let commit = CommandShortcut("\r")
    /// The commit form amends with the typed message on ⇧⌘⏎; elsewhere the menu item opens the form in amend mode.
    static let amend = CommandShortcut("\r", [.command, .shift])
    /// Edits the selected commit's message in place in the detail panel.
    static let editMessage = CommandShortcut("e")
    /// ⌃⌘S as in Finder and Mail.
    static let toggleSidebar = CommandShortcut("s", [.command, .control])
    /// ⌥⌘I as the inspector in Finder and Pages; ⌥⌘D belongs to the Dock.
    static let toggleDetail = CommandShortcut("i", [.command, .option])
    static let openTerminal = CommandShortcut("t", [.command, .shift])
    static let openEditor = CommandShortcut("e", [.command, .shift])
    static let revealInFinder = CommandShortcut("r", [.command, .shift])
}

extension CommandBlocker {
    /// The short reason a disabled command shows, in the bar's muted text.
    var reason: LocalizedStringResource {
        switch self {
        case .detachedHead: LocalizedStringResource("common.detachedHead", defaultValue: "Detached HEAD", bundle: .module)
        case .noCommits: LocalizedStringResource("command.blocker.noCommits", defaultValue: "No commits yet", bundle: .module)
        case .noRemote: LocalizedStringResource("command.blocker.noRemote", defaultValue: "No remote", bundle: .module)
        case .noUpstream: LocalizedStringResource("command.blocker.noUpstream", defaultValue: "No upstream", bundle: .module)
        case .nothingStaged: LocalizedStringResource("command.blocker.nothingStaged", defaultValue: "Nothing staged", bundle: .module)
        case .nothingToStage: LocalizedStringResource("command.blocker.nothingToStage", defaultValue: "Nothing to stage", bundle: .module)
        case .nothingToUnstage: LocalizedStringResource("command.blocker.nothingToUnstage", defaultValue: "Nothing staged to unstage", bundle: .module)
        case .noTrackedChanges: LocalizedStringResource("command.blocker.noTrackedChanges", defaultValue: "No changes to tracked files", bundle: .module)
        case .noChanges: LocalizedStringResource("command.blocker.noChanges", defaultValue: "No changes", bundle: .module)
        case .noStash: LocalizedStringResource("command.blocker.noStash", defaultValue: "No stash", bundle: .module)
        case .conflicts: LocalizedStringResource("command.blocker.conflicts", defaultValue: "Unresolved conflicts", bundle: .module)
        case .operationInProgress(let kind): LocalizedStringResource("command.blocker.operationInProgress", defaultValue: "\(kind.label) in progress", bundle: .module)
        case .noOperation: LocalizedStringResource("command.blocker.noOperation", defaultValue: "Nothing in progress", bundle: .module)
        case .notFastForward: LocalizedStringResource("command.blocker.notFastForward", defaultValue: "Not a fast-forward", bundle: .module)
        case .upToDate: LocalizedStringResource("command.blocker.upToDate", defaultValue: "Already up to date", bundle: .module)
        case .checkedOut: LocalizedStringResource("checkout.command.checkedOut", defaultValue: "Checked out", bundle: .module)
        case .notCheckoutable: LocalizedStringResource("command.blocker.notCheckoutable", defaultValue: "Cannot be checked out", bundle: .module)
        }
    }
}

extension OperationProgress.Kind {
    var label: String {
        switch self {
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .merge: "Merge"
        }
    }
}
