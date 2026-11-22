import AppKit
import GitEngine

/// What a command is, independent of a tab's state: id, title, search words, glyph and shortcut.
/// The command bar and the main menu both read these, so a title or shortcut changes in one place; the providers add context, enabled state and the action.
/// Commands that exist once per remote, branch or tab are built by their provider directly and listed in the menu as a family by id prefix.
struct CommandSpec {
    let id: String
    let title: String
    var keywords: [String] = []
    let glyph: CommandGlyph
    var shortcut: CommandShortcut? = nil
    var scope: Command.Scope = .repository
}

@MainActor
extension CommandSpec {
    // MARK: Remotes

    static let fetchAll = CommandSpec(id: "fetch", title: "Alle Remotes fetchen", keywords: ["fetch"], glyph: .symbol("arrow.down.circle"), shortcut: .fetch)
    static let fetchTags = CommandSpec(id: "fetch.tags", title: "Tags aller Remotes fetchen", keywords: ["fetch"], glyph: .glyph(.tag))
    static let pull = CommandSpec(id: "pull", title: "Pull", glyph: .symbol("arrow.down"), shortcut: .pull)
    static let pullAutostash = CommandSpec(id: "pull.autostash", title: "Pull mit Autostash", keywords: ["stash"], glyph: .symbol("arrow.down"))
    static let setUpstreamAndPull = CommandSpec(id: "pull.set-upstream", title: "Upstream setzen und pullen …", keywords: ["pull"], glyph: .symbol("arrow.down"))
    static let push = CommandSpec(id: "push", title: "Push", glyph: .symbol("arrow.up"), shortcut: .push)

    // MARK: Branches

    static let newBranch = CommandSpec(id: "branch.new", title: "Neuer Branch …", keywords: ["branch", "create"], glyph: .glyph(.branch), shortcut: .newBranch)
    static let checkout = CommandSpec(id: "checkout", title: "Branch auschecken …", keywords: ["checkout", "switch", "wechseln"], glyph: .glyph(.branch))
    static let rebaseInteractive = CommandSpec(id: "rebase.interactive", title: "Rebase interaktiv …", keywords: ["rebase -i", "squash", "reword"], glyph: .symbol("list.bullet.indent"))
    static let switchWorktree = CommandSpec(id: "worktree.switch", title: "Worktree wechseln …", keywords: ["worktree", "switch"], glyph: .glyph(.bonsaiLinked))

    // MARK: Working directory

    static let stash = CommandSpec(id: "stash", title: "Stash …", keywords: ["stash push", "änderungen"], glyph: .glyph(.stashBowl), shortcut: .stash)
    static let pop = CommandSpec(id: "stash.pop", title: "Stash poppen", keywords: ["pop"], glyph: .glyph(.stashBowl), shortcut: .pop)
    static let commit = CommandSpec(id: "commit", title: "Commit …", keywords: ["commit"], glyph: .glyph(.staged), shortcut: .commit)
    static let amend = CommandSpec(id: "commit.amend", title: "Letzten Commit ändern (Amend) …", keywords: ["amend"], glyph: .glyph(.pencil))
    static let editMessage = CommandSpec(id: "commit.reword", title: "Commit-Nachricht bearbeiten", keywords: ["reword", "message", "nachricht"], glyph: .glyph(.pencil), shortcut: .editMessage)
    static let stageAll = CommandSpec(id: "stage.all", title: "Alles stagen", keywords: ["add", "stage all"], glyph: .glyph(.plus))
    static let unstageAll = CommandSpec(id: "unstage.all", title: "Alles unstagen", keywords: ["restore", "unstage all"], glyph: .glyph(.minus))
    static let discardAll = CommandSpec(id: "discard.all", title: "Alle Änderungen verwerfen …", keywords: ["discard", "restore", "reset"], glyph: .glyph(.trash))

    // MARK: Elsewhere and clipboard

