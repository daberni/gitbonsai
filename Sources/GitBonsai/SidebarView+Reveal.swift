import AppKit
import GitEngine

/// Shows a branch or worktree that was chosen elsewhere, such as in "Go to Ref…".
extension SidebarView {
    /// Expands the section and folder that hold the target, scrolls its row into view and marks it as the hover does until the pointer moves. Tags and stashes live in their panels, not in the tree, so nothing happens for them.
    func reveal(_ target: RefJump.Target) {
        guard let model else { return }
        outline.expand(toShow: target)
        saveOutline()
        reload(from: model)
        guard let index = items.firstIndex(where: { Self.item($0, shows: target) }) else { return }
        hovered = index
        needsDisplay = true
        scrollToVisible(frames[index].insetBy(dx: 0, dy: -Theme.Space.s))
    }

    private static func item(_ item: SidebarItem, shows target: RefJump.Target) -> Bool {
        switch (item, target.kind) {
        case (.row(let row), .localBranch), (.row(let row), .remoteBranch): row.ref.map { $0.name == target.name && $0.kind != .tag } ?? false
        case (.worktree(let info, _), .worktree(let path, _)): info.worktree.path == path
        default: false
        }
    }
}

extension SidebarOutline {
    /// Opens the section and the branch folder `target` is listed in; the keys follow `items(from:)`.
    mutating func expand(toShow target: RefJump.Target) {
        let section: String
        let display: String
        switch target.kind {
        case .localBranch:
            (section, display) = ("local", target.name)
        case .remoteBranch(let remote):
            (section, display) = ("remote:" + remote, String(target.name.dropFirst(remote.count + 1)))
        case .worktree:
            return open("worktrees")
        case .tag, .stash:
            return
        }
        open(section)
        if let slash = display.firstIndex(of: "/") { open(section + "/" + display[..<slash] + "/") }
    }
}
