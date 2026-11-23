import AppKit
import GitEngine

/// Lists that open from a sidebar row in a popover instead of in the tree.
enum SidebarPanel: String {
    case tags, stashes

    var target: String { "panel:" + rawValue }

    init?(target: String) {
        guard target.hasPrefix("panel:") else { return nil }
        self.init(rawValue: String(target.dropFirst("panel:".count)))
    }
}

/// One line of the sidebar.
enum SidebarItem {
    case header(key: String, title: String, count: Int, icon: Glyph, plus: Bool)
    case worktree(WorktreeInfo, isCurrent: Bool)
    case row(SidebarRow)

    /// What the row's context menu acts on, if it has one.
    var menuSubject: SidebarMenuSubject? {
        switch self {
        case .worktree(let info, let isCurrent): .worktree(info, isCurrent: isCurrent)
        case .row(let row): row.ref.map(SidebarMenuSubject.branch)
        case .header(let key, _, _, _, _): key.hasPrefix(Self.remotePrefix) ? .remote(String(key.dropFirst(Self.remotePrefix.count))) : nil
        }
    }

    /// Section keys of remotes start with this, followed by the remote's name.
    static let remotePrefix = "remote:"
    /// The target of the "Add Remote…" row.
    static let addRemoteTarget = "action:addRemote"
}

/// A line of the sidebar other than a header or worktree: a branch, a folder of branches, or an entry that opens something.
struct SidebarRow {
    var text: String
    /// The count or other value right of the text.
    var value: String = ""
    /// Commits a local branch has that its upstream lacks, and the reverse; drawn as badges in the value column, nothing at 0.
    var ahead = 0
    var behind = 0
    /// Drawn in the first column, as the plus of "Add Remote…".
    var expander: Glyph?
    var icon: Glyph?
    /// The glyph in the status slot at the right edge, with its colour.
    var slot: Glyph?
    var slotColor: NSColor?
    var indent: CGFloat = 0
    var strong = false
    var isCheckedOut = false
    /// Faint, for an entry that adds something.
    var ghost = false
    /// What a click selects or opens: a commit, a panel or a folder.
    var target: String?
    /// The worktree that has this branch checked out, if another one.
    var linkedWorktree: String?
    /// What a double click checks out.
    var checkout: CheckoutTarget?
    /// Set on branch rows; their context menu acts on it.
    var ref: Ref?
}

/// The thing a sidebar context menu acts on.
enum SidebarMenuSubject {
    case branch(Ref)
    case worktree(WorktreeInfo, isCurrent: Bool)
    /// A remote's header.
    case remote(String)

    /// How the harness names a subject: `branch:<name>` for local and remote branches (`branch:origin/main`), `worktree:<folder>`, `remote:<name>`.
    var harnessName: String {
        switch self {
        case .branch(let ref): "branch:" + ref.name
        case .worktree(let info, _): "worktree:" + (info.worktree.path as NSString).lastPathComponent
        case .remote(let name): "remote:" + name
        }
    }
}

/// Turns the view model into sidebar lines and remembers which sections and folders are collapsed.
@MainActor
struct SidebarOutline {
    /// A remote with more branches than this starts collapsed, even the first one.
    private static let expandedRemoteLimit = 40

    /// Stored per repository by `SidebarStateStore`, so it survives a relaunch.
    private(set) var state: OutlineState

    init(state: OutlineState = OutlineState()) {
        self.state = state
    }

    func isCollapsed(_ key: String) -> Bool { state.collapsed.contains(key) }

    mutating func toggle(_ key: String) {
        if state.collapsed.remove(key) == nil { state.collapsed.insert(key) }
    }

    mutating func open(_ key: String) {
        state.collapsed.remove(key)
    }

