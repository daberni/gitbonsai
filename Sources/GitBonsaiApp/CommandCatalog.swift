import AppKit
import GitEngine

/// What a command is, independent of a tab's state: id, title, search words, glyph and shortcut.
/// The command bar and the main menu both read these, so a title or shortcut changes in one place; the providers add context, enabled state and the action.
/// Commands that exist once per remote, branch or tab are built by their provider directly and listed in the menu as a family by id prefix.
struct CommandSpec {
    let id: String
    let title: LocalizedStringResource
    /// Comma-separated search words; see `Command.searchWords`.
    var keywords: LocalizedStringResource? = nil
    let glyph: CommandGlyph
    var shortcut: CommandShortcut? = nil
    var scope: Command.Scope = .repository
}

@MainActor
extension CommandSpec {
    // MARK: Remotes

    static let fetchAll = CommandSpec(id: "fetch", title: "Fetch all Remotes", keywords: "fetch, download, update", glyph: .symbol("arrow.down.circle"), shortcut: .fetch)
    static let fetchTags = CommandSpec(id: "fetch.tags", title: "Fetch Tags from all Remotes", keywords: "fetch, download, update", glyph: .glyph(.tag))
    static let pull = CommandSpec(id: "pull", title: "Pull", keywords: "pull, update, download", glyph: .symbol("arrow.down"), shortcut: .pull)
    static let setUpstreamAndPull = CommandSpec(id: "pull.set-upstream", title: "Set Upstream and Pull…", keywords: "pull, upstream, track", glyph: .symbol("arrow.down"))
    static let push = CommandSpec(id: "push", title: "Push", keywords: "push, upload, publish", glyph: .symbol("arrow.up"), shortcut: .push)

    // MARK: Branches

    static let newBranch = CommandSpec(id: "branch.new", title: "New Branch…", keywords: "branch, create, new", glyph: .glyph(.branch), shortcut: .newBranch)
    static let checkout = CommandSpec(id: "checkout", title: "Checkout Branch…", keywords: "checkout, switch", glyph: .glyph(.branch))
    static let rebaseInteractive = CommandSpec(id: "rebase.interactive", title: "Interactive Rebase…", keywords: "rebase -i, squash, reword, fixup, drop", glyph: .symbol("list.bullet.indent"))
    static let switchWorktree = CommandSpec(id: "worktree.switch", title: "Switch Worktree…", keywords: "worktree, switch", glyph: .glyph(.bonsaiLinked))

    // MARK: Working directory

    static let stash = CommandSpec(id: "stash", title: "Stash changes", keywords: "stash push, changes, save", glyph: .glyph(.stashBowl), shortcut: .stash)
    static let stashWithMessage = CommandSpec(id: "stash.message", title: "Stash with Message…", keywords: "stash push, changes, message", glyph: .glyph(.stashBowl))
    static let stashStaged = CommandSpec(id: "stash.staged", title: "Stash staged changes only", keywords: "stash push, staged, index", glyph: .glyph(.stashBowl))
    static let pop = CommandSpec(id: "stash.pop", title: "Pop Stash", keywords: "pop, stash apply, restore", glyph: .glyph(.stashBowl), shortcut: .pop)
    static let commit = CommandSpec(id: "commit", title: "Commit…", keywords: "commit, save, record", glyph: .glyph(.staged), shortcut: .commit)
    static let amend = CommandSpec(id: "commit.amend", title: "Amend last Commit…", keywords: "amend, fix, last commit", glyph: .glyph(.pencil))
    static let editMessage = CommandSpec(id: "commit.reword", title: "Edit Commit Message", keywords: "reword, message, edit", glyph: .glyph(.pencil), shortcut: .editMessage)
    static let stageAll = CommandSpec(id: "stage.all", title: "Stage all changes", keywords: "add, stage, index", glyph: .glyph(.plus))
    static let unstageAll = CommandSpec(id: "unstage.all", title: "Unstage all changes", keywords: "restore, unstage, index", glyph: .glyph(.minus))
    static let discardAll = CommandSpec(id: "discard.all", title: "Discard all changes…", keywords: "discard, restore, reset", glyph: .glyph(.trash))

    // MARK: Elsewhere and clipboard

