import AppKit
import GitEngine

/// Pulling: the checked-out branch with the toolbar's modes, and any local branch from its menu. A branch that is not checked out is only ever fast-forwarded; a diverged one is left alone with a way out offered.
@MainActor
final class PullUseCase {
    let prompter: any Prompting
    let status: UpstreamStatus
    private let viewModel: GraphViewModel
    /// Moves the tab to another worktree, like a double click on it in the sidebar.
    var onSwitchWorktree: ((String) -> Void)?

    init(context: RepositoryContext, status: UpstreamStatus) {
        viewModel = context.model
        prompter = context.prompter
        self.status = status
    }

    private var branch: String? { status.branch }
    private var upstream: Upstream? { status.upstream }
    var defaultMode: PullMode { status.defaultMode }

    // MARK: Menus

    /// With an upstream: the three modes, the default marked and first; every mode carries local changes. Without one: setting it.
    func groups() -> [[MenuEntry]] {
        guard let branch, let upstream else {
            let header = MenuEntry.header(branch.map { name -> LocalizedStringResource in LocalizedStringResource("pull.menu.noUpstream", defaultValue: "\(RefName.branch(name)) has no upstream", bundle: .module) } ?? LocalizedStringResource("pull.menu.headNoUpstream", defaultValue: "HEAD has no upstream", bundle: .module))
            var set = MenuEntry(LocalizedStringResource("pull.action.setUpstreamAndPull", defaultValue: "Set Upstream and Pull…", bundle: .module)) { [weak self] in self?.setUpstreamAndPull() }
            set.isDisabled = branch == nil || remoteBranches().isEmpty
            return [[header, set]]
        }
        let header = MenuEntry.header(LocalizedStringResource("pull.menu.header", defaultValue: "Pull \(RefName.remoteBranch(upstream.name)) into \(RefName.branch(branch))", bundle: .module))
        let modes = [defaultMode] + PullMode.allCases.filter { $0 != defaultMode }
        let entries = modes.map { mode in
            var entry = pullEntry(Self.title(of: mode), PullVariant(mode: mode))
            if mode == defaultMode { entry.marker = String(localized: "common.default", defaultValue: "Default", bundle: .module, comment: "Marks the default app in the list of editors or terminals.") }
            return entry
        }
        return [[header] + entries]
    }

    private static func title(of mode: PullMode) -> LocalizedStringResource {
        switch mode {
        case .fastForwardOnly: LocalizedStringResource("pull.menu.fastForwardOnly", defaultValue: "Fast-forward only", bundle: .module)
        case .merge: LocalizedStringResource("pull.mode.merge", defaultValue: "Merge", bundle: .module, comment: "Pull mode.")
        case .rebase: LocalizedStringResource("pull.mode.rebase", defaultValue: "Rebase", bundle: .module, comment: "Pull mode.")
        }
    }

    /// "Pull <branch>" for a local branch with an upstream, nil for anything else.
    func entry(for ref: Ref) -> MenuEntry? {
        guard ref.kind == .localBranch, let upstream = ref.upstream else { return nil }
        let name = ref.name
        var item = MenuEntry(LocalizedStringResource("branch.menu.pull", defaultValue: "Pull \(RefName.branch(name))", bundle: .module)) { [weak self] in self?.pull(name) }
        item.toolTip = String(localized: "branch.pull.toolTip", defaultValue: "Fetches \(upstream) and fast-forwards \(name) when that works without a merge.", bundle: .module)
        return item
    }

    private func pullEntry(_ title: LocalizedStringResource, _ variant: PullVariant) -> MenuEntry {
        var entry = MenuEntry(title) { [weak self] in self?.pull(variant) }
        entry.toolTip = variant.commandLine
        return entry
    }

    // MARK: Current branch

    func pull(_ variant: PullVariant) {
        Task { await performPull(variant) }
    }

    /// Pulls and refreshes the tab; true when the pull went through. Local changes come along through `--autostash`: when they conflict on the way back, the working directory shows the conflicts, and the status line and a toast say so, without a sheet.
    @discardableResult
    func performPull(_ variant: PullVariant) async -> Bool {
        await viewModel.remoteActivity.run(.pull) { [self] in await pullAndRefresh(variant) }
    }