    static let search = CommandSpec(id: "search", title: "Commits durchsuchen", keywords: ["find", "suchen", "filter"], glyph: .symbol("magnifyingglass"), shortcut: .search)
    static let openTerminal = CommandSpec(id: "open.terminal", title: "Im Terminal öffnen", keywords: ["shell", "console"], glyph: .symbol("apple.terminal"), shortcut: .openTerminal)
    static let chooseTerminal = CommandSpec(id: "open.terminal.choose", title: "Im Terminal öffnen mit …", keywords: ["shell", "console"], glyph: .symbol("apple.terminal"))
    static let openEditor = CommandSpec(id: "open.editor", title: "Im Editor öffnen", keywords: ["code", "ide"], glyph: .symbol("chevron.left.forwardslash.chevron.right"), shortcut: .openEditor)
    static let chooseEditor = CommandSpec(id: "open.editor.choose", title: "Im Editor öffnen mit …", keywords: ["code", "ide"], glyph: .symbol("chevron.left.forwardslash.chevron.right"))
    static let revealInFinder = CommandSpec(id: "open.finder", title: "Im Finder zeigen", keywords: ["reveal", "ordner"], glyph: .symbol("folder"), shortcut: .revealInFinder)
    static let copyBranch = CommandSpec(id: "copy.branch", title: "Branch-Namen kopieren", keywords: ["copy"], glyph: .symbol("doc.on.doc"))
    static let copyHead = CommandSpec(id: "copy.head", title: "HEAD-SHA kopieren", keywords: ["copy", "sha"], glyph: .symbol("doc.on.doc"))

    // MARK: View

    static let toggleSidebar = CommandSpec(id: "view.sidebar", title: "Seitenleiste ausblenden", keywords: ["sidebar", "seitenleiste"], glyph: .symbol("sidebar.left"), shortcut: .toggleSidebar)
    static let toggleDetail = CommandSpec(id: "view.detail", title: "Detail-Panel ausblenden", keywords: ["inspector", "detail"], glyph: .symbol("sidebar.right"), shortcut: .toggleDetail)

    // MARK: Window and app

    static let newTab = CommandSpec(id: "tab.new", title: "Neuer Tab", keywords: ["tab"], glyph: .glyph(.plus), shortcut: .newTab, scope: .app)
    static let openRepository = CommandSpec(id: "repository.open", title: "Repository öffnen …", keywords: ["open", "ordner"], glyph: .symbol("folder"), shortcut: .openRepository, scope: .app)
    static let clone = CommandSpec(id: "repository.clone", title: "Repository klonen …", keywords: ["clone"], glyph: .glyph(.cloud), shortcut: .clone, scope: .app)
    static let closeTab = CommandSpec(id: "tab.close", title: "Tab schließen", keywords: ["tab", "close"], glyph: .glyph(.xmark), shortcut: .closeTab, scope: .app)
    static let nextTab = CommandSpec(id: "tab.next", title: "Nächster Tab", keywords: ["tab"], glyph: .glyph(.chevronRight), shortcut: .nextTab, scope: .app)
    static let previousTab = CommandSpec(id: "tab.previous", title: "Vorheriger Tab", keywords: ["tab"], glyph: .symbol("chevron.left"), shortcut: .previousTab, scope: .app)
    static let switchTab = CommandSpec(id: "tab.switch", title: "Zu Tab wechseln …", keywords: ["tab", "repository"], glyph: .symbol("square.on.square"), scope: .app)
    static let settings = CommandSpec(id: "settings", title: "Einstellungen …", keywords: ["settings", "preferences", "editor", "terminal"], glyph: .symbol("gearshape"), shortcut: .settings, scope: .app)
}

extension Command {
    /// `keywords` add search words that depend on the state, such as the name of the default editor; `title` replaces the spec's for a toggle that names its next state.
    init(_ spec: CommandSpec, title: String? = nil, keywords: [String] = [], context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: String? = nil, action: Action) {
        self.init(id: spec.id, title: title ?? spec.title, keywords: spec.keywords + keywords, glyph: spec.glyph, shortcut: spec.shortcut, scope: spec.scope, context: context, blocker: blocker, disabledReason: disabledReason, action: action)
    }

    init(_ spec: CommandSpec, title: String? = nil, keywords: [String] = [], context: String? = nil, blocker: CommandBlocker? = nil, disabledReason: String? = nil, run: @escaping @MainActor () -> Void) {
        self.init(spec, title: title, keywords: keywords, context: context, blocker: blocker, disabledReason: disabledReason, action: .run(run))
    }
}
