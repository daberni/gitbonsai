import AppKit
import GitEngine

/// The context menu of a local or remote branch, in the sidebar and on its history pill, and running its actions.
@MainActor
final class BranchActionsController {
    private let runner: SidebarActionRunner
    private let checkout: (CheckoutTarget, _ worktreePath: String?) -> Void
    private let branchPull: BranchPullController
    private var viewModel: GraphViewModel { runner.viewModel }

    init(runner: SidebarActionRunner, branchPull: BranchPullController, checkout: @escaping (CheckoutTarget, _ worktreePath: String?) -> Void) {
        self.runner = runner
        self.branchPull = branchPull
        self.checkout = checkout
    }

    func menuGroups(for ref: Ref) -> [[NSMenuItem]] {
        switch ref.kind {
        case .localBranch: localGroups(ref)
        case .remoteBranch(let remote): remoteGroups(ref, remote: remote, branch: String(ref.name.dropFirst(remote.count + 1)))
        default: []
        }
    }

    // MARK: Menu

    /// Entries that would act on the branch itself through HEAD, or move the current branch onto itself, are left out for the checked-out branch.
    private func localGroups(_ ref: Ref) -> [[NSMenuItem]] {
        let name = ref.name
        let worktree = viewModel.branchesInOtherWorktrees[ref.fullName]
        let worktreeName = worktree.map { ($0.path as NSString).lastPathComponent }
        var checkoutGroup: [NSMenuItem] = []
        var historyGroup: [NSMenuItem] = []
        if let pull = branchPull.item(for: ref) { checkoutGroup.append(pull) }
        if !ref.isHead {
            let title: LocalizedStringResource = worktreeName.map { folder -> LocalizedStringResource in "Switch to Worktree \(RefName.worktree(folder))" } ?? "Checkout \(RefName.branch(name))"
            checkoutGroup.append(ActionMenuItem(title) { [weak self] in self?.checkout(.localBranch(name), worktree?.path) })
            if let current = viewModel.currentBranch {
                historyGroup.append(ActionMenuItem("Merge \(RefName.branch(name)) into \(RefName.branch(current))") { [weak self] in self?.merge(name, into: current) })
                historyGroup.append(ActionMenuItem("Rebase \(RefName.branch(current)) onto \(RefName.branch(name))") { [weak self] in self?.rebase(current, onto: name) })
            }
        }
        var editGroup: [NSMenuItem] = [
            ActionMenuItem("Rename…") { [weak self] in self?.rename(name) },
            ActionMenuItem(ref.upstream == nil ? "Set Upstream…" : "Change Upstream…") { [weak self] in self?.setUpstream(of: ref) },
        ]
        if !ref.isHead, worktree == nil {
            editGroup.append(ActionMenuItem("Create Worktree for \(RefName.branch(name))…") { [weak self] in self?.createWorktree(for: name) })
        }
        let copyGroup: [NSMenuItem] = [ActionMenuItem("Copy name") { SidebarActionRunner.copy(name) }]
        let deleteGroup: [NSMenuItem] = ref.isHead ? [] : [ActionMenuItem("Delete \(RefName.branch(name))…") { [weak self] in self?.delete(name, worktree: worktree) }]
        return [checkoutGroup, historyGroup, editGroup, copyGroup, deleteGroup]
    }

    /// A local branch that follows this remote branch is offered a pull from it.
    private func remoteGroups(_ ref: Ref, remote: String, branch: String) -> [[NSMenuItem]] {
        let hasLocal = viewModel.refs.contains { $0.kind == .localBranch && $0.name == branch }
        var checkoutGroup: [NSMenuItem] = hasLocal ? [] : [ActionMenuItem("Checkout \(RefName.remoteBranch(ref.name)) as local Branch") { [weak self] in self?.checkout(.remoteBranch(remote: remote, branch: branch), nil) }]
        let followers = viewModel.refs.filter { $0.kind == .localBranch && $0.upstream == ref.name }
        checkoutGroup += followers.compactMap(branchPull.item(for:))
        return [
            checkoutGroup,
            [ActionMenuItem("Copy name") { SidebarActionRunner.copy(ref.name) }],
            [ActionMenuItem("Delete \(RefName.remoteBranch(branch)) from \(RefName.remote(remote))…") { [weak self] in self?.deleteRemote(branch, on: remote) }],
        ]
    }

    // MARK: Actions

    private func merge(_ name: String, into current: String) {
        Task { await runner.run(failure: "Merge failed", conflict: "Merge stopped on conflicts", note: "git merge") { try await $0.merge(name) } }
    }

