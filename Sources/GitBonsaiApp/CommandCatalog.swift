import AppKit
import GitEngine

/// What a command is, independent of a tab's state: id, title, search words, glyph and shortcut.
/// The command bar and the main menu both read these, so a title or shortcut changes in one place; the providers add context, enabled state and the action.
/// Commands that exist once per remote, branch or tab are built by their provider directly and listed in the menu as a family by id prefix.
struct CommandSpec {
    let id: String
    let title: LocalizedStringResource
    var keywords: [String] = []
    let glyph: CommandGlyph
    var shortcut: CommandShortcut? = nil
    var scope: Command.Scope = .repository
}

@MainActor
extension CommandSpec {
    // MARK: Remotes

    static let fetchAll = CommandSpec(id: "fetch", title: "Fetch All Remotes", keywords: ["fetch"], glyph: .symbol("arrow.down.circle"), shortcut: .fetch)
    static let fetchTags = CommandSpec(id: "fetch.tags", title: "Fetch Tags from All Remotes", keywords: ["fetch"], glyph: .glyph(.tag))
    static let pull = CommandSpec(id: "pull", title: "Pull", glyph: .symbol("arrow.down"), shortcut: .pull)
    static let setUpstreamAndPull = CommandSpec(id: "pull.set-upstream", title: "Set Upstream and Pull…", keywords: ["pull"], glyph: .symbol("arrow.down"))
    static let push = CommandSpec(id: "push", title: "Push", glyph: .symbol("arrow.up"), shortcut: .push)

    // MARK: Branches

    static let newBranch = CommandSpec(id: "branch.new", title: "New Branch…", keywords: ["branch", "create"], glyph: .glyph(.branch), shortcut: .newBranch)
    static let checkout = CommandSpec(id: "checkout", title: "Check Out Branch…", keywords: ["checkout", "switch", "wechseln"], glyph: .glyph(.branch))
    static let rebaseInteractive = CommandSpec(id: "rebase.interactive", title: "Interactive Rebase…", keywords: ["rebase -i", "squash", "reword"], glyph: .symbol("list.bullet.indent"))
    static let switchWorktree = CommandSpec(id: "worktree.switch", title: "Switch Worktree…", keywords: ["worktree", "switch"], glyph: .glyph(.bonsaiLinked))

    // MARK: Working directory

    static let stash = CommandSpec(id: "stash", title: "Stash Changes", keywords: ["stash push", "änderungen"], glyph: .glyph(.stashBowl), shortcut: .stash)
    static let stashWithMessage = CommandSpec(id: "stash.message", title: "Stash with Message…", keywords: ["stash push", "änderungen"], glyph: .glyph(.stashBowl))
    static let stashStaged = CommandSpec(id: "stash.staged", title: "Stash Staged Changes Only", keywords: ["stash push", "staged"], glyph: .glyph(.stashBowl))
    static let pop = CommandSpec(id: "stash.pop", title: "Pop Stash", keywords: ["pop"], glyph: .glyph(.stashBowl), shortcut: .pop)
    static let commit = CommandSpec(id: "commit", title: "Commit…", keywords: ["commit"], glyph: .glyph(.staged), shortcut: .commit)
    static let amend = CommandSpec(id: "commit.amend", title: "Amend Last Commit…", keywords: ["amend"], glyph: .glyph(.pencil))
    static let editMessage = CommandSpec(id: "commit.reword", title: "Edit Commit Message", keywords: ["reword", "message", "nachricht"], glyph: .glyph(.pencil), shortcut: .editMessage)
    static let stageAll = CommandSpec(id: "stage.all", title: "Stage All", keywords: ["add", "stage all"], glyph: .glyph(.plus))
    static let unstageAll = CommandSpec(id: "unstage.all", title: "Unstage All", keywords: ["restore", "unstage all"], glyph: .glyph(.minus))
    static let discardAll = CommandSpec(id: "discard.all", title: "Discard All Changes…", keywords: ["discard", "restore", "reset"], glyph: .glyph(.trash))

    // MARK: Elsewhere and clipboard

