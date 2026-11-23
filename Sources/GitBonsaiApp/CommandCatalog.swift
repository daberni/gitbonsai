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

    static let fetchAll = CommandSpec(id: "fetch", title: LocalizedStringResource("fetch.action.all", defaultValue: "Fetch all Remotes", bundle: .module), keywords: LocalizedStringResource("command.fetch.keywords", defaultValue: "fetch, download, update", bundle: .module), glyph: .symbol("arrow.down.circle"), shortcut: .fetch)
    static let fetchTags = CommandSpec(id: "fetch.tags", title: LocalizedStringResource("fetch.action.tags", defaultValue: "Fetch Tags from all Remotes", bundle: .module), keywords: LocalizedStringResource("command.fetch.keywords", defaultValue: "fetch, download, update", bundle: .module), glyph: .glyph(.tag))
    static let pull = CommandSpec(id: "pull", title: LocalizedStringResource("command.pull.title", defaultValue: "Pull", bundle: .module), keywords: LocalizedStringResource("command.pull.keywords", defaultValue: "pull, update, download", bundle: .module), glyph: .symbol("arrow.down"), shortcut: .pull)
    static let setUpstreamAndPull = CommandSpec(id: "pull.set-upstream", title: LocalizedStringResource("pull.action.setUpstreamAndPull", defaultValue: "Set Upstream and Pull…", bundle: .module), keywords: LocalizedStringResource("command.setUpstreamAndPull.keywords", defaultValue: "pull, upstream, track", bundle: .module), glyph: .symbol("arrow.down"))
    static let push = CommandSpec(id: "push", title: LocalizedStringResource("command.push.title", defaultValue: "Push", bundle: .module), keywords: LocalizedStringResource("command.push.keywords", defaultValue: "push, upload, publish", bundle: .module), glyph: .symbol("arrow.up"), shortcut: .push)

    // MARK: Branches

    static let newBranch = CommandSpec(id: "branch.new", title: LocalizedStringResource("command.newBranch.title", defaultValue: "New Branch…", bundle: .module), keywords: LocalizedStringResource("command.newBranch.keywords", defaultValue: "branch, create, new", bundle: .module), glyph: .glyph(.branch), shortcut: .newBranch)
    static let checkout = CommandSpec(id: "checkout", title: LocalizedStringResource("command.checkout.title", defaultValue: "Checkout Branch…", bundle: .module), keywords: LocalizedStringResource("command.checkout.keywords", defaultValue: "checkout, switch", bundle: .module), glyph: .glyph(.branch))
    static let fastForward = CommandSpec(id: "fast-forward", title: LocalizedStringResource("command.fastForward.title", defaultValue: "Fast-Forward to Branch…", bundle: .module), keywords: LocalizedStringResource("command.fastForward.keywords", defaultValue: "fast-forward, ff-only, merge, update", bundle: .module), glyph: .symbol("forward"))
    static let rebaseInteractive = CommandSpec(id: "rebase.interactive", title: LocalizedStringResource("command.rebaseInteractive.title", defaultValue: "Interactive Rebase…", bundle: .module), keywords: LocalizedStringResource("command.rebaseInteractive.keywords", defaultValue: "rebase -i, squash, reword, fixup, drop", bundle: .module), glyph: .symbol("list.bullet.indent"))
    static let goToRef = CommandSpec(id: "ref.goTo", title: LocalizedStringResource("command.goToRef.title", defaultValue: "Go to Ref…", bundle: .module), keywords: LocalizedStringResource("command.goToRef.keywords", defaultValue: "jump, find, branch, tag, worktree, stash, open quickly", bundle: .module), glyph: .symbol("arrow.right.circle"), shortcut: .goToRef)
    static let switchWorktree = CommandSpec(id: "worktree.switch", title: LocalizedStringResource("command.switchWorktree.title", defaultValue: "Switch Worktree…", bundle: .module), keywords: LocalizedStringResource("command.switchWorktree.keywords", defaultValue: "worktree, switch", bundle: .module), glyph: .glyph(.bonsaiLinked))

    // MARK: Working directory

    static let stash = CommandSpec(id: "stash", title: LocalizedStringResource("stash.action.stashChanges", defaultValue: "Stash changes", bundle: .module), keywords: LocalizedStringResource("command.stash.keywords", defaultValue: "stash push, changes, save", bundle: .module), glyph: .glyph(.stashBowl), shortcut: .stash)
    static let stashWithMessage = CommandSpec(id: "stash.message", title: LocalizedStringResource("stash.action.withMessage", defaultValue: "Stash with Message…", bundle: .module), keywords: LocalizedStringResource("command.stashWithMessage.keywords", defaultValue: "stash push, changes, message", bundle: .module), glyph: .glyph(.stashBowl))
    static let stashStaged = CommandSpec(id: "stash.staged", title: LocalizedStringResource("stash.action.stagedOnly", defaultValue: "Stash staged changes only", bundle: .module), keywords: LocalizedStringResource("command.stashStaged.keywords", defaultValue: "stash push, staged, index", bundle: .module), glyph: .glyph(.stashBowl))
    static let pop = CommandSpec(id: "stash.pop", title: LocalizedStringResource("command.pop.title", defaultValue: "Pop Stash", bundle: .module), keywords: LocalizedStringResource("command.pop.keywords", defaultValue: "pop, stash apply, restore", bundle: .module), glyph: .glyph(.stashBowl), shortcut: .pop)
    static let commit = CommandSpec(id: "commit", title: LocalizedStringResource("command.commit.title", defaultValue: "Commit…", bundle: .module), keywords: LocalizedStringResource("command.commit.keywords", defaultValue: "commit, save, record", bundle: .module), glyph: .glyph(.staged), shortcut: .commit)
    static let amend = CommandSpec(id: "commit.amend", title: LocalizedStringResource("command.amend.title", defaultValue: "Amend last Commit…", bundle: .module), keywords: LocalizedStringResource("command.amend.keywords", defaultValue: "amend, fix, last commit", bundle: .module), glyph: .glyph(.pencil))
    static let editMessage = CommandSpec(id: "commit.reword", title: LocalizedStringResource("command.editMessage.title", defaultValue: "Edit Commit Message", bundle: .module), keywords: LocalizedStringResource("command.editMessage.keywords", defaultValue: "reword, message, edit", bundle: .module), glyph: .glyph(.pencil), shortcut: .editMessage)
    static let stageAll = CommandSpec(id: "stage.all", title: LocalizedStringResource("command.stageAll.title", defaultValue: "Stage all changes", bundle: .module), keywords: LocalizedStringResource("command.stageAll.keywords", defaultValue: "add, stage, index", bundle: .module), glyph: .glyph(.plus))
    static let unstageAll = CommandSpec(id: "unstage.all", title: LocalizedStringResource("command.unstageAll.title", defaultValue: "Unstage all changes", bundle: .module), keywords: LocalizedStringResource("command.unstageAll.keywords", defaultValue: "restore, unstage, index", bundle: .module), glyph: .glyph(.minus))
    static let discardAll = CommandSpec(id: "discard.all", title: LocalizedStringResource("command.discardAll.title", defaultValue: "Discard all changes…", bundle: .module), keywords: LocalizedStringResource("command.discardAll.keywords", defaultValue: "discard, restore, reset", bundle: .module), glyph: .glyph(.trash))

    // MARK: Elsewhere and clipboard

    static let search = CommandSpec(id: "search", title: LocalizedStringResource("history.search.title", defaultValue: "Search Commits", bundle: .module), keywords: LocalizedStringResource("command.search.keywords", defaultValue: "find, filter", bundle: .module), glyph: .symbol("magnifyingglass"), shortcut: .search)
    static let openTerminal = CommandSpec(id: "open.terminal", title: LocalizedStringResource("command.openTerminal.title", defaultValue: "Open in terminal", bundle: .module), keywords: LocalizedStringResource("command.openTerminal.keywords", defaultValue: "shell, console", bundle: .module), glyph: .symbol("apple.terminal"), shortcut: .openTerminal)
    static let chooseTerminal = CommandSpec(id: "open.terminal.choose", title: LocalizedStringResource("command.chooseTerminal.title", defaultValue: "Open in terminal with…", bundle: .module), keywords: LocalizedStringResource("command.openTerminal.keywords", defaultValue: "shell, console", bundle: .module), glyph: .symbol("apple.terminal"))
    static let openEditor = CommandSpec(id: "open.editor", title: LocalizedStringResource("command.openEditor.title", defaultValue: "Open in editor", bundle: .module), keywords: LocalizedStringResource("command.openEditor.keywords", defaultValue: "code, ide", bundle: .module), glyph: .symbol("chevron.left.forwardslash.chevron.right"), shortcut: .openEditor)
    static let chooseEditor = CommandSpec(id: "open.editor.choose", title: LocalizedStringResource("command.chooseEditor.title", defaultValue: "Open in editor with…", bundle: .module), keywords: LocalizedStringResource("command.openEditor.keywords", defaultValue: "code, ide", bundle: .module), glyph: .symbol("chevron.left.forwardslash.chevron.right"))
    static let revealInFinder = CommandSpec(id: "open.finder", title: LocalizedStringResource("common.showInFinder", defaultValue: "Show in Finder", bundle: .module), keywords: LocalizedStringResource("command.revealInFinder.keywords", defaultValue: "reveal, folder", bundle: .module), glyph: .symbol("folder"), shortcut: .revealInFinder)
    static let copyBranch = CommandSpec(id: "copy.branch", title: LocalizedStringResource("command.copyBranch.title", defaultValue: "Copy Branch name", bundle: .module), keywords: LocalizedStringResource("command.copyBranch.keywords", defaultValue: "copy, name, clipboard", bundle: .module), glyph: .symbol("doc.on.doc"))
    static let copyHead = CommandSpec(id: "copy.head", title: LocalizedStringResource("command.copyHead.title", defaultValue: "Copy HEAD SHA", bundle: .module), keywords: LocalizedStringResource("command.copyHead.keywords", defaultValue: "copy, sha, hash, clipboard", bundle: .module), glyph: .symbol("doc.on.doc"))

    // MARK: View

    static let toggleSidebar = CommandSpec(id: "view.sidebar", title: LocalizedStringResource("command.hideSidebar.title", defaultValue: "Hide sidebar", bundle: .module), keywords: LocalizedStringResource("command.toggleSidebar.keywords", defaultValue: "sidebar, show, hide", bundle: .module), glyph: .symbol("sidebar.left"), shortcut: .toggleSidebar)
    static let toggleDetail = CommandSpec(id: "view.detail", title: LocalizedStringResource("command.hideDetail.title", defaultValue: "Hide detail panel", bundle: .module), keywords: LocalizedStringResource("command.toggleDetail.keywords", defaultValue: "inspector, detail, show, hide", bundle: .module), glyph: .symbol("sidebar.right"), shortcut: .toggleDetail)

    // MARK: Window and app

    static let newTab = CommandSpec(id: "tab.new", title: LocalizedStringResource("command.newTab.title", defaultValue: "New tab", bundle: .module), keywords: LocalizedStringResource("command.newTab.keywords", defaultValue: "tab, new", bundle: .module), glyph: .glyph(.plus), shortcut: .newTab, scope: .app)
    static let openRepository = CommandSpec(id: "repository.open", title: LocalizedStringResource("command.openRepository.title", defaultValue: "Open Repository…", bundle: .module), keywords: LocalizedStringResource("command.openRepository.keywords", defaultValue: "open, folder", bundle: .module), glyph: .symbol("folder"), shortcut: .openRepository, scope: .app)
    static let clone = CommandSpec(id: "repository.clone", title: LocalizedStringResource("command.clone.title", defaultValue: "Clone Repository…", bundle: .module), keywords: LocalizedStringResource("command.clone.keywords", defaultValue: "clone, download", bundle: .module), glyph: .glyph(.cloud), shortcut: .clone, scope: .app)
    static let closeTab = CommandSpec(id: "tab.close", title: LocalizedStringResource("command.closeTab.title", defaultValue: "Close tab", bundle: .module), keywords: LocalizedStringResource("command.closeTab.keywords", defaultValue: "tab, close", bundle: .module), glyph: .glyph(.xmark), shortcut: .closeTab, scope: .app)
    static let nextTab = CommandSpec(id: "tab.next", title: LocalizedStringResource("command.nextTab.title", defaultValue: "Next tab", bundle: .module), keywords: LocalizedStringResource("command.nextTab.keywords", defaultValue: "tab, next", bundle: .module), glyph: .glyph(.chevronRight), shortcut: .nextTab, scope: .app)
    static let previousTab = CommandSpec(id: "tab.previous", title: LocalizedStringResource("command.previousTab.title", defaultValue: "Previous tab", bundle: .module), keywords: LocalizedStringResource("command.previousTab.keywords", defaultValue: "tab, previous", bundle: .module), glyph: .symbol("chevron.left"), shortcut: .previousTab, scope: .app)
    static let switchTab = CommandSpec(id: "tab.switch", title: LocalizedStringResource("command.switchTab.title", defaultValue: "Switch to tab…", bundle: .module), keywords: LocalizedStringResource("command.switchTab.keywords", defaultValue: "tab, repository", bundle: .module), glyph: .symbol("square.on.square"), scope: .app)
    static let settings = CommandSpec(id: "settings", title: LocalizedStringResource("command.settings.title", defaultValue: "Settings…", bundle: .module), keywords: LocalizedStringResource("command.settings.keywords", defaultValue: "settings, preferences, editor, terminal", bundle: .module), glyph: .symbol("gearshape"), shortcut: .settings, scope: .app)
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
