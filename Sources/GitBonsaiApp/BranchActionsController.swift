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
            let title: RefString = worktreeName.map { folder -> RefString in "Zu Worktree \(worktree: folder) wechseln" } ?? "\(branch: name) auschecken"
            checkoutGroup.append(ActionMenuItem(title) { [weak self] in self?.checkout(.localBranch(name), worktree?.path) })
            if let current = viewModel.currentBranch {
                historyGroup.append(ActionMenuItem("\(branch: name) in \(branch: current) mergen") { [weak self] in self?.merge(name, into: current) })
                historyGroup.append(ActionMenuItem("\(branch: current) auf \(branch: name) rebasen") { [weak self] in self?.rebase(current, onto: name) })
            }
        }
        var editGroup: [NSMenuItem] = [
            ActionMenuItem("Umbenennen …") { [weak self] in self?.rename(name) },
            ActionMenuItem(ref.upstream == nil ? "Upstream setzen …" : "Upstream ändern …") { [weak self] in self?.setUpstream(of: ref) },
        ]
        if !ref.isHead, worktree == nil {
            editGroup.append(ActionMenuItem("Worktree für \(branch: name) anlegen …") { [weak self] in self?.createWorktree(for: name) })
        }
        let copyGroup: [NSMenuItem] = [ActionMenuItem("Namen kopieren") { SidebarActionRunner.copy(name) }]
        let deleteGroup: [NSMenuItem] = ref.isHead ? [] : [ActionMenuItem("\(branch: name) löschen …") { [weak self] in self?.delete(name, worktree: worktree) }]
        return [checkoutGroup, historyGroup, editGroup, copyGroup, deleteGroup]
    }

    /// A local branch that follows this remote branch is offered a pull from it.
    private func remoteGroups(_ ref: Ref, remote: String, branch: String) -> [[NSMenuItem]] {
        let hasLocal = viewModel.refs.contains { $0.kind == .localBranch && $0.name == branch }
        var checkoutGroup: [NSMenuItem] = hasLocal ? [] : [ActionMenuItem("\(remoteBranch: ref.name) als lokalen Branch auschecken") { [weak self] in self?.checkout(.remoteBranch(remote: remote, branch: branch), nil) }]
        let followers = viewModel.refs.filter { $0.kind == .localBranch && $0.upstream == ref.name }
        checkoutGroup += followers.compactMap(branchPull.item(for:))
        return [
            checkoutGroup,
            [ActionMenuItem("Namen kopieren") { SidebarActionRunner.copy(ref.name) }],
            [ActionMenuItem("\(remoteBranch: branch) auf \(remote: remote) löschen …") { [weak self] in self?.deleteRemote(branch, on: remote) }],
        ]
    }

    // MARK: Actions

    private func merge(_ name: String, into current: String) {
        Task { await runner.run(failure: "Merge fehlgeschlagen", conflict: "Merge mit Konflikten angehalten", note: "git merge") { try await $0.merge(name) } }
    }

    private func rebase(_ current: String, onto name: String) {
        Task {
            let published = await viewModel.repository.publishedCommitCount(rewrittenBy: name)
            if published > 0 {
                let upstream = viewModel.status?.branch.upstream ?? "dem Upstream"
                let commits = published == 1 ? "Ein Commit, der dabei neu geschrieben wird, ist" : "\(published) Commits, die dabei neu geschrieben werden, sind"
                guard await runner.confirm("\(branch: current) auf \(branch: name) rebasen?", info: "\(commits) schon in \(remoteBranch: upstream). Danach lässt sich \(branch: current) nur noch mit Force-Push hochladen.", button: "Rebasen") else { return }
            }
            await runner.run(failure: "Rebase fehlgeschlagen", conflict: "Rebase mit Konflikten angehalten", note: "git rebase") { try await $0.rebaseCurrentBranch(onto: name) }
        }
    }

    private func rename(_ name: String) {
        let form = ActionForm(title: "\(branch: name) umbenennen", info: "Upstream und Worktree folgen dem neuen Namen. Auf dem Remote bleibt der alte Name.", confirm: "Umbenennen")
        form.addField(key: "name", label: "Neuer Name", value: name)
        Task {
            guard let values = await runner.prompter.ask(form), let newName = values.value("name"), newName != name else { return }
            await runner.run(failure: "Branch nicht umbenannt", note: "git branch -m") { try await $0.renameBranch(name, to: newName) }
        }
    }

    private func setUpstream(of ref: Ref) {
        let name = ref.name
        let remoteBranches = viewModel.refs.compactMap { candidate -> String? in
            guard case .remoteBranch = candidate.kind, !candidate.name.hasSuffix("/HEAD") else { return nil }
            return candidate.name
        }.sorted()
        let info: RefString = ref.upstream.map { upstream -> RefString in "Zurzeit \(remoteBranch: upstream). Leer lassen entfernt den Upstream." } ?? "Der Remote-Branch, mit dem \(branch: name) verglichen wird und von dem Pull holt."
        let form = ActionForm(title: "Upstream von \(branch: name)", info: info, confirm: "Übernehmen")
        let suggested = ref.upstream ?? remoteBranches.first { $0.hasSuffix("/" + name) } ?? ""
        form.addComboField(key: "upstream", label: "Remote-Branch", value: suggested, suggestions: remoteBranches, required: ref.upstream == nil)
        Task {
            guard let values = await runner.prompter.ask(form) else { return }
            let upstream = values.value("upstream")
            guard upstream != ref.upstream else { return }
            await runner.run(failure: "Upstream nicht gesetzt", note: upstream == nil ? "git branch --unset-upstream" : "git branch --set-upstream-to") { try await $0.setUpstream(of: name, to: upstream) }
        }
    }

    private func createWorktree(for name: String) {
        let form = ActionForm(title: "Worktree für \(branch: name) anlegen", info: "Der Branch wird in einem eigenen Ordner ausgecheckt.", confirm: "Anlegen")
        form.addFolderField(key: "path", label: "Ordner", value: runner.defaultWorktreePath(suffix: name))
        Task {
            guard let values = await runner.prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            await runner.run(failure: "Worktree nicht angelegt", note: "git worktree add") { try await $0.addWorktree(at: path, branch: name) }
        }
    }

    /// A branch checked out in another worktree can only go together with that worktree.
    private func delete(_ name: String, worktree: Worktree?) {
        Task {
            if let worktree {
                let folder = (worktree.path as NSString).lastPathComponent
                guard await runner.confirm("\(branch: name) und Worktree \(worktree: folder) löschen?", info: "\(branch: name) ist im Worktree \(worktree: folder) ausgecheckt und lässt sich nur zusammen mit ihm löschen. Der Ordner \(path: (worktree.path as NSString).abbreviatingWithTildeInPath) wird entfernt.", button: "Worktree und Branch löschen", destructive: true) else { return }
                guard await runner.removeWorktree(at: worktree.path) else { return }
            } else {
                guard await runner.confirm("\(branch: name) löschen?", info: "Der lokale Branch wird gelöscht. Ein gleichnamiger Branch auf dem Remote bleibt.", button: "Löschen", destructive: true) else { return }
            }
            await runner.deleteBranch(name)
        }
    }

    private func deleteRemote(_ branch: String, on remote: String) {
        Task {
            guard await runner.confirm("\(remoteBranch: branch) auf \(remote: remote) löschen?", info: "Der Branch wird auf dem Remote gelöscht, für alle, die damit arbeiten. Lokale Branches bleiben.", button: "Auf dem Remote löschen", destructive: true) else { return }
            await runner.run(failure: "Remote-Branch nicht gelöscht", note: "git push --delete") { try await $0.deleteRemoteBranch(branch, on: remote) }
        }
    }
}