    static let search = CommandSpec(id: "search", title: "Search Commits", keywords: ["find", "suchen", "filter"], glyph: .symbol("magnifyingglass"), shortcut: .search)
    static let openTerminal = CommandSpec(id: "open.terminal", title: "Open in Terminal", keywords: ["shell", "console"], glyph: .symbol("apple.terminal"), shortcut: .openTerminal)
    static let chooseTerminal = CommandSpec(id: "open.terminal.choose", title: "Open in Terminal With…", keywords: ["shell", "console"], glyph: .symbol("apple.terminal"))
    static let openEditor = CommandSpec(id: "open.editor", title: "Open in Editor", keywords: ["code", "ide"], glyph: .symbol("chevron.left.forwardslash.chevron.right"), shortcut: .openEditor)
    static let chooseEditor = CommandSpec(id: "open.editor.choose", title: "Open in Editor With…", keywords: ["code", "ide"], glyph: .symbol("chevron.left.forwardslash.chevron.right"))
    static let revealInFinder = CommandSpec(id: "open.finder", title: "Show in Finder", keywords: ["reveal", "ordner"], glyph: .symbol("folder"), shortcut: .revealInFinder)
    static let copyBranch = CommandSpec(id: "copy.branch", title: "Copy Branch Name", keywords: ["copy"], glyph: .symbol("doc.on.doc"))
    static let copyHead = CommandSpec(id: "copy.head", title: "Copy HEAD SHA", keywords: ["copy", "sha"], glyph: .symbol("doc.on.doc"))

    // MARK: View

    static let toggleSidebar = CommandSpec(id: "view.sidebar", title: "Hide Sidebar", keywords: ["sidebar", "seitenleiste"], glyph: .symbol("sidebar.left"), shortcut: .toggleSidebar)
    static let toggleDetail = CommandSpec(id: "view.detail", title: "Hide Detail Panel", keywords: ["inspector", "detail"], glyph: .symbol("sidebar.right"), shortcut: .toggleDetail)

    // MARK: Window and app

    static let newTab = CommandSpec(id: "tab.new", title: "New Tab", keywords: ["tab"], glyph: .glyph(.plus), shortcut: .newTab, scope: .app)
    static let openRepository = CommandSpec(id: "repository.open", title: "Open Repository…", keywords: ["open", "ordner"], glyph: .symbol("folder"), shortcut: .openRepository, scope: .app)
    static let clone = CommandSpec(id: "repository.clone", title: "Clone Repository…", keywords: ["clone"], glyph: .glyph(.cloud), shortcut: .clone, scope: .app)
    static let closeTab = CommandSpec(id: "tab.close", title: "Close Tab", keywords: ["tab", "close"], glyph: .glyph(.xmark), shortcut: .closeTab, scope: .app)
    static let nextTab = CommandSpec(id: "tab.next", title: "Next Tab", keywords: ["tab"], glyph: .glyph(.chevronRight), shortcut: .nextTab, scope: .app)
    static let previousTab = CommandSpec(id: "tab.previous", title: "Previous Tab", keywords: ["tab"], glyph: .symbol("chevron.left"), shortcut: .previousTab, scope: .app)
    static let switchTab = CommandSpec(id: "tab.switch", title: "Switch to Tab…", keywords: ["tab", "repository"], glyph: .symbol("square.on.square"), scope: .app)
    static let settings = CommandSpec(id: "settings", title: "Settings…", keywords: ["settings", "preferences", "editor", "terminal"], glyph: .symbol("gearshape"), shortcut: .settings, scope: .app)
}

extension Command {
    /// `keywords` add search words that depend on the state, such as the name of the default editor; `title` replaces the spec's for a toggle that names its next state.
    init(_ spec: CommandSpec, title: LocalizedStringResource? = nil, keywords: [String] = [], context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: LocalizedStringResource? = nil, action: Action) {
        self.init(id: spec.id, title: title ?? spec.title, keywords: spec.keywords + keywords, glyph: spec.glyph, shortcut: spec.shortcut, scope: spec.scope, context: context, blocker: blocker, disabledReason: disabledReason, action: action)
    }

    init(_ spec: CommandSpec, title: LocalizedStringResource? = nil, keywords: [String] = [], context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: LocalizedStringResource? = nil, run: @escaping @MainActor () -> Void) {
        self.init(spec, title: title, keywords: keywords, context: context, blocker: blocker, disabledReason: disabledReason, action: .run(run))
    }
}
