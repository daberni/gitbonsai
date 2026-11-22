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
        case choose(placeholder: String, @MainActor () -> [Command])
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

    var isEnabled: Bool { disabledReason == nil }

    init(id: String, title: String, keywords: [String] = [], glyph: CommandGlyph, shortcut: CommandShortcut? = nil, scope: Scope = .repository, context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: String? = nil, action: Action) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.glyph = glyph
        self.shortcut = shortcut
        self.scope = scope
        self.context = context
        self.disabledReason = disabledReason ?? blocker?.reason
        self.action = action
    }

    init(id: String, title: String, keywords: [String] = [], glyph: CommandGlyph, shortcut: CommandShortcut? = nil, scope: Scope = .repository, context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: String? = nil, run: @escaping @MainActor () -> Void) {
        self.init(id: id, title: title, keywords: keywords, glyph: glyph, shortcut: shortcut, scope: scope, context: context, blocker: blocker, disabledReason: disabledReason, action: .run(run))
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
    var reason: String {
        switch self {
        case .detachedHead: "Detached HEAD"
        case .noCommits: "Noch kein Commit"
        case .noRemote: "Kein Remote"
        case .noUpstream: "Kein Upstream"
        case .nothingStaged: "Nichts vorgemerkt"
        case .nothingToStage: "Nichts zu stagen"
        case .nothingToUnstage: "Nichts gestaged"
        case .noTrackedChanges: "Keine Änderungen an versionierten Dateien"
        case .noChanges: "Keine Änderungen"
        case .noStash: "Kein Stash"
        case .conflicts: "Offene Konflikte"
        case .operationInProgress(let kind): "\(kind.label) läuft"
        case .noOperation: "Nichts läuft"
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
