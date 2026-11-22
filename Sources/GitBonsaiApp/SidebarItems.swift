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
        default: nil
        }
    }
}

/// A line of the sidebar other than a header or worktree: a branch, a folder of branches, or an entry that opens something.
struct SidebarRow {
    var text: String
    /// The count or other value right of the text.
    var value: String = ""
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

    /// How the harness names a subject: `branch:<name>` for local and remote branches (`branch:origin/main`), `worktree:<folder>`.
    var harnessName: String {
        switch self {
        case .branch(let ref): "branch:" + ref.name
        case .worktree(let info, _): "worktree:" + (info.worktree.path as NSString).lastPathComponent
        }
    }
}

/// Turns the view model into sidebar lines and remembers which sections and folders are collapsed.
@MainActor
struct SidebarOutline {
    /// A remote with more branches than this starts collapsed, even the first one.
    private static let expandedRemoteLimit = 40

    private var collapsed: Set<String> = []
    private var knownSections: Set<String> = []

    func isCollapsed(_ key: String) -> Bool { collapsed.contains(key) }

    mutating func toggle(_ key: String) {
        if collapsed.remove(key) == nil { collapsed.insert(key) }
    }

    mutating func items(from model: GraphViewModel) -> [SidebarItem] {
        var result: [SidebarItem] = []
        let otherWorktrees = model.branchesInOtherWorktrees

        func section(_ key: String, title: String, count: Int, icon: Glyph, plus: Bool = false, startCollapsed: Bool = false) -> Bool {
            if knownSections.insert(key).inserted, startCollapsed { collapsed.insert(key) }
            result.append(.header(key: key, title: title, count: count, icon: icon, plus: plus))
            return !collapsed.contains(key)
        }
        /// Branches grouped by their first path segment, folders first, like Fork and Tower.
        func branches(_ refs: [Ref], display: (Ref) -> String, section key: String) {
            var folders: [String: [(String, Ref)]] = [:]
            var leaves: [(String, Ref)] = []
            for ref in refs {
                let name = display(ref)
                if let slash = name.firstIndex(of: "/") {
                    folders[String(name[..<slash]) + "/", default: []].append((String(name[name.index(after: slash)...]), ref))
                } else {
                    leaves.append((name, ref))
                }
            }
            func leaf(_ name: String, _ ref: Ref, indent: CGFloat) {
                let value = [ref.ahead.flatMap { $0 > 0 ? "↑\($0)" : nil }, ref.behind.flatMap { $0 > 0 ? "↓\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
                let linked = otherWorktrees[ref.fullName]
                let slot: Glyph? = ref.isHead ? .check : linked != nil ? .bonsaiLinked : nil
                let checkout: CheckoutTarget? = switch ref.kind {
                case .localBranch: .localBranch(ref.name)
                case .remoteBranch(let remote): .remoteBranch(remote: remote, branch: String(ref.name.dropFirst(remote.count + 1)))
                default: nil
                }
                result.append(.row(SidebarRow(text: name, value: value, slot: slot, slotColor: ref.isHead ? Theme.moss : nil, indent: indent, strong: ref.isHead, isCheckedOut: ref.isHead, target: ref.target, linkedWorktree: linked?.path, checkout: ref.isHead ? nil : checkout, ref: ref)))
            }
            for folder in folders.keys.sorted() {
                let folderKey = key + "/" + folder
                let open = !collapsed.contains(folderKey)
                result.append(.row(SidebarRow(text: folder, value: open ? "" : "\(folders[folder]!.count)", icon: open ? .chevronDown : .chevronRight, target: "folder:" + folderKey)))
                if open { for (name, ref) in folders[folder]!.sorted(by: { $0.0 < $1.0 }) { leaf(name, ref, indent: Theme.Sidebar.folderIndent) } }
            }
            for (name, ref) in leaves.sorted(by: { $0.0 < $1.0 }) { leaf(name, ref, indent: 0) }
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

        var remotes: [String: [Ref]] = [:]
        for ref in model.refs {
            if case .remoteBranch(let remote) = ref.kind, !ref.name.hasSuffix("/HEAD") { remotes[remote, default: []].append(ref) }
        }
        for (index, remote) in remotes.keys.sorted(by: { $0 == "origin" ? true : $1 == "origin" ? false : $0 < $1 }).enumerated() {
            let refs = remotes[remote]!
            if section("remote:" + remote, title: remote, count: refs.count, icon: .cloud, startCollapsed: index > 0 || refs.count > Self.expandedRemoteLimit) {
                branches(refs, display: { String($0.name.dropFirst(remote.count + 1)) }, section: "remote:" + remote)
            }
        }
        result.append(.row(SidebarRow(text: String(localized: "sidebar.row.addRemote", defaultValue: "Add Remote…", bundle: .module), expander: .plus, ghost: true)))

        return result
    }
}