    private func pullAndRefresh(_ variant: PullVariant) async -> Bool {
        let repository = viewModel.repository
        let upstreamName = upstream?.name ?? String(localized: "pull.diverged.upstreamName", defaultValue: "Upstream", bundle: .module, comment: "Stands for the upstream branch when its name is unknown.")
        do {
            let result = try await repository.pull(variant)
            await viewModel.refresh(note: variant.commandLine + (result.localChangesConflicted ? " · " + Self.conflictedChanges : ""), focus: .followHead)
            if result.localChangesConflicted { prompter.toast(RefString(LocalizedStringResource("pull.toast.doneWithConflicts", defaultValue: "Pull done, local changes brought back with conflicts, stash “autostash” stays", bundle: .module)), action: prompter.showConflictsAction) }
            return true
        } catch is CancellationError {
            await viewModel.refreshAfterCancel(variant.commandLine, focus: .followHead)
        } catch let error as GitError where error.isDivergedPull {
            await viewModel.refresh(note: nil, focus: .followHead)
            await offerRebase(after: error, upstream: upstreamName)
        } catch {
            await viewModel.refresh(note: nil, focus: .followHead)
            let stopped = (error as? GitError)?.stoppedOnConflict == true
            await prompter.reportUnlessStopped(error, title: stopped ? LocalizedStringResource("failure.pull.conflicts", defaultValue: "Pull stopped on conflicts", bundle: .module) : LocalizedStringResource("failure.pull.failed", defaultValue: "Pull failed", bundle: .module), actions: [], in: repository)
        }
        return false
    }

    /// The status line after a pull whose carried changes conflicted on the way back.
    static let conflictedChanges = String(localized: "pull.toast.conflictedChanges", defaultValue: "local changes brought back with conflicts, stash “autostash” stays", bundle: .module, comment: "Status line after a pull, after the git command.")

    /// A fast-forward-only pull found commits on both sides; the local ones can go on top of the upstream, or the two can be merged.
    /// The pull fetched first, so the counts are read again rather than taken from before it.
    private func offerRebase(after error: GitError, upstream: String) async {
        let fresh: Upstream? = if let branch { await viewModel.repository.upstream(of: branch) } else { nil }
        let summary: LocalizedStringResource = if let ahead = fresh?.ahead, let behind = fresh?.behind {
            LocalizedStringResource("pull.diverged.infoCounts", defaultValue: "Local commits: \(ahead), new on \(RefName.remoteBranch(upstream)): \(behind).", bundle: .module)
        } else {
            .verbatim(RefString(verbatim: ""))
        }
        prompter.showSheet(title: LocalizedStringResource("pull.diverged.title", defaultValue: "Branches have diverged", bundle: .module), summary: summary, details: GitFailureText.details(of: error), actions: [
            FailureAction(title: LocalizedStringResource("pull.diverged.rebase", defaultValue: "Pull using rebase", bundle: .module)) { [weak self] in self?.pull(PullVariant(mode: .rebase)) },
            FailureAction(title: LocalizedStringResource("pull.diverged.merge", defaultValue: "Pull using merge", bundle: .module)) { [weak self] in self?.pull(PullVariant(mode: .merge)) },
        ])
    }

    /// Asks for a remote branch, makes it the upstream and pulls with the default mode.
    func setUpstreamAndPull() {
        guard let branch else { return }
        let candidates = remoteBranches()
        let preferred = candidates.first { $0 == "origin/\(branch)" } ?? candidates.first { $0.hasSuffix("/\(branch)") } ?? candidates.first ?? ""
        let form = ActionForm(title: LocalizedStringResource("pull.setUpstream.title", defaultValue: "Set Upstream for \(RefName.branch(branch))", bundle: .module), confirm: LocalizedStringResource("pull.setUpstream.confirm", defaultValue: "Set and Pull", bundle: .module))
        let repository = viewModel.repository
        Task {
            let catalog = RefCatalog.remoteBranches((try? await repository.refTips()) ?? [])
            form.addRefPicker(key: "upstream", label: LocalizedStringResource("pull.setUpstream.field", defaultValue: "Upstream", bundle: .module, comment: "Field label: the upstream branch."), repository: repository, catalog: catalog, selection: catalog.item(titled: preferred))
            guard let values = await prompter.ask(form), let upstream = values.value("upstream") else { return }
            do {
                try await viewModel.repository.setUpstream(of: branch, to: upstream)
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.upstream.notSet", defaultValue: "Upstream not set", bundle: .module))
                return
            }
            pull(PullVariant(mode: defaultMode))
        }
    }

