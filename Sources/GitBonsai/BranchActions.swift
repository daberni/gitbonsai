import AppKit
import GitEngine

/// The context menu of a local or remote branch, in the sidebar and on its history pill, and running its actions.
@MainActor
final class BranchActions {
    private let runner: ActionRunner
    private let prompter: any Prompting
    private let pasteboard: Pasteboard
    private let checkout: (CheckoutTarget, _ worktreePath: String?) -> Void
    private let pullUseCase: PullUseCase
    private let pushUseCase: PushUseCase
    private let fastForward: FastForwardUseCase
    private let rebaseOnto: RebaseOntoUseCase
    private let viewModel: GraphViewModel

    init(context: RepositoryContext, pull: PullUseCase, push: PushUseCase, fastForward: FastForwardUseCase, rebaseOnto: RebaseOntoUseCase, checkout: @escaping (CheckoutTarget, _ worktreePath: String?) -> Void) {
        viewModel = context.model
        runner = context.runner
        prompter = context.prompter
        pasteboard = context.app.pasteboard
        pullUseCase = pull
        pushUseCase = push
        self.fastForward = fastForward
        self.rebaseOnto = rebaseOnto
        self.checkout = checkout
    }

    /// The menu of a local or remote branch. In the history the commit section offers Copy SHA, Create Worktree… (preselecting the branch) and the rebase onto the commit instead.
    /// In the history a remote branch whose local branch of the same name sits on the same commit is shown with it; it keeps only what the local branch's entries do not cover: Delete Branches…, Pull and the copy group already reach it.
    func sections(for ref: Ref, in context: MenuContext) -> MenuSections {
        let inHistory = context.isHistory
        switch ref.kind {
        case .localBranch: return localSections(ref, inHistory: inHistory)
        case .remoteBranch(let remote):
            let branch = String(ref.name.dropFirst(remote.count + 1))
            let counterpart = inHistory && (viewModel.refsByCommit[ref.target] ?? []).contains { $0.kind == .localBranch && $0.name == branch }
            return remoteSections(ref, remote: remote, branch: branch, inHistory: inHistory, counterpart: counterpart)
        default: return MenuSections()
        }
    }

    // MARK: Menu

    /// Entries that would act on the branch itself through HEAD, or move the current branch onto itself, are left out for the checked-out branch.
    private func localSections(_ ref: Ref, inHistory: Bool) -> MenuSections {
        let name = ref.name
        let worktree = viewModel.branchesInOtherWorktrees[ref.fullName]
        let worktreeName = worktree.map { ($0.path as NSString).lastPathComponent }
        var sections = MenuSections()
        sections.integrate = [fastForward.entry(to: .ref(ref))?.movingHead, fastForward.toHeadEntry(for: ref)].compactMap { $0 }
        if !ref.isHead {
            let title: LocalizedStringResource = worktreeName.map { folder -> LocalizedStringResource in LocalizedStringResource("worktree.action.switchTo", defaultValue: "Switch to Worktree \(RefName.worktree(folder))", bundle: .module) } ?? LocalizedStringResource("checkout.action.branch", defaultValue: "Checkout \(RefName.branch(name))", bundle: .module)
            sections.goThere.append(MenuEntry(title) { [weak self] in self?.checkout(.localBranch(name), worktree?.path) }.movingHead)
            sections.integrate += integrateItems(ref, inHistory: inHistory)
            if !inHistory, canCreateWorktree(for: ref) {
                sections.create.append(MenuEntry(LocalizedStringResource("commit.menu.createWorktree", defaultValue: "Create Worktree…", bundle: .module)) { [weak self] in self?.createWorktree(for: name) })
            }
        }
        sections.sync = [pullUseCase.entry(for: ref)?.movingHead, pushUseCase.entry(for: ref)].compactMap { $0 }
        sections.change = [
            MenuEntry(LocalizedStringResource("branch.menu.rename", defaultValue: "Rename…", bundle: .module)) { [weak self] in self?.rename(name) },
            MenuEntry(ref.upstream == nil ? LocalizedStringResource("branch.menu.setUpstream", defaultValue: "Set Upstream…", bundle: .module) : LocalizedStringResource("branch.menu.changeUpstream", defaultValue: "Change Upstream…", bundle: .module)) { [weak self] in self?.setUpstream(of: ref) },
        ]
        sections.copy = copyItems(ref, sha: !inHistory)
        if !ref.isHead {
            // Deleting asks only for a branch with commits found nowhere else or one checked out in another worktree; only then the entry ends in an ellipsis.
            let asks = worktree != nil || !viewModel.isReachableFromHead(ref.target)
            let title: LocalizedStringResource = asks ? LocalizedStringResource("branch.menu.deleteAsking", defaultValue: "Delete \(RefName.branch(name))…", bundle: .module) : LocalizedStringResource("branch.menu.delete", defaultValue: "Delete \(RefName.branch(name))", bundle: .module)
            sections.remove.append(MenuEntry(title) { [weak self] in self?.delete(name, worktree: worktree) })
            if worktree == nil, hasRemoteCounterpart(ref) { sections.remove.append(deleteEverywhereItem(name)) }
        }
        return sections
    }

