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
    /// The count or other value right of the text; a folder shows its count only while collapsed.
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

    var menuSubject: MenuSubject {
        switch self {
        case .branch(let ref): .branch(ref)
        case .worktree(let info, let isCurrent): .worktree(info, isCurrent: isCurrent)
        case .remote(let name): .remote(name)
        }
    }
}

/// One item of the sidebar's outline. A class, because `NSOutlineView` tells items apart by identity.
final class SidebarNode {
    let item: SidebarItem
    /// Stable across reloads: the outline finds the selected row again by it.
    let id: String
    /// The key in `OutlineState` for sections and folders; nil for rows that do not expand.
    let expansionKey: String?
    let children: [SidebarNode]

    init(_ item: SidebarItem, id: String, expansionKey: String? = nil, children: [SidebarNode] = []) {
        self.item = item
        self.id = id
        self.expansionKey = expansionKey
        self.children = children
    }

    var isExpandable: Bool { expansionKey != nil }
}

/// What the sidebar shows, read from the view model once per reload.
struct SidebarContent {
    var refs: [Ref]
    var worktrees: [WorktreeInfo]
    var currentWorktree: String?
    var changes: Int
    var stashes: Int
    var headSHA: String?
    var branchesInOtherWorktrees: [String: Worktree] = [:]
    /// The configured remotes; one without fetched branches still gets its header.
    var remotes: [String]

    @MainActor
    init(model: GraphViewModel, remotes: [String]) {
        refs = model.refs
        worktrees = model.worktrees
        currentWorktree = model.worktrees.first { model.isCurrent($0.worktree) }?.worktree.path
        changes = model.status?.entries.count ?? 0
        stashes = model.stashes.count
        headSHA = model.headSHA
        branchesInOtherWorktrees = model.branchesInOtherWorktrees
        self.remotes = remotes
    }

    init(refs: [Ref], worktrees: [WorktreeInfo] = [], currentWorktree: String? = nil, changes: Int = 0, stashes: Int = 0, headSHA: String? = nil, remotes: [String] = []) {
        self.refs = refs
        self.worktrees = worktrees
        self.currentWorktree = currentWorktree
        self.changes = changes
        self.stashes = stashes
        self.headSHA = headSHA
        self.remotes = remotes
    }
}

/// Turns the view model into the sidebar's tree and remembers which sections and folders are collapsed.
@MainActor
struct SidebarOutline {
    /// A remote with more branches than this starts collapsed, even the first one.
    static let expandedRemoteLimit = 40

    /// Stored per repository by `SessionStore`, so it survives a relaunch.
    private(set) var state: OutlineState

    init(state: OutlineState = OutlineState()) {
        self.state = state
    }

    func isCollapsed(_ key: String) -> Bool { state.collapsed.contains(key) }

    /// Returns whether anything changed.
    @discardableResult
    mutating func setCollapsed(_ key: String, _ collapsed: Bool) -> Bool {
        collapsed ? state.collapsed.insert(key).inserted : state.collapsed.remove(key) != nil
    }

