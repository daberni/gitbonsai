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
            let title: LocalizedStringResource = worktreeName.map { folder -> LocalizedStringResource in LocalizedStringResource("worktree.action.switchTo", defaultValue: "Switch to Worktree \(RefName.worktree(folder))", bundle: .module) } ?? LocalizedStringResource("checkout.action.branch", defaultValue: "Checkout \(RefName.branch(name))", bundle: .module)
            checkoutGroup.append(ActionMenuItem(title) { [weak self] in self?.checkout(.localBranch(name), worktree?.path) })
            if let current = viewModel.currentBranch {
                historyGroup.append(ActionMenuItem(LocalizedStringResource("branch.menu.merge", defaultValue: "Merge \(RefName.branch(name)) into \(RefName.branch(current))", bundle: .module)) { [weak self] in self?.merge(name, into: current) })
                historyGroup.append(ActionMenuItem(LocalizedStringResource("branch.menu.rebase", defaultValue: "Rebase \(RefName.branch(current)) onto \(RefName.branch(name))", bundle: .module)) { [weak self] in self?.rebase(current, onto: name) })
            }
        }
        var editGroup: [NSMenuItem] = [
            ActionMenuItem(LocalizedStringResource("branch.menu.rename", defaultValue: "Rename…", bundle: .module)) { [weak self] in self?.rename(name) },
            ActionMenuItem(ref.upstream == nil ? LocalizedStringResource("branch.menu.setUpstream", defaultValue: "Set Upstream…", bundle: .module) : LocalizedStringResource("branch.menu.changeUpstream", defaultValue: "Change Upstream…", bundle: .module)) { [weak self] in self?.setUpstream(of: ref) },
        ]
        if !ref.isHead, worktree == nil {
            editGroup.append(ActionMenuItem(LocalizedStringResource("branch.menu.createWorktree", defaultValue: "Create Worktree for \(RefName.branch(name))…", bundle: .module)) { [weak self] in self?.createWorktree(for: name) })
        }
        let copyGroup: [NSMenuItem] = [ActionMenuItem(LocalizedStringResource("common.copyName", defaultValue: "Copy name", bundle: .module)) { SidebarActionRunner.copy(name) }]
        let deleteGroup: [NSMenuItem] = ref.isHead ? [] : [ActionMenuItem(LocalizedStringResource("branch.menu.delete", defaultValue: "Delete \(RefName.branch(name))…", bundle: .module)) { [weak self] in self?.delete(name, worktree: worktree) }]
        return [checkoutGroup, historyGroup, editGroup, copyGroup, deleteGroup]
    }

    /// A local branch that follows this remote branch is offered a pull from it.
    private func remoteGroups(_ ref: Ref, remote: String, branch: String) -> [[NSMenuItem]] {
        let hasLocal = viewModel.refs.contains { $0.kind == .localBranch && $0.name == branch }
        var checkoutGroup: [NSMenuItem] = hasLocal ? [] : [ActionMenuItem(LocalizedStringResource("checkout.action.asLocalBranch", defaultValue: "Checkout \(RefName.remoteBranch(ref.name)) as local Branch", bundle: .module)) { [weak self] in self?.checkout(.remoteBranch(remote: remote, branch: branch), nil) }]
        let followers = viewModel.refs.filter { $0.kind == .localBranch && $0.upstream == ref.name }
        checkoutGroup += followers.compactMap(branchPull.item(for:))
        return [
            checkoutGroup,
            [ActionMenuItem(LocalizedStringResource("common.copyName", defaultValue: "Copy name", bundle: .module)) { SidebarActionRunner.copy(ref.name) }],
            [ActionMenuItem(LocalizedStringResource("branch.menu.deleteRemote", defaultValue: "Delete \(RefName.remoteBranch(branch)) from \(RefName.remote(remote))…", bundle: .module)) { [weak self] in self?.deleteRemote(branch, on: remote) }],
        ]
    }

    // MARK: Actions

    private func merge(_ name: String, into current: String) {
        Task { await runner.run(failure: LocalizedStringResource("failure.merge.failed", defaultValue: "Merge failed", bundle: .module), conflict: LocalizedStringResource("failure.merge.conflicts", defaultValue: "Merge stopped on conflicts", bundle: .module), note: "git merge") { try await $0.merge(name) } }
    }

    private func rebase(_ current: String, onto name: String) {
        Task {
            let published = await viewModel.repository.publishedCommitCount(rewrittenBy: name)
            if published > 0 {
                let info: LocalizedStringResource = if let upstream = viewModel.status?.branch.upstream {
                    LocalizedStringResource("branch.rebase.alreadyOnRemote", defaultValue: "\(published) commits that this rewrites are already on \(RefName.remoteBranch(upstream)). Afterwards \(RefName.branch(current)) can only be pushed with a force push.", bundle: .module)
                } else {
                    LocalizedStringResource("branch.rebase.alreadyOnUpstream", defaultValue: "\(published) commits that this rewrites are already on the upstream. Afterwards \(RefName.branch(current)) can only be pushed with a force push.", bundle: .module)
                }
                guard await runner.confirm(LocalizedStringResource("branch.rebase.title", defaultValue: "Rebase \(RefName.branch(current)) onto \(RefName.branch(name))?", bundle: .module), info: info, button: LocalizedStringResource("branch.rebase.confirm", defaultValue: "Rebase Branch", bundle: .module)) else { return }
            }
            await runner.run(failure: LocalizedStringResource("failure.rebase.failed", defaultValue: "Rebase failed", bundle: .module), conflict: LocalizedStringResource("failure.rebase.conflicts", defaultValue: "Rebase stopped on conflicts", bundle: .module), note: "git rebase") { try await $0.rebaseCurrentBranch(onto: name) }
        }
    }

    private func rename(_ name: String) {
        let form = ActionForm(title: LocalizedStringResource("branch.rename.title", defaultValue: "Rename \(RefName.branch(name))", bundle: .module), info: LocalizedStringResource("branch.rename.info", defaultValue: "The upstream and the worktree follow the new name. The remote keeps the old name.", bundle: .module), confirm: LocalizedStringResource("branch.rename.confirm", defaultValue: "Rename", bundle: .module))
        form.addField(key: "name", label: LocalizedStringResource("branch.rename.newName", defaultValue: "New name", bundle: .module), value: name)
        Task {
            guard let values = await runner.prompter.ask(form), let newName = values.value("name"), newName != name else { return }
            await runner.run(failure: LocalizedStringResource("failure.branch.notRenamed", defaultValue: "Branch not renamed", bundle: .module), note: "git branch -m") { try await $0.renameBranch(name, to: newName) }
        }
    }

    private func setUpstream(of ref: Ref) {
        let name = ref.name
        let remoteBranches = viewModel.refs.compactMap { candidate -> String? in
            guard case .remoteBranch = candidate.kind, !candidate.name.hasSuffix("/HEAD") else { return nil }
            return candidate.name
        }.sorted()
        let info: LocalizedStringResource = ref.upstream.map { upstream -> LocalizedStringResource in LocalizedStringResource("branch.upstream.infoCurrent", defaultValue: "Currently \(RefName.remoteBranch(upstream)). Leave empty to remove the upstream.", bundle: .module) } ?? LocalizedStringResource("branch.upstream.info", defaultValue: "The remote branch that \(RefName.branch(name)) is compared with and that Pull fetches from.", bundle: .module)
        let form = ActionForm(title: LocalizedStringResource("branch.upstream.title", defaultValue: "Upstream of \(RefName.branch(name))", bundle: .module), info: info, confirm: LocalizedStringResource("common.apply", defaultValue: "Apply", bundle: .module))
        let suggested = ref.upstream ?? remoteBranches.first { $0.hasSuffix("/" + name) } ?? ""
        form.addComboField(key: "upstream", label: LocalizedStringResource("branch.upstream.remoteBranch", defaultValue: "Remote branch", bundle: .module), value: suggested, suggestions: remoteBranches, required: ref.upstream == nil)
        Task {
            guard let values = await runner.prompter.ask(form) else { return }
            let upstream = values.value("upstream")
            guard upstream != ref.upstream else { return }
            await runner.run(failure: LocalizedStringResource("failure.upstream.notSet", defaultValue: "Upstream not set", bundle: .module), note: upstream == nil ? "git branch --unset-upstream" : "git branch --set-upstream-to") { try await $0.setUpstream(of: name, to: upstream) }
        }
    }

    private func createWorktree(for name: String) {
        let form = ActionForm(title: LocalizedStringResource("branch.createWorktree.title", defaultValue: "Create Worktree for \(RefName.branch(name))", bundle: .module), info: LocalizedStringResource("branch.createWorktree.info", defaultValue: "The branch is checked out in a folder of its own.", bundle: .module), confirm: LocalizedStringResource("common.create", defaultValue: "Create", bundle: .module))
        form.addFolderField(key: "path", label: LocalizedStringResource("common.folder", defaultValue: "Folder", bundle: .module), value: runner.defaultWorktreePath(suffix: name))
        Task {
            guard let values = await runner.prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            await runner.run(failure: LocalizedStringResource("failure.worktree.notCreated", defaultValue: "Worktree not created", bundle: .module), note: "git worktree add") { try await $0.addWorktree(at: path, branch: name) }
        }
    }

    /// A branch checked out in another worktree can only go together with that worktree.
    private func delete(_ name: String, worktree: Worktree?) {
        Task {
            if let worktree {
                let folder = (worktree.path as NSString).lastPathComponent
                let shownPath = (worktree.path as NSString).abbreviatingWithTildeInPath
                guard await runner.confirm(LocalizedStringResource("branch.deleteWithWorktree.title", defaultValue: "Delete \(RefName.branch(name)) and Worktree \(RefName.worktree(folder))?", bundle: .module), info: LocalizedStringResource("branch.deleteWithWorktree.info", defaultValue: "\(RefName.branch(name)) is checked out in the worktree \(RefName.worktree(folder)) and can only be deleted together with it. The folder \(RefName.path(shownPath)) will be removed.", bundle: .module), button: LocalizedStringResource("branch.deleteWithWorktree.confirm", defaultValue: "Delete Worktree and Branch", bundle: .module), destructive: true) else { return }
                guard await runner.removeWorktree(at: worktree.path) else { return }
            } else {
                guard await runner.confirm(LocalizedStringResource("branch.delete.title", defaultValue: "Delete \(RefName.branch(name))?", bundle: .module), info: LocalizedStringResource("branch.delete.info", defaultValue: "The local branch is deleted. A branch of the same name on the remote stays.", bundle: .module), button: LocalizedStringResource("common.delete", defaultValue: "Delete", bundle: .module), destructive: true) else { return }
            }
            await runner.deleteBranch(name)
        }
    }

    private func deleteRemote(_ branch: String, on remote: String) {
        Task {
            guard await runner.confirm(LocalizedStringResource("branch.deleteRemote.title", defaultValue: "Delete \(RefName.remoteBranch(branch)) from \(RefName.remote(remote))?", bundle: .module), info: LocalizedStringResource("branch.deleteRemote.info", defaultValue: "The branch is deleted on the remote, for everyone who works with it. Local branches stay.", bundle: .module), button: LocalizedStringResource("branch.deleteRemote.confirm", defaultValue: "Delete on Remote", bundle: .module), destructive: true) else { return }
            await runner.run(failure: LocalizedStringResource("failure.branch.remoteNotDeleted", defaultValue: "Remote branch not deleted", bundle: .module), note: "git push --delete") { try await $0.deleteRemoteBranch(branch, on: remote) }
        }
    }
}