    /// Merge and Rebase of the current branch onto a branch that has commits it lacks. Nothing when HEAD already contains the branch, and nothing beyond the fast-forward when the branch contains HEAD.
    /// The rebase is the history's one-click rebase onto the branch's tip; in the history the commit section offers it.
    private func integrateItems(_ ref: Ref, inHistory: Bool) -> [MenuEntry] {
        guard let current = viewModel.currentBranch, !fastForward.canFastForwardCurrent(to: ref.target), !viewModel.isReachableFromHead(ref.target) else { return [] }
        let name = ref.name
        let isRemote = ref.kind != .localBranch
        let mergeTitle: LocalizedStringResource = isRemote ? LocalizedStringResource("branch.menu.mergeRemote", defaultValue: "Merge \(RefName.remoteBranch(name)) into \(RefName.branch(current))", bundle: .module) : LocalizedStringResource("branch.menu.merge", defaultValue: "Merge \(RefName.branch(name)) into \(RefName.branch(current))", bundle: .module)
        var items = [MenuEntry(mergeTitle) { [weak self] in self?.merge(name, into: current) }.movingHead]
        if !inHistory {
            let rebaseTitle: LocalizedStringResource = isRemote ? LocalizedStringResource("branch.menu.rebaseRemote", defaultValue: "Rebase \(RefName.branch(current)) onto \(RefName.remoteBranch(name))", bundle: .module) : LocalizedStringResource("branch.menu.rebase", defaultValue: "Rebase \(RefName.branch(current)) onto \(RefName.branch(name))", bundle: .module)
            items.append(MenuEntry(rebaseTitle) { [weak self] in self?.rebaseOnto.rebase(current, onto: ref) }.movingHead)
        }
        return items
    }