    func remoteBranches() -> [String] {
        viewModel.refs.filter { if case .remoteBranch = $0.kind { !$0.name.hasSuffix("/HEAD") } else { false } }.map(\.name).sorted()
    }

    // MARK: Any branch

    func pull(_ branch: String) {
        let repository = viewModel.repository
        Task {
            let result: BranchPullResult
            do {
                result = try await repository.fastForwardBranch(branch)
            } catch BranchPullError.isCurrentBranch {
                pull(PullVariant(mode: defaultMode))
                return
            } catch {
                await viewModel.refresh(note: nil, focus: .followHead)
                prompter.report(error, title: LocalizedStringResource("failure.branch.notPulled", defaultValue: "\(RefName.branch(branch)) not pulled", bundle: .module))
                return
            }
            // The pull needed the upstream, so only a race can lose it here; git's own name for it stands in then.
            let upstream = await repository.upstream(of: branch)?.name ?? "\(branch)@{upstream}"
            switch result.outcome {
            case .fastForwarded(let commits):
                let summary = Self.fastForwarded(branch, by: commits, to: upstream, place: result.place, conflicted: result.localChangesConflicted)
                await viewModel.refresh(note: summary.plain + " · " + result.commandLine, focus: .followHead)
                prompter.toast(summary)
            case .upToDate(let ahead):
                let summary: RefString = if ahead > 0 {
                    RefString(LocalizedStringResource("branch.pull.upToDateUnpushed", defaultValue: "\(RefName.branch(branch)) is up to date with \(RefName.remoteBranch(upstream)), \(ahead) local commits not pushed yet", bundle: .module))
                } else {
                    RefString(LocalizedStringResource("branch.pull.upToDate", defaultValue: "\(RefName.branch(branch)) is up to date with \(RefName.remoteBranch(upstream))", bundle: .module))
                }
                await viewModel.refresh(note: summary.plain + " · " + result.commandLine)
                prompter.toast(summary)
            case .diverged(let ahead, let behind):
                let diverged = String(localized: "branch.pull.diverged", defaultValue: "\(branch) has diverged from \(upstream)", bundle: .module, comment: "Status line; the arguments are a local branch and its upstream.")
                await viewModel.refresh(note: diverged + " · " + result.commandLine)
                await offerWayOut(branch: branch, upstream: upstream, ahead: ahead, behind: behind, place: result.place)
            }
        }
    }

    /// A pull in another worktree carries its local changes; only there can bringing them back conflict.
    private static func fastForwarded(_ branch: String, by commits: Int, to upstream: String, place: BranchPullPlace, conflicted: Bool) -> RefString {
        let name = RefName.branch(branch)
        let target = RefName.remoteBranch(upstream)
        guard case .worktree(let path) = place else { return RefString(LocalizedStringResource("branch.pull.fastForwarded", defaultValue: "Fast-forwarded \(name) by \(commits) commits to \(target)", bundle: .module)) }
        let folder = RefName.worktree((path as NSString).lastPathComponent)
        if conflicted {
            return RefString(LocalizedStringResource("branch.pull.fastForwardedInWorktreeConflicts", defaultValue: "Fast-forwarded \(name) by \(commits) commits to \(target) (in worktree \(folder)); local changes came back with conflicts, the stash “autostash” stays", bundle: .module))
        }
        return RefString(LocalizedStringResource("branch.pull.fastForwardedInWorktree", defaultValue: "Fast-forwarded \(name) by \(commits) commits to \(target) (in worktree \(folder))", bundle: .module))
    }

    // MARK: Diverged

