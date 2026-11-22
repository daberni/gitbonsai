import AppKit
import GitEngine

/// The context menu of a ref pill in the history: the ref's own menu from the sidebar and the Tags list, not the commit's.
@MainActor
final class PillMenuController {
    private let viewModel: GraphViewModel
    private let sidebarActions: SidebarActionsController
    private let tags: TagsController

    init(viewModel: GraphViewModel, sidebarActions: SidebarActionsController, tags: TagsController) {
        self.viewModel = viewModel
        self.sidebarActions = sidebarActions
        self.tags = tags
    }

    func menuItems(forRow index: Int, ref: PillRef) -> [NSMenuItem] {
        guard viewModel.commits.indices.contains(index) else { return [] }
        let commit = viewModel.commits[index].id
        let refs = viewModel.refsByCommit[commit] ?? []
        switch ref {
        case .branch(let name):
            return branchItems(name, refs: refs)
        case .tag(let name):
            return tags.localTagGroups(name, commit: commit).joinedWithSeparators
        case .detachedHead:
            return [
                [ActionMenuItem("Create Branch Here…") { [weak self] in self?.sidebarActions.newBranch.show() }],
                [ActionMenuItem("Copy SHA") { SidebarActionRunner.copy(commit) }],
            ].joinedWithSeparators
        case .other(let name):
            return [ActionMenuItem("Copy Name") { SidebarActionRunner.copy(name) }]
        }
    }

    /// The pill joins a local branch and its same-named remote branches at this commit. The local branch leads with its own menu and each remote branch follows in a submenu;
    /// a pill with a single remote branch and no local one shows that remote branch's menu directly.
    private func branchItems(_ name: String, refs: [Ref]) -> [NSMenuItem] {
        let branches = sidebarActions.branches
        let local = refs.first { $0.kind == .localBranch && $0.name == name }
        let remotes = refs.filter { ref in
            guard case .remoteBranch(let remote) = ref.kind else { return false }
            return ref.name == "\(remote)/\(name)"
        }
        if local == nil, remotes.count == 1, let remote = remotes.first { return branches.menuGroups(for: remote).joinedWithSeparators }
        let submenus = remotes.map { remote in
            let item = NSMenuItem(title: remote.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            branches.menuGroups(for: remote).joinedWithSeparators.forEach(submenu.addItem)
            item.submenu = submenu
            return item
        }
        let localGroups = local.map(branches.menuGroups(for:)) ?? []
        return (localGroups + [submenus]).joinedWithSeparators
    }
}