    static let search = CommandSpec(id: "search", title: "Search Commits", keywords: "find, filter", glyph: .symbol("magnifyingglass"), shortcut: .search)
    static let openTerminal = CommandSpec(id: "open.terminal", title: "Open in terminal", keywords: "shell, console", glyph: .symbol("apple.terminal"), shortcut: .openTerminal)
    static let chooseTerminal = CommandSpec(id: "open.terminal.choose", title: "Open in terminal with…", keywords: "shell, console", glyph: .symbol("apple.terminal"))
    static let openEditor = CommandSpec(id: "open.editor", title: "Open in editor", keywords: "code, ide", glyph: .symbol("chevron.left.forwardslash.chevron.right"), shortcut: .openEditor)
    static let chooseEditor = CommandSpec(id: "open.editor.choose", title: "Open in editor with…", keywords: "code, ide", glyph: .symbol("chevron.left.forwardslash.chevron.right"))
    static let revealInFinder = CommandSpec(id: "open.finder", title: "Show in Finder", keywords: "reveal, folder", glyph: .symbol("folder"), shortcut: .revealInFinder)
    static let copyBranch = CommandSpec(id: "copy.branch", title: "Copy Branch name", keywords: "copy, name, clipboard", glyph: .symbol("doc.on.doc"))
    static let copyHead = CommandSpec(id: "copy.head", title: "Copy HEAD SHA", keywords: "copy, sha, hash, clipboard", glyph: .symbol("doc.on.doc"))

    // MARK: View

    static let toggleSidebar = CommandSpec(id: "view.sidebar", title: "Hide sidebar", keywords: "sidebar, show, hide", glyph: .symbol("sidebar.left"), shortcut: .toggleSidebar)
    static let toggleDetail = CommandSpec(id: "view.detail", title: "Hide detail panel", keywords: "inspector, detail, show, hide", glyph: .symbol("sidebar.right"), shortcut: .toggleDetail)

    // MARK: Window and app

    static let newTab = CommandSpec(id: "tab.new", title: "New tab", keywords: "tab, new", glyph: .glyph(.plus), shortcut: .newTab, scope: .app)
    static let openRepository = CommandSpec(id: "repository.open", title: "Open Repository…", keywords: "open, folder", glyph: .symbol("folder"), shortcut: .openRepository, scope: .app)
    static let clone = CommandSpec(id: "repository.clone", title: "Clone Repository…", keywords: "clone, download", glyph: .glyph(.cloud), shortcut: .clone, scope: .app)
    static let closeTab = CommandSpec(id: "tab.close", title: "Close tab", keywords: "tab, close", glyph: .glyph(.xmark), shortcut: .closeTab, scope: .app)
    static let nextTab = CommandSpec(id: "tab.next", title: "Next tab", keywords: "tab, next", glyph: .glyph(.chevronRight), shortcut: .nextTab, scope: .app)
    static let previousTab = CommandSpec(id: "tab.previous", title: "Previous tab", keywords: "tab, previous", glyph: .symbol("chevron.left"), shortcut: .previousTab, scope: .app)
    static let switchTab = CommandSpec(id: "tab.switch", title: "Switch to tab…", keywords: "tab, repository", glyph: .symbol("square.on.square"), scope: .app)
    static let settings = CommandSpec(id: "settings", title: "Settings…", keywords: "settings, preferences, editor, terminal", glyph: .symbol("gearshape"), shortcut: .settings, scope: .app)
}

extension Command {
    /// `keywords` add search words that depend on the state, such as the name of the default editor; `title` replaces the spec's for a toggle that names its next state.
    init(_ spec: CommandSpec, title: LocalizedStringResource? = nil, keywords: [String] = [], context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: LocalizedStringResource? = nil, action: Action) {
        self.init(id: spec.id, title: title ?? spec.title, keywords: (spec.keywords.map(Command.searchWords) ?? []) + keywords, glyph: spec.glyph, shortcut: spec.shortcut, scope: spec.scope, context: context, blocker: blocker, disabledReason: disabledReason, action: action)
    }

    init(_ spec: CommandSpec, title: LocalizedStringResource? = nil, keywords: [String] = [], context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: LocalizedStringResource? = nil, run: @escaping @MainActor () -> Void) {
        self.init(spec, title: title, keywords: keywords, context: context, blocker: blocker, disabledReason: disabledReason, action: .run(run))
    }
}
