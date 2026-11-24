import AppKit
import GitEngine

/// The context menus of the history, built from a ref section and a commit section that fill the same groups (`MenuSections`), so a combined menu orders its entries by meaning:
/// go there, integrate with the current branch, create, change, copy, remove. A pill's menu zips its ref section with the commit section.
/// A row's menu does the same when the commit has a single branch pill; with several pills each pill becomes a submenu at the top, and the commit section follows.
/// The commit section alone offers Copy SHA; ref sections add only Copy name.
@MainActor
final class HistoryMenuController {
    private let viewModel: GraphViewModel
    private let checkout: CheckoutController
    private let commitActions: CommitActionsController
    private let branches: BranchActionsController
    private let tags: TagsController
    private let fastForward: FastForwardController

    init(viewModel: GraphViewModel, checkout: CheckoutController, commitActions: CommitActionsController, branches: BranchActionsController, tags: TagsController, fastForward: FastForwardController) {
        self.viewModel = viewModel
        self.checkout = checkout
        self.commitActions = commitActions
        self.branches = branches
        self.tags = tags
        self.fastForward = fastForward
    }

    func rowMenu(forRow index: Int) -> [NSMenuItem] {
        guard let commit = commit(at: index) else { return [] }
        let all = pills(of: commit)
        let subjects = all.filter { !refSections($0.ref, commit: commit).groups.joinedWithSeparators.isEmpty }
        let leading: MenuSections
        if subjects.count == 1, case .branch = subjects[0].ref {
            return combined(refSections(subjects[0].ref, commit: commit), commit: commit, index: index, pills: all, subject: subjects[0].ref)
        }
        leading = MenuSections(refs: subjects.map { submenu(titled: Self.title(of: $0.ref), refSections($0.ref, commit: commit)) })
        return (leading + commitSections(commit, index: index, pills: all, subject: nil)).groups.joinedWithSeparators
    }

    func pillMenu(forRow index: Int, ref: PillRef) -> [NSMenuItem] {
        guard let commit = commit(at: index) else { return [] }
        return combined(refSections(ref, commit: commit), commit: commit, index: index, pills: pills(of: commit), subject: ref)
    }

    /// The branch's own "Rebase main onto X" joins the commit section's rebase variants, which offer it as one entry with a submenu.
    private func combined(_ ref: MenuSections, commit: Commit, index: Int, pills: [PillModel], subject: PillRef) -> [NSMenuItem] {
        var ref = ref
        let allCommits = ref.integrate.first { $0.identifier == RebaseOntoController.allCommitsItem }
        ref.integrate.removeAll { $0 === allCommits }
        return (ref + commitSections(commit, index: index, pills: pills, subject: subject, rebaseAllCommits: allCommits)).groups.joinedWithSeparators
    }

    // MARK: Sections

    /// A branch pill joins a local branch and its same-named remote branches: the local branch's entries fill the groups, each remote branch leads as a submenu titled with its pill.
    /// A pill with a single remote branch and no local one fills the groups with that remote branch's entries.
    private func refSections(_ ref: PillRef, commit: Commit) -> MenuSections {
        switch ref {
        case .branch(let name):
            let refs = viewModel.refsByCommit[commit.id] ?? []
            let local = refs.first { $0.kind == .localBranch && $0.name == name }
            let remotes = refs.filter { ref in
                guard case .remoteBranch(let remote) = ref.kind else { return false }
                return ref.name == "\(remote)/\(name)"
            }
            if local == nil, remotes.count == 1, let remote = remotes.first { return branches.sections(for: remote, inHistory: true) }
            let submenus = remotes.compactMap { remote -> NSMenuItem? in
                let sections = branches.sections(for: remote, inHistory: true, counterpart: local != nil)
                guard !sections.groups.joinedWithSeparators.isEmpty else { return nil }
                return submenu(titled: RefString(marked: RefName.remoteBranch(remote.name)), sections)
            }
            return MenuSections(refs: submenus) + (local.map { branches.sections(for: $0, inHistory: true) } ?? MenuSections())
        case .tag(let name):
            return tags.localTagSections(name, commit: commit.id, checkout: false)
        case .detachedHead:
            // HEAD is the commit itself; the commit section has everything it offers.
            return MenuSections()
        case .other(let name):
            return MenuSections(copy: [ActionMenuItem(LocalizedStringResource("common.copyName", defaultValue: "Copy name", bundle: .module)) { ActionRunner.copy(name) }])
        }
    }

    /// The fast-forward to the commit itself only shows where no branch pill already offers it by name.
    /// Create Worktree… preselects the menu's local branch (`subject`) when it can have a worktree; otherwise it starts from the commit.
    private func commitSections(_ commit: Commit, index: Int, pills: [PillModel], subject: PillRef?, rebaseAllCommits: NSMenuItem? = nil) -> MenuSections {
        let named = pills.contains { if case .branch = $0.ref { true } else { false } }
        let moveHere = named ? nil : fastForward.item(to: .commit(commit.id))
        var worktreeForBranch: (() -> Void)?
        if case .branch(let name) = subject, let local = viewModel.refsByCommit[commit.id]?.first(where: { $0.kind == .localBranch && $0.name == name }), branches.canCreateWorktree(for: local) {
            worktreeForBranch = { [weak branches] in branches?.createWorktree(for: name) }
        }
        var sections = commitActions.sections(for: commit, moveHere: moveHere, worktreeForBranch: worktreeForBranch, rebaseAllCommits: rebaseAllCommits)
        if let detached = checkout.detachedItem(forRow: index) { sections.goThere.append(detached) }
        if let squash = commitActions.squash.menuItem(for: commit) { sections.change.append(squash) }
        return sections
    }

    // MARK: Parts

    private func commit(at index: Int) -> Commit? {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return nil }
        return viewModel.commits[index]
    }

    private func pills(of commit: Commit) -> [PillModel] {
        HistoryRowModel.pills(for: viewModel.refsByCommit[commit.id] ?? [], branchesElsewhere: viewModel.branchesInOtherWorktrees, detachedHead: viewModel.currentBranch == nil && viewModel.headSHA == commit.id)
    }

    private func submenu(titled title: RefString, _ sections: MenuSections) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.setTitle(title)
        let submenu = NSMenu()
        sections.groups.joinedWithSeparators.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private static func title(of ref: PillRef) -> RefString {
        switch ref {
        case .branch(let name): RefString(marked: RefName.branch(name))
        case .tag(let name): RefString(marked: RefName.tag(name))
        case .detachedHead: RefString(verbatim: "HEAD")
        case .other(let name): RefString(verbatim: name)
        }
    }
}

enum RefMenus {
    /// The ref as a pill inside a menu title.
    static func pillName(of ref: Ref) -> String {
        switch ref.kind {
        case .localBranch: RefName.branch(ref.name)
        case .remoteBranch: RefName.remoteBranch(ref.name)
        case .tag: RefName.tag(ref.name)
        default: RefName.commit(ref.target)
        }
    }

    /// "Copy <SHA>", copying the full SHA.
    @MainActor static func copySHAItem(_ sha: String) -> NSMenuItem {
        ActionMenuItem(LocalizedStringResource("commit.menu.copySHA", defaultValue: "Copy \(RefName.commit(sha))", bundle: .module)) { ActionRunner.copy(sha) }
    }
}