    /// Nothing merges or rebases on its own: the branch can be checked out and pulled with the normal pull, or reset to its upstream.
    /// A branch checked out in another worktree is pulled there, so the tab moves to that worktree instead.
    private func offerWayOut(branch: String, upstream: String, ahead: Int, behind: Int, place: BranchPullPlace) async {
        let alert = NSAlert()
        let title = LocalizedStringResource("branch.diverged.title", defaultValue: "Branch and Upstream have diverged", bundle: .module)
        let names = RefString(marked: RefName.branch(branch) + " ↔ " + RefName.remoteBranch(upstream))
        let counts = RefString(LocalizedStringResource("branch.pull.divergedInfo", defaultValue: "Local has \(Self.newCommits(ahead)), the upstream \(Self.newCommits(behind)).", bundle: .module))
        let cancel = String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        if case .worktree(let path) = place {
            let folder = (path as NSString).lastPathComponent
            alert.setConfirmation(title, names: names, info: RefString(LocalizedStringResource("branch.pull.divergedInWorktree", defaultValue: "Pull in its worktree \(RefName.worktree(folder)).", bundle: .module)))
            alert.addButton(withTitle: String(localized: "worktree.action.switchTo", defaultValue: "Switch to Worktree \(folder)", bundle: .module))
            alert.addButton(withTitle: cancel)
            if await prompter.confirm(alert) { onSwitchWorktree?(path) }
            return
        }
        alert.setConfirmation(title, names: names, info: counts)
        alert.addButton(withTitle: String(localized: "branch.pull.checkoutAndPull", defaultValue: "Checkout and Pull…", bundle: .module))
        alert.addButton(withTitle: String(localized: "branch.pull.resetTo", defaultValue: "Reset to \(upstream)", bundle: .module))
        alert.addButton(withTitle: cancel)
        switch await prompter.choose(alert) {
        case .alertFirstButtonReturn: await checkoutAndPull(branch)
        case .alertSecondButtonReturn: await reset(branch, to: upstream)
        default: break
        }
    }

    private func checkoutAndPull(_ branch: String) async {
        switch await viewModel.checkout(.localBranch(branch)) {
        case .done:
            // The toolbar's pull works on what it last read, which was the branch before the checkout.
            await status.refresh().value
            pull(PullVariant(mode: defaultMode))
        case .changesLeftInStash(let conflict):
            prompter.report(GitError(arguments: ["switch", branch], exitCode: 1, stderr: conflict.conflictedPaths.joined(separator: "\n")), title: LocalizedStringResource("failure.branch.switchedNotPulled", defaultValue: "Switched, but the carried-over changes conflict; not pulled", bundle: .module))
        case .failed(let message):
            prompter.report(GitError(arguments: ["switch", branch], exitCode: 1, stderr: message), title: LocalizedStringResource("failure.checkout.notCheckedOut", defaultValue: "\(RefName.branch(branch)) not checked out", bundle: .module))
        }
    }

    /// Runs without asking again: the status line offers Undo, which brings the local commits back. The reset refuses if the branch moved meanwhile.
    private func reset(_ branch: String, to upstream: String) async {
        let repository = viewModel.repository
        guard let head = try? await repository.branchHead(branch) else { return }
        do {
            try await viewModel.withUndoPoint(scope: .branch(branch), operation: "git update-ref refs/heads/\(branch)") { try await repository.resetBranchToUpstream(branch, expecting: head) }
            let done = String(localized: "branch.reset.done", defaultValue: "\(branch) reset to \(upstream)", bundle: .module)
            await viewModel.refresh(note: done + " · git update-ref refs/heads/\(branch)", focus: .followHead)
            prompter.toast(RefString(LocalizedStringResource("branch.reset.done", defaultValue: "\(RefName.branch(branch)) reset to \(RefName.remoteBranch(upstream))", bundle: .module)))
        } catch {
            await viewModel.refresh(note: nil, focus: .followHead)
            prompter.report(error, title: LocalizedStringResource("failure.branch.notReset", defaultValue: "\(RefName.branch(branch)) not reset", bundle: .module))
        }
    }

    /// A count of its own inside the diverged message, which names two of them.
    private static func newCommits(_ count: Int) -> String {
        String(localized: "branch.pull.newCommits", defaultValue: "\(count) new commits", bundle: .module, comment: "One side's count in “Local has 2 new commits, origin/main has 1 new commit.”")
    }
}