    /// `remotes` are the configured remotes; one without fetched branches still gets its header.
    mutating func items(from model: GraphViewModel, remotes configured: [String]) -> [SidebarItem] {
        var result: [SidebarItem] = []
        let otherWorktrees = model.branchesInOtherWorktrees

        func section(_ key: String, title: String, count: Int, icon: Glyph, plus: Bool = false, startCollapsed: Bool = false) -> Bool {
            // A section seen before keeps the user's choice; only a new one takes its default.
            if state.known.insert(key).inserted, startCollapsed { state.collapsed.insert(key) }
            result.append(.header(key: key, title: title, count: count, icon: icon, plus: plus))
            return !state.collapsed.contains(key)
        }
        /// Branches grouped into folders by their first path segment; folders and branches sorted together by name.
        func branches(_ refs: [Ref], display: (Ref) -> String, section key: String) {
            func leaf(_ name: String, _ ref: Ref, indent: CGFloat) {
                let linked = otherWorktrees[ref.fullName]
                let slot: Glyph? = ref.isHead ? .check : linked != nil ? .bonsaiLinked : nil
                let checkout: CheckoutTarget? = switch ref.kind {
                case .localBranch: .localBranch(ref.name)
                case .remoteBranch(let remote): .remoteBranch(remote: remote, branch: String(ref.name.dropFirst(remote.count + 1)))
                default: nil
                }
                result.append(.row(SidebarRow(text: name, ahead: ref.ahead ?? 0, behind: ref.behind ?? 0, slot: slot, slotColor: ref.isHead ? Theme.moss : nil, indent: indent, strong: ref.isHead, isCheckedOut: ref.isHead, target: ref.target, linkedWorktree: linked?.path, checkout: ref.isHead ? nil : checkout, ref: ref)))
            }
            for entry in BranchTree.entries(refs.map { (name: display($0), item: $0) }) {
                switch entry {
                case .branch(let name, let ref):
                    leaf(name, ref, indent: 0)
                case .folder(let folder, let children):
                    let folderKey = key + "/" + folder
                    let open = !state.collapsed.contains(folderKey)
                    result.append(.row(SidebarRow(text: folder, value: open ? "" : "\(children.count)", icon: open ? .chevronDown : .chevronRight, target: "folder:" + folderKey)))
                    if open { for (name, ref) in children { leaf(name, ref, indent: Theme.Sidebar.folderIndent) } }
                }
            }
        }

        if section("worktrees", title: String(localized: "sidebar.section.worktrees", defaultValue: "Worktrees", bundle: .module, comment: "Sidebar section."), count: model.worktrees.count, icon: .bonsaiMain, plus: true) {
            for info in model.worktrees {
                result.append(.worktree(info, isCurrent: model.isCurrent(info.worktree)))
            }
        }
        let tags = model.refs.filter { $0.kind == .tag }
        result.append(.row(SidebarRow(text: String(localized: "sidebar.row.tags", defaultValue: "Tags", bundle: .module, comment: "Sidebar row that opens the tag list."), value: "\(tags.count)", icon: .tag, slot: .chevronRight, target: SidebarPanel.tags.target)))

        let locals = model.refs.filter { $0.kind == .localBranch }
        if section("local", title: String(localized: "sidebar.section.local", defaultValue: "Local", bundle: .module, comment: "Sidebar section of local branches."), count: locals.count, icon: .laptop, plus: true) {
            // The uncommitted changes of this worktree; a click selects their row in the history, or HEAD when there are none.
            let changes = model.status?.entries.count ?? 0
            result.append(.row(SidebarRow(text: String(localized: "common.workingDirectory", defaultValue: "Working Directory", bundle: .module, comment: "Detail panel title for uncommitted changes"), value: "\(changes)", icon: .pencil, target: changes > 0 ? GraphViewModel.wipID : model.headSHA)))
            result.append(.row(SidebarRow(text: String(localized: "sidebar.row.stashes", defaultValue: "Stashes", bundle: .module, comment: "Sidebar row that opens the stash list."), value: "\(model.stashes.count)", icon: .stashBowl, slot: .chevronRight, target: SidebarPanel.stashes.target)))
            branches(locals, display: { $0.name }, section: "local")
        }

        var remotes = Dictionary(uniqueKeysWithValues: configured.map { ($0, [Ref]()) })
        for ref in model.refs {
            if case .remoteBranch(let remote) = ref.kind, !ref.name.hasSuffix("/HEAD") { remotes[remote, default: []].append(ref) }
        }
        for (index, remote) in remotes.keys.sorted(by: { $0 == "origin" ? true : $1 == "origin" ? false : $0 < $1 }).enumerated() {
            let refs = remotes[remote]!
            if section(SidebarItem.remotePrefix + remote, title: remote, count: refs.count, icon: .cloud, startCollapsed: index > 0 || refs.count > Self.expandedRemoteLimit) {
                branches(refs, display: { String($0.name.dropFirst(remote.count + 1)) }, section: SidebarItem.remotePrefix + remote)
            }
        }
        result.append(.row(SidebarRow(text: String(localized: "sidebar.row.addRemote", defaultValue: "Add Remote…", bundle: .module), expander: .plus, ghost: true, target: SidebarItem.addRemoteTarget)))

        return result
    }
}
