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
    /// `ref` is set on branch rows; their context menu acts on it.
    case row(text: String, value: String, expander: Glyph?, icon: Glyph?, slot: Glyph?, slotColor: NSColor?, indent: CGFloat, strong: Bool, isCheckedOut: Bool, ghost: Bool, target: String?, linkedWorktree: String?, checkout: CheckoutTarget?, ref: Ref? = nil)

    /// What the row's context menu acts on, if it has one.
    var menuSubject: SidebarMenuSubject? {
        switch self {
        case .worktree(let info, let isCurrent): .worktree(info, isCurrent: isCurrent)
        case .row(_, _, _, _, _, _, _, _, _, _, _, _, _, let ref?): .branch(ref)
        default: nil
        }
    }
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
                result.append(.row(text: name, value: value, expander: nil, icon: nil, slot: slot, slotColor: ref.isHead ? Theme.moss : nil, indent: indent, strong: ref.isHead, isCheckedOut: ref.isHead, ghost: false, target: ref.target, linkedWorktree: linked?.path, checkout: ref.isHead ? nil : checkout, ref: ref))
            }
            for folder in folders.keys.sorted() {
                let folderKey = key + "/" + folder
                let open = !collapsed.contains(folderKey)
                result.append(.row(text: folder, value: open ? "" : "\(folders[folder]!.count)", expander: nil, icon: open ? .chevronDown : .chevronRight, slot: nil, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: "folder:" + folderKey, linkedWorktree: nil, checkout: nil))
                if open { for (name, ref) in folders[folder]!.sorted(by: { $0.0 < $1.0 }) { leaf(name, ref, indent: Theme.Sidebar.folderIndent) } }
            }
            for (name, ref) in leaves.sorted(by: { $0.0 < $1.0 }) { leaf(name, ref, indent: 0) }
        }

        if section("worktrees", title: "Worktrees", count: model.worktrees.count, icon: .bonsaiMain, plus: true) {
            for info in model.worktrees {
                result.append(.worktree(info, isCurrent: model.isCurrent(info.worktree)))
            }
        }
        let tags = model.refs.filter { $0.kind == .tag }
        result.append(.row(text: "Tags", value: "\(tags.count)", expander: nil, icon: .tag, slot: .chevronRight, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: SidebarPanel.tags.target, linkedWorktree: nil, checkout: nil))

        let locals = model.refs.filter { $0.kind == .localBranch }
        if section("local", title: "Local", count: locals.count, icon: .laptop, plus: true) {
            // The uncommitted changes of this worktree; a click selects their row in the history, or HEAD when there are none.
            let changes = model.status?.entries.count ?? 0
            result.append(.row(text: "Working Directory", value: "\(changes)", expander: nil, icon: .pencil, slot: nil, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: changes > 0 ? GraphViewModel.wipID : model.headSHA, linkedWorktree: nil, checkout: nil))
            result.append(.row(text: "Stashes", value: "\(model.stashes.count)", expander: nil, icon: .stashBowl, slot: .chevronRight, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: SidebarPanel.stashes.target, linkedWorktree: nil, checkout: nil))
            branches(locals, display: { $0.name }, section: "local")
        }

        var remotes: [String: [Ref]] = [:]
        for ref in model.refs {
            if case .remoteBranch(let remote) = ref.kind, !ref.name.hasSuffix("/HEAD") { remotes[remote, default: []].append(ref) }
        }
        for (index, remote) in remotes.keys.sorted(by: { $0 == "origin" ? true : $1 == "origin" ? false : $0 < $1 }).enumerated() {
            let refs = remotes[remote]!
            if section("remote:" + remote, title: remote, count: refs.count, icon: .cloud, startCollapsed: index > 0 || refs.count > 40) {
                branches(refs, display: { String($0.name.dropFirst(remote.count + 1)) }, section: "remote:" + remote)
            }
        }
        result.append(.row(text: "Remote hinzufügen …", value: "", expander: .plus, icon: nil, slot: nil, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: true, target: nil, linkedWorktree: nil, checkout: nil))

        return result
    }
}