    /// The whole tree, collapsed parts included; the outline view asks only for the children of expanded items.
    mutating func nodes(from content: SidebarContent) -> [SidebarNode] {
        var result: [SidebarNode] = []

        func section(_ key: String, title: String, count: Int, icon: Glyph, plus: Bool = false, startCollapsed: Bool = false, children: [SidebarNode]) -> SidebarNode {
            // A section seen before keeps the user's choice; only a new one takes its default.
            if state.known.insert(key).inserted, startCollapsed { state.collapsed.insert(key) }
            return SidebarNode(.header(key: key, title: title, count: count, icon: icon, plus: plus), id: "section:" + key, expansionKey: key, children: children)
        }
        /// Branches grouped into folders by their first path segment; folders and branches sorted together by name.
        func branches(_ refs: [Ref], display: (Ref) -> String, section key: String) -> [SidebarNode] {
            func leaf(_ name: String, _ ref: Ref, indent: CGFloat) -> SidebarNode {
                let linked = content.branchesInOtherWorktrees[ref.fullName]
                let slot: Glyph? = ref.isHead ? .check : linked != nil ? .bonsaiLinked : nil
                let checkout: CheckoutTarget? = switch ref.kind {
                case .localBranch: .localBranch(ref.name)
                case .remoteBranch(let remote): .remoteBranch(remote: remote, branch: String(ref.name.dropFirst(remote.count + 1)))
                default: nil
                }
                let row = SidebarRow(text: name, ahead: ref.ahead ?? 0, behind: ref.behind ?? 0, slot: slot, slotColor: ref.isHead ? Theme.moss : nil, indent: indent, strong: ref.isHead, isCheckedOut: ref.isHead, target: ref.target, linkedWorktree: linked?.path, checkout: ref.isHead ? nil : checkout, ref: ref)
                return SidebarNode(.row(row), id: "ref:" + ref.fullName)
            }
            return BranchTree.entries(refs.map { (name: display($0), item: $0) }).map { entry in
                switch entry {
                case .branch(let name, let ref):
                    return leaf(name, ref, indent: 0)
                case .folder(let folder, let children):
                    let folderKey = key + "/" + folder
                    let row = SidebarRow(text: folder, value: "\(children.count)", icon: .chevronRight, target: "folder:" + folderKey)
                    return SidebarNode(.row(row), id: "folder:" + folderKey, expansionKey: folderKey, children: children.map { leaf($0.name, $0.item, indent: Theme.Sidebar.folderIndent) })
                }
            }
        }

        let worktrees = content.worktrees.map { SidebarNode(.worktree($0, isCurrent: $0.worktree.path == content.currentWorktree), id: "worktree:" + $0.worktree.path) }
        result.append(section("worktrees", title: String(localized: "sidebar.section.worktrees", defaultValue: "Worktrees", bundle: .module, comment: "Sidebar section."), count: content.worktrees.count, icon: .bonsaiMain, plus: true, children: worktrees))

        let tags = content.refs.lazy.filter { $0.kind == .tag }.count
        result.append(SidebarNode(.row(SidebarRow(text: String(localized: "sidebar.row.tags", defaultValue: "Tags", bundle: .module, comment: "Sidebar row that opens the tag list."), value: "\(tags)", icon: .tag, slot: .chevronRight, target: SidebarPanel.tags.target)), id: SidebarPanel.tags.target))

        let locals = content.refs.filter { $0.kind == .localBranch }
        // The uncommitted changes of this worktree; a click selects their row in the history, or HEAD when there are none.
        let workingDirectory = SidebarNode(.row(SidebarRow(text: String(localized: "common.workingDirectory", defaultValue: "Working Directory", bundle: .module, comment: "Detail panel title for uncommitted changes"), value: "\(content.changes)", icon: .pencil, target: content.changes > 0 ? GraphViewModel.wipID : content.headSHA)), id: "workingDirectory")
        let stashes = SidebarNode(.row(SidebarRow(text: String(localized: "sidebar.row.stashes", defaultValue: "Stashes", bundle: .module, comment: "Sidebar row that opens the stash list."), value: "\(content.stashes)", icon: .stashBowl, slot: .chevronRight, target: SidebarPanel.stashes.target)), id: SidebarPanel.stashes.target)
        result.append(section("local", title: String(localized: "sidebar.section.local", defaultValue: "Local", bundle: .module, comment: "Sidebar section of local branches."), count: locals.count, icon: .laptop, plus: true, children: [workingDirectory, stashes] + branches(locals, display: { $0.name }, section: "local")))

        var remotes = Dictionary(uniqueKeysWithValues: content.remotes.map { ($0, [Ref]()) })
        for ref in content.refs {
            if case .remoteBranch(let remote) = ref.kind, !ref.name.hasSuffix("/HEAD") { remotes[remote, default: []].append(ref) }
        }
        for (index, remote) in remotes.keys.sorted(by: { $0 == "origin" ? true : $1 == "origin" ? false : $0 < $1 }).enumerated() {
            let refs = remotes[remote]!
            let key = SidebarItem.remotePrefix + remote
            result.append(section(key, title: remote, count: refs.count, icon: .cloud, startCollapsed: index > 0 || refs.count > Self.expandedRemoteLimit, children: branches(refs, display: { String($0.name.dropFirst(remote.count + 1)) }, section: key)))
        }
        result.append(SidebarNode(.row(SidebarRow(text: String(localized: "sidebar.row.addRemote", defaultValue: "Add Remote…", bundle: .module), expander: .plus, ghost: true, target: SidebarItem.addRemoteTarget)), id: SidebarItem.addRemoteTarget))
        return result
    }

    /// Opens the section and the branch folder `target` is listed in; the keys follow `nodes(from:)`. Returns the id of the target's node, nil for tags and stashes, which live in their panels.
    @discardableResult
    mutating func expand(toShow target: RefJump.Target) -> String? {
        let section: String
        let display: String
        switch target.kind {
        case .localBranch:
            (section, display) = ("local", target.name)
        case .remoteBranch(let remote):
            (section, display) = (SidebarItem.remotePrefix + remote, String(target.name.dropFirst(remote.count + 1)))
        case .worktree(let path, _):
            setCollapsed("worktrees", false)
            return "worktree:" + path
        case .tag, .stash:
            return nil
        }
        setCollapsed(section, false)
        if let slash = display.firstIndex(of: "/") { setCollapsed(section + "/" + display[...slash], false) }
        return "ref:" + target.id
    }
}