    private func rebase(_ current: String, onto name: String) {
        Task {
            let published = await viewModel.repository.publishedCommitCount(rewrittenBy: name)
            if published > 0 {
                let info: LocalizedStringResource = if let upstream = viewModel.status?.branch.upstream {
                    "\(published) commits that this rewrites are already on \(RefName.remoteBranch(upstream)). Afterwards \(RefName.branch(current)) can only be pushed with a force push."
                } else {
                    "\(published) commits that this rewrites are already on the upstream. Afterwards \(RefName.branch(current)) can only be pushed with a force push."
                }
                guard await runner.confirm("Rebase \(RefName.branch(current)) onto \(RefName.branch(name))?", info: info, button: "Rebase Branch") else { return }
            }
            await runner.run(failure: "Rebase failed", conflict: "Rebase stopped on conflicts", note: "git rebase") { try await $0.rebaseCurrentBranch(onto: name) }
        }
    }

    private func rename(_ name: String) {
        let form = ActionForm(title: "Rename \(RefName.branch(name))", info: "The upstream and the worktree follow the new name. The remote keeps the old name.", confirm: "Rename")
        form.addField(key: "name", label: "New name", value: name)
        Task {
            guard let values = await runner.prompter.ask(form), let newName = values.value("name"), newName != name else { return }
            await runner.run(failure: "Branch not renamed", note: "git branch -m") { try await $0.renameBranch(name, to: newName) }
        }
    }

    private func setUpstream(of ref: Ref) {
        let name = ref.name
        let remoteBranches = viewModel.refs.compactMap { candidate -> String? in
            guard case .remoteBranch = candidate.kind, !candidate.name.hasSuffix("/HEAD") else { return nil }
            return candidate.name
        }.sorted()
        let info: LocalizedStringResource = ref.upstream.map { upstream -> LocalizedStringResource in "Currently \(RefName.remoteBranch(upstream)). Leave empty to remove the upstream." } ?? "The remote branch that \(RefName.branch(name)) is compared with and that Pull fetches from."
        let form = ActionForm(title: "Upstream of \(RefName.branch(name))", info: info, confirm: "Apply")
        let suggested = ref.upstream ?? remoteBranches.first { $0.hasSuffix("/" + name) } ?? ""
        form.addComboField(key: "upstream", label: "Remote branch", value: suggested, suggestions: remoteBranches, required: ref.upstream == nil)
        Task {
            guard let values = await runner.prompter.ask(form) else { return }
            let upstream = values.value("upstream")
            guard upstream != ref.upstream else { return }
            await runner.run(failure: "Upstream not set", note: upstream == nil ? "git branch --unset-upstream" : "git branch --set-upstream-to") { try await $0.setUpstream(of: name, to: upstream) }
        }
    }

    private func createWorktree(for name: String) {
        let form = ActionForm(title: "Create Worktree for \(RefName.branch(name))", info: "The branch is checked out in a folder of its own.", confirm: "Create")
        form.addFolderField(key: "path", label: "Folder", value: runner.defaultWorktreePath(suffix: name))
        Task {
            guard let values = await runner.prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            await runner.run(failure: "Worktree not created", note: "git worktree add") { try await $0.addWorktree(at: path, branch: name) }
        }
    }

    /// A branch checked out in another worktree can only go together with that worktree.
    private func delete(_ name: String, worktree: Worktree?) {
        Task {
            if let worktree {
                let folder = (worktree.path as NSString).lastPathComponent
                let shownPath = (worktree.path as NSString).abbreviatingWithTildeInPath
                guard await runner.confirm("Delete \(RefName.branch(name)) and Worktree \(RefName.worktree(folder))?", info: "\(RefName.branch(name)) is checked out in the worktree \(RefName.worktree(folder)) and can only be deleted together with it. The folder \(RefName.path(shownPath)) will be removed.", button: "Delete Worktree and Branch", destructive: true) else { return }
                guard await runner.removeWorktree(at: worktree.path) else { return }
            } else {
                guard await runner.confirm("Delete \(RefName.branch(name))?", info: "The local branch is deleted. A branch of the same name on the remote stays.", button: "Delete", destructive: true) else { return }
            }
            await runner.deleteBranch(name)
        }
    }

    private func deleteRemote(_ branch: String, on remote: String) {
        Task {
            guard await runner.confirm("Delete \(RefName.remoteBranch(branch)) from \(RefName.remote(remote))?", info: "The branch is deleted on the remote, for everyone who works with it. Local branches stay.", button: "Delete on Remote", destructive: true) else { return }
            await runner.run(failure: "Remote branch not deleted", note: "git push --delete") { try await $0.deleteRemoteBranch(branch, on: remote) }
        }
    }
}
