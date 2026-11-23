import AppKit
import GitEngine

/// The context menus of the history, built from two sections with the same entries and order wherever they show:
/// the ref section of a pill (the sidebar's branch menu, the Tags list's tag menu) and the commit section of its row.
/// A pill's menu is its ref section, then the commit section flat. A row's menu leads with the ref section inline when the commit has a single branch pill,
/// or with one submenu per pill when it has several, followed by the commit section.
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
        let subjects = all.filter { !refGroups($0.ref, commit: commit).joinedWithSeparators.isEmpty }
        let leading: [[NSMenuItem]] = if subjects.count == 1, case .branch = subjects[0].ref {
            refGroups(subjects[0].ref, commit: commit)
        } else {
            [subjects.map { submenu(titled: Self.title(of: $0.ref), refGroups($0.ref, commit: commit)) }]
        }
        return (leading + commitGroups(commit, index: index, pills: all)).joinedWithSeparators
    }

    func pillMenu(forRow index: Int, ref: PillRef) -> [NSMenuItem] {
        guard let commit = commit(at: index) else { return [] }
        return (refGroups(ref, commit: commit) + commitGroups(commit, index: index, pills: pills(of: commit))).joinedWithSeparators
    }

    // MARK: Sections

    /// A branch pill joins a local branch and its same-named remote branches: the local branch's menu leads, each remote branch follows as a submenu titled with its pill.
    /// A pill with a single remote branch and no local one shows that remote branch's menu directly.
    private func refGroups(_ ref: PillRef, commit: Commit) -> [[NSMenuItem]] {
        switch ref {
        case .branch(let name):
            let refs = viewModel.refsByCommit[commit.id] ?? []
            let local = refs.first { $0.kind == .localBranch && $0.name == name }
            let remotes = refs.filter { ref in
                guard case .remoteBranch(let remote) = ref.kind else { return false }
                return ref.name == "\(remote)/\(name)"
            }
            if local == nil, remotes.count == 1, let remote = remotes.first { return branches.menuGroups(for: remote) }
            let submenus = remotes.map { remote in submenu(titled: RefString(marked: RefName.remoteBranch(remote.name)), branches.menuGroups(for: remote)) }
            return (local.map(branches.menuGroups(for:)) ?? []) + [submenus]
        case .tag(let name):
            return tags.localTagGroups(name, commit: commit.id, checkout: false)
        case .detachedHead:
            // HEAD is the commit itself; the commit section has everything it offers.
            return []
        case .other(let name):
            return [[ActionMenuItem(LocalizedStringResource("common.copyName", defaultValue: "Copy name", bundle: .module)) { ActionRunner.copy(name) }]]
        }
    }

    /// The fast-forward to the commit itself only shows where no branch pill already offers it by name.
    private func commitGroups(_ commit: Commit, index: Int, pills: [PillModel]) -> [[NSMenuItem]] {
        let named = pills.contains { if case .branch = $0.ref { true } else { false } }
        let moveHere = named ? [] : fastForward.items(to: .commit(commit.id))
        return [checkout.detachedItem(forRow: index).map { [$0] } ?? []] + commitActions.groups(for: commit, moveHere: moveHere)
    }

    // MARK: Parts

    private func commit(at index: Int) -> Commit? {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return nil }
        return viewModel.commits[index]
    }

    private func pills(of commit: Commit) -> [PillModel] {
        HistoryRowModel.pills(for: viewModel.refsByCommit[commit.id] ?? [], branchesElsewhere: viewModel.branchesInOtherWorktrees, detachedHead: viewModel.currentBranch == nil && viewModel.headSHA == commit.id)
    }

    private func submenu(titled title: RefString, _ groups: [[NSMenuItem]]) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.setTitle(title)
        let submenu = NSMenu()
        groups.joinedWithSeparators.forEach(submenu.addItem)
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
}
