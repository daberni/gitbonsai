import AppKit
import GitEngine

/// The context menu of a local or remote branch, in the sidebar and on its history pill, and running its actions.
@MainActor
final class BranchActionsController {
    private let runner: SidebarActionRunner
    private let checkout: (CheckoutTarget, _ worktreePath: String?) -> Void
    private let branchPull: BranchPullController
    private let fastForward: FastForwardController
    private var viewModel: GraphViewModel { runner.viewModel }

    init(runner: SidebarActionRunner, branchPull: BranchPullController, fastForward: FastForwardController, checkout: @escaping (CheckoutTarget, _ worktreePath: String?) -> Void) {
        self.runner = runner
        self.branchPull = branchPull
        self.fastForward = fastForward
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
        var historyGroup = fastForward.items(to: .ref(ref))
        if let pull = branchPull.item(for: ref) { checkoutGroup.append(pull) }
        if !ref.isHead {
            let title: LocalizedStringResource = worktreeName.map { folder -> LocalizedStringResource in LocalizedStringResource("worktree.action.switchTo", defaultValue: "Switch to Worktree \(RefName.worktree(folder))", bundle: .module) } ?? LocalizedStringResource("checkout.action.branch", defaultValue: "Checkout \(RefName.branch(name))", bundle: .module)
            checkoutGroup.append(ActionMenuItem(title) { [weak self] in self?.checkout(.localBranch(name), worktree?.path) })
            // Merging or rebasing onto a descendant would only fast-forward, which the entry above does.
            if let current = viewModel.currentBranch, !fastForward.canFastForwardCurrent(to: ref.target) {
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
        let copyGroup = Self.copyItems(ref)
        var deleteGroup: [NSMenuItem] = []
        if !ref.isHead {
            deleteGroup.append(ActionMenuItem(LocalizedStringResource("branch.menu.delete", defaultValue: "Delete \(RefName.branch(name))", bundle: .module)) { [weak self] in self?.delete(name, worktree: worktree) })
            if worktree == nil, hasRemoteCounterpart(ref) { deleteGroup.append(deleteEverywhereItem(name)) }
        }
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
            fastForward.items(to: .ref(ref)),
            Self.copyItems(ref),
            [ActionMenuItem(LocalizedStringResource("branch.menu.deleteRemote", defaultValue: "Delete \(RefName.remoteBranch(branch)) from \(RefName.remote(remote))…", bundle: .module)) { [weak self] in self?.deleteRemote(branch, on: remote) }],
        ]
    }

    /// A remote has a branch of that name, or the branch tracks one.
    private func hasRemoteCounterpart(_ ref: Ref) -> Bool {
        ref.upstream != nil || viewModel.refs.contains { candidate in
            guard case .remoteBranch(let remote) = candidate.kind else { return false }
            return candidate.name == "\(remote)/\(ref.name)"
        }
    }

    func deleteEverywhereItem(_ name: String) -> NSMenuItem {
        ActionMenuItem(LocalizedStringResource("branch.menu.deleteBranches", defaultValue: "Delete Branches…", bundle: .module)) { [weak self] in self?.deleteEverywhere(name) }
    }

    private static func copyItems(_ ref: Ref) -> [NSMenuItem] {
        [
            ActionMenuItem(LocalizedStringResource("common.copyName", defaultValue: "Copy name", bundle: .module)) { ActionRunner.copy(ref.name) },
            ActionMenuItem(LocalizedStringResource("common.copySHA", defaultValue: "Copy SHA", bundle: .module)) { ActionRunner.copy(ref.target) },
        ]
    }

    // MARK: Actions

    private func merge(_ name: String, into current: String) {
        Task { await runner.run(failure: LocalizedStringResource("failure.merge.failed", defaultValue: "Merge failed", bundle: .module), conflict: LocalizedStringResource("failure.merge.conflicts", defaultValue: "Merge stopped on conflicts", bundle: .module), note: "git merge", undo: .head) { try await $0.merge(name) } }
    }

    /// Runs without asking, also when commits are already published: the status line offers Undo, and a later push says what it needs.
    private func rebase(_ current: String, onto name: String) {
        Task { await runner.run(failure: LocalizedStringResource("failure.rebase.failed", defaultValue: "Rebase failed", bundle: .module), conflict: LocalizedStringResource("failure.rebase.conflicts", defaultValue: "Rebase stopped on conflicts", bundle: .module), note: "git rebase", undo: .head) { try await $0.rebaseCurrentBranch(onto: name) } }
    }

    private func rename(_ name: String) {
        let form = ActionForm(title: LocalizedStringResource("branch.rename.title", defaultValue: "Rename \(RefName.branch(name))", bundle: .module), confirm: LocalizedStringResource("branch.rename.confirm", defaultValue: "Rename", bundle: .module))
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
        // Clearing the field is how this form removes the upstream; nothing else says so.
        let info: LocalizedStringResource? = ref.upstream == nil ? nil : LocalizedStringResource("branch.upstream.infoCurrent", defaultValue: "Leave empty to remove the upstream.", bundle: .module)
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
        let form = ActionForm(title: LocalizedStringResource("branch.createWorktree.title", defaultValue: "Create Worktree for \(RefName.branch(name))", bundle: .module), confirm: LocalizedStringResource("common.create", defaultValue: "Create", bundle: .module))
        form.addFolderField(key: "path", label: LocalizedStringResource("common.folder", defaultValue: "Folder", bundle: .module), value: runner.defaultWorktreePath(suffix: name))
        Task {
            guard let values = await runner.prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            await runner.run(failure: LocalizedStringResource("failure.worktree.notCreated", defaultValue: "Worktree not created", bundle: .module), note: "git worktree add") { try await $0.addWorktree(at: path, branch: name) }
        }
    }

    /// A branch checked out in another worktree can only go together with that worktree, which is asked for. A merged branch goes without asking and can be undone; an unmerged one asks first.
    private func delete(_ name: String, worktree: Worktree?) {
        Task {
            if let worktree {
                let folder = (worktree.path as NSString).lastPathComponent
                guard await runner.confirm(LocalizedStringResource("branch.deleteWithWorktree.title", defaultValue: "Delete Branch and Worktree?", bundle: .module), names: RefString(marked: RefName.branch(name) + " " + RefName.worktree(folder)), button: LocalizedStringResource("branch.deleteWithWorktree.confirm", defaultValue: "Delete Worktree and Branch", bundle: .module), destructive: true) else { return }
                guard await runner.removeWorktree(at: worktree.path) else { return }
            }
            await runner.deleteBranch(name)
        }
    }

    private func deleteRemote(_ branch: String, on remote: String) {
        Task {
            guard await runner.confirm(LocalizedStringResource("branch.deleteRemote.title", defaultValue: "Delete Remote Branch?", bundle: .module), names: RefString(marked: RefName.remoteBranch("\(remote)/\(branch)")), button: LocalizedStringResource("branch.deleteRemote.confirm", defaultValue: "Delete on Remote", bundle: .module), destructive: true) else { return }
            await runner.run(failure: LocalizedStringResource("failure.branch.remoteNotDeleted", defaultValue: "Remote branch not deleted", bundle: .module), note: "git push --delete") { try await $0.deleteRemoteBranch(branch, on: remote) }
        }
    }

    /// The local branch and its counterparts on every remote, after a sheet that lists each with its commit and whether it holds commits found nowhere else.
    func deleteEverywhere(_ name: String) {
        Task {
            let deletion: BranchDeletion
            do {
                deletion = try await viewModel.repository.branchDeletion(of: name)
            } catch {
                return runner.prompter.report(error, title: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module))
            }
            guard let targets = await DeleteEverywhereSheet.ask(deletion, prompter: runner.prompter), !targets.isEmpty else { return }
            let note = targets.map(\.commandLine).joined(separator: " && ")
            await runner.run(failure: LocalizedStringResource("failure.branch.notAllDeleted", defaultValue: "Not all Branches deleted", bundle: .module), note: note) { try await $0.delete(targets) }
        }
    }
}
