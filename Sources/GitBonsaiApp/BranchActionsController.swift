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

    /// The sidebar's menu of a branch. In a history menu (`inHistory`) the commit section offers Copy SHA and Create Worktree… instead, the latter preselecting the branch.
    func sections(for ref: Ref, inHistory: Bool = false) -> MenuSections {
        switch ref.kind {
        case .localBranch: localSections(ref, copySHA: !inHistory, createWorktree: !inHistory)
        case .remoteBranch(let remote): remoteSections(ref, remote: remote, branch: String(ref.name.dropFirst(remote.count + 1)), copySHA: !inHistory)
        default: MenuSections()
        }
    }

    // MARK: Menu

    /// Entries that would act on the branch itself through HEAD, or move the current branch onto itself, are left out for the checked-out branch.
    private func localSections(_ ref: Ref, copySHA: Bool, createWorktree: Bool) -> MenuSections {
        let name = ref.name
        let worktree = viewModel.branchesInOtherWorktrees[ref.fullName]
        let worktreeName = worktree.map { ($0.path as NSString).lastPathComponent }
        var sections = MenuSections()
        sections.integrate = fastForward.item(to: .ref(ref)).map { [$0] } ?? []
        if !ref.isHead {
            let title: LocalizedStringResource = worktreeName.map { folder -> LocalizedStringResource in LocalizedStringResource("worktree.action.switchTo", defaultValue: "Switch to Worktree \(RefName.worktree(folder))", bundle: .module) } ?? LocalizedStringResource("checkout.action.branch", defaultValue: "Checkout \(RefName.branch(name))", bundle: .module)
            sections.goThere.append(ActionMenuItem(title) { [weak self] in self?.checkout(.localBranch(name), worktree?.path) })
            // Merging or rebasing onto a descendant would only fast-forward, which the entry above does.
            if let current = viewModel.currentBranch, !fastForward.canFastForwardCurrent(to: ref.target) {
                sections.integrate.append(ActionMenuItem(LocalizedStringResource("branch.menu.merge", defaultValue: "Merge \(RefName.branch(name)) into \(RefName.branch(current))", bundle: .module)) { [weak self] in self?.merge(name, into: current) })
                sections.integrate.append(ActionMenuItem(LocalizedStringResource("branch.menu.rebase", defaultValue: "Rebase \(RefName.branch(current)) onto \(RefName.branch(name))", bundle: .module)) { [weak self] in self?.rebase(current, onto: name) })
            }
            if createWorktree, canCreateWorktree(for: ref) {
                sections.create.append(ActionMenuItem(LocalizedStringResource("commit.menu.createWorktree", defaultValue: "Create Worktree…", bundle: .module)) { [weak self] in self?.createWorktree(for: name) })
            }
        }
        sections.change = [
            ActionMenuItem(LocalizedStringResource("branch.menu.rename", defaultValue: "Rename…", bundle: .module)) { [weak self] in self?.rename(name) },
            ActionMenuItem(ref.upstream == nil ? LocalizedStringResource("branch.menu.setUpstream", defaultValue: "Set Upstream…", bundle: .module) : LocalizedStringResource("branch.menu.changeUpstream", defaultValue: "Change Upstream…", bundle: .module)) { [weak self] in self?.setUpstream(of: ref) },
        ]
        if let pull = branchPull.item(for: ref) { sections.change.append(pull) }
        sections.copy = Self.copyItems(ref, sha: copySHA)
        if !ref.isHead {
            sections.remove.append(ActionMenuItem(LocalizedStringResource("branch.menu.delete", defaultValue: "Delete \(RefName.branch(name))", bundle: .module)) { [weak self] in self?.delete(name, worktree: worktree) })
            if worktree == nil, hasRemoteCounterpart(ref) { sections.remove.append(deleteEverywhereItem(name)) }
        }
        return sections
    }

    /// A local branch that follows this remote branch is offered a pull from it.
    private func remoteSections(_ ref: Ref, remote: String, branch: String, copySHA: Bool) -> MenuSections {
        let hasLocal = viewModel.refs.contains { $0.kind == .localBranch && $0.name == branch }
        var sections = MenuSections()
        if !hasLocal {
            sections.goThere = [ActionMenuItem(LocalizedStringResource("checkout.action.asLocalBranch", defaultValue: "Checkout \(RefName.remoteBranch(ref.name)) as local Branch", bundle: .module)) { [weak self] in self?.checkout(.remoteBranch(remote: remote, branch: branch), nil) }]
        }
        sections.integrate = fastForward.item(to: .ref(ref)).map { [$0] } ?? []
        sections.change = viewModel.refs.filter { $0.kind == .localBranch && $0.upstream == ref.name }.compactMap(branchPull.item(for:))
        sections.copy = Self.copyItems(ref, sha: copySHA)
        sections.remove = [ActionMenuItem(LocalizedStringResource("branch.menu.deleteRemote", defaultValue: "Delete \(RefName.remoteBranch(branch)) from \(RefName.remote(remote))…", bundle: .module)) { [weak self] in self?.deleteRemote(branch, on: remote) }]
        return sections
    }

    /// A local branch checked out nowhere can get a worktree of its own.
    func canCreateWorktree(for ref: Ref) -> Bool {
        ref.kind == .localBranch && !ref.isHead && viewModel.branchesInOtherWorktrees[ref.fullName] == nil
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

    private static func copyItems(_ ref: Ref, sha: Bool) -> [NSMenuItem] {
        let name = ActionMenuItem(LocalizedStringResource("common.copyName", defaultValue: "Copy name", bundle: .module)) { ActionRunner.copy(ref.name) }
        guard sha else { return [name] }
        return [name, ActionMenuItem(LocalizedStringResource("common.copySHA", defaultValue: "Copy SHA", bundle: .module)) { ActionRunner.copy(ref.target) }]
    }

    // MARK: Actions

    private func merge(_ name: String, into current: String) {
        Task { await runner.run(failure: LocalizedStringResource("failure.merge.failed", defaultValue: "Merge failed", bundle: .module), conflict: LocalizedStringResource("failure.merge.conflicts", defaultValue: "Merge stopped on conflicts", bundle: .module), note: "git merge", focus: .followHead, undo: .head) { try await $0.merge(name) } }
    }

    /// Runs without asking, also when commits are already published: the status line offers Undo, and a later push says what it needs.
    private func rebase(_ current: String, onto name: String) {
        Task { await runner.run(failure: LocalizedStringResource("failure.rebase.failed", defaultValue: "Rebase failed", bundle: .module), conflict: LocalizedStringResource("failure.rebase.conflicts", defaultValue: "Rebase stopped on conflicts", bundle: .module), note: "git rebase", focus: .followHead, undo: .head) { try await $0.rebaseCurrentBranch(onto: name) } }
    }

    private func rename(_ name: String) {
        let form = ActionForm(title: LocalizedStringResource("branch.rename.title", defaultValue: "Rename \(RefName.branch(name))", bundle: .module), confirm: LocalizedStringResource("branch.rename.confirm", defaultValue: "Rename", bundle: .module))
        form.addField(key: "name", label: LocalizedStringResource("branch.rename.newName", defaultValue: "New name", bundle: .module), value: name)
        Task {
            guard let values = await runner.prompter.ask(form), let newName = values.value("name"), newName != name else { return }
            await runner.run(failure: LocalizedStringResource("failure.branch.notRenamed", defaultValue: "Branch not renamed", bundle: .module), note: "git branch -m") { try await $0.renameBranch(name, to: newName) }
        }
    }

    /// A remote branch from the picker becomes the upstream; with an upstream set, a checkbox removes it instead.
    private func setUpstream(of ref: Ref) {
        let name = ref.name
        let repository = viewModel.repository
        let form = ActionForm(title: LocalizedStringResource("branch.upstream.title", defaultValue: "Upstream of \(RefName.branch(name))", bundle: .module), confirm: LocalizedStringResource("common.apply", defaultValue: "Apply", bundle: .module))
        Task {
            let tips = (try? await repository.refTips()) ?? []
            let catalog = RefCatalog.remoteBranches(tips)
            let suggested = ref.upstream ?? catalog.groups(matching: "").flatMap(\.matches).map(\.item.title).first { $0.hasSuffix("/" + name) } ?? ""
            form.addRefPicker(key: "upstream", label: LocalizedStringResource("branch.upstream.remoteBranch", defaultValue: "Remote branch", bundle: .module), repository: repository, catalog: catalog, selection: catalog.item(titled: suggested))
            if ref.upstream != nil { form.addCheckbox(LocalizedStringResource("branch.upstream.remove", defaultValue: "Remove upstream", bundle: .module), checked: false) }
            guard let values = await runner.prompter.ask(form) else { return }
            let upstream = values.isChecked ? nil : values.value("upstream")
            guard upstream != ref.upstream else { return }
            await runner.run(failure: LocalizedStringResource("failure.upstream.notSet", defaultValue: "Upstream not set", bundle: .module), note: upstream == nil ? "git branch --unset-upstream" : "git branch --set-upstream-to") { try await $0.setUpstream(of: name, to: upstream) }
        }
    }

    func createWorktree(for name: String) {
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