    /// Checking out a remote branch goes to the local branch of the same name, which is created to track it when there is none.
    /// A local branch following this remote branch is offered a pull from it.
    private func remoteSections(_ ref: Ref, remote: String, branch: String, inHistory: Bool, counterpart: Bool) -> MenuSections {
        let local = viewModel.refs.first { $0.kind == .localBranch && $0.name == branch }
        var sections = MenuSections()
        // Beside its local branch on the same commit, the local branch's own Checkout covers it.
        if local?.isHead != true, !counterpart {
            let worktree = local.flatMap { viewModel.branchesInOtherWorktrees[$0.fullName] }
            let target: CheckoutTarget = local == nil ? .remoteBranch(remote: remote, branch: branch) : .localBranch(branch)
            sections.goThere = [MenuEntry(LocalizedStringResource("checkout.action.branch", defaultValue: "Checkout \(RefName.branch(branch))", bundle: .module)) { [weak self] in self?.checkout(target, worktree?.path) }.movingHead]
        }
        sections.integrate = fastForward.entry(to: .ref(ref)).map { [$0.movingHead] } ?? []
        guard !counterpart else { return sections }
        sections.integrate += integrateItems(ref, inHistory: inHistory)
        sections.sync = viewModel.refs.filter { $0.kind == .localBranch && $0.upstream == ref.name }.compactMap { pullUseCase.entry(for: $0)?.movingHead }
        sections.copy = copyItems(ref, sha: !inHistory)
        sections.remove = [MenuEntry(LocalizedStringResource("branch.menu.deleteAsking", defaultValue: "Delete \(RefName.remoteBranch(ref.name))…", bundle: .module)) { [weak self] in self?.deleteRemote(branch, on: remote) }]
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

    func deleteEverywhereItem(_ name: String) -> MenuEntry {
        MenuEntry(LocalizedStringResource("branch.menu.deleteBranches", defaultValue: "Delete Branches…", bundle: .module)) { [weak self] in self?.deleteEverywhere(name) }
    }

    /// "Copy <branch>" copies the ref's own name, also where remotes have a branch of the same name.
    private func copyItems(_ ref: Ref, sha: Bool) -> [MenuEntry] {
        let name = MenuEntry(LocalizedStringResource("branch.menu.copyName", defaultValue: "Copy \(RefMenus.pillName(of: ref))", bundle: .module)) { [pasteboard] in pasteboard.copy(ref.name) }
        guard sha else { return [name] }
        return [name, .copySHA(ref.target, to: pasteboard)]
    }

    // MARK: Actions

    private func merge(_ name: String, into current: String) {
        Task { await runner.perform(failure: LocalizedStringResource("failure.merge.failed", defaultValue: "Merge failed", bundle: .module), conflict: LocalizedStringResource("failure.merge.conflicts", defaultValue: "Merge stopped on conflicts", bundle: .module), note: "git merge", focus: .followHead, undo: .head) { try await $0.merge(name) } }
    }

    private func rename(_ name: String) {
        let form = ActionForm(title: LocalizedStringResource("branch.rename.title", defaultValue: "Rename \(RefName.branch(name))", bundle: .module), confirm: LocalizedStringResource("branch.rename.confirm", defaultValue: "Rename", bundle: .module))
        form.addField(key: "name", label: LocalizedStringResource("branch.rename.newName", defaultValue: "New name", bundle: .module), value: name)
        Task {
            guard let values = await prompter.ask(form), let newName = values.value("name"), newName != name else { return }
            await runner.perform(failure: LocalizedStringResource("failure.branch.notRenamed", defaultValue: "Branch not renamed", bundle: .module), note: "git branch -m") { try await $0.renameBranch(name, to: newName) }
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
            guard let values = await prompter.ask(form) else { return }
            let upstream = values.isChecked ? nil : values.value("upstream")
            guard upstream != ref.upstream else { return }
            await runner.perform(failure: LocalizedStringResource("failure.upstream.notSet", defaultValue: "Upstream not set", bundle: .module), note: upstream == nil ? "git branch --unset-upstream" : "git branch --set-upstream-to") { try await $0.setUpstream(of: name, to: upstream) }
        }
    }

    func createWorktree(for name: String) {
        let form = ActionForm(title: LocalizedStringResource("branch.createWorktree.title", defaultValue: "Create Worktree for \(RefName.branch(name))", bundle: .module), confirm: LocalizedStringResource("common.create", defaultValue: "Create", bundle: .module))
        form.addFolderField(key: "path", label: LocalizedStringResource("common.folder", defaultValue: "Folder", bundle: .module), value: viewModel.defaultWorktreePath(suffix: name))
        Task {
            guard let values = await prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            await runner.perform(failure: LocalizedStringResource("failure.worktree.notCreated", defaultValue: "Worktree not created", bundle: .module), note: "git worktree add") { try await $0.addWorktree(at: path, branch: name) }
        }
    }

    /// A branch checked out in another worktree can only go together with that worktree, which is asked for. A merged branch goes without asking and can be undone; an unmerged one asks first.
    private func delete(_ name: String, worktree: Worktree?) {
        Task {
            if let worktree {
                let folder = (worktree.path as NSString).lastPathComponent
                guard await runner.confirm(LocalizedStringResource("branch.deleteWithWorktree.title", defaultValue: "Delete Branch and Worktree?", bundle: .module), names: RefString(marked: RefName.branch(name) + " " + RefName.worktree(folder)), button: LocalizedStringResource("branch.deleteWithWorktree.confirm", defaultValue: "Delete Worktree and Branch", bundle: .module), destructive: true, style: .informational) else { return }
                guard await runner.removeWorktree(at: worktree.path) else { return }
            }
            await runner.deleteBranch(name)
        }
    }

    private func deleteRemote(_ branch: String, on remote: String) {
        Task {
            guard await runner.confirm(LocalizedStringResource("branch.deleteRemote.title", defaultValue: "Delete Remote Branch?", bundle: .module), names: RefString(marked: RefName.remoteBranch("\(remote)/\(branch)")), button: LocalizedStringResource("branch.deleteRemote.confirm", defaultValue: "Delete on Remote", bundle: .module), destructive: true, style: .informational) else { return }
            await runner.perform(failure: LocalizedStringResource("failure.branch.remoteNotDeleted", defaultValue: "Remote branch not deleted", bundle: .module), note: "git push --delete") { try await $0.deleteRemoteBranch(branch, on: remote) }
        }
    }

    /// The local branch and its counterparts on every remote, after a sheet that lists each with its commit and whether it holds commits found nowhere else.
    func deleteEverywhere(_ name: String) {
        Task {
            let deletion: BranchDeletion
            do {
                deletion = try await viewModel.repository.branchDeletion(of: name)
            } catch {
                return prompter.report(error, title: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module))
            }
            guard let targets = await DeleteEverywhereSheet.ask(deletion, prompter: prompter), !targets.isEmpty else { return }
            let note = targets.map(\.commandLine).joined(separator: " && ")
            await runner.perform(failure: LocalizedStringResource("failure.branch.notAllDeleted", defaultValue: "Not all Branches deleted", bundle: .module), note: note) { try await $0.delete(targets) }
        }
    }
}
