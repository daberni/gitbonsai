import AppKit
import GitEngine

/// Pulling a local branch from its context menu, also when it is not checked out: in the sidebar and on its ref pill in the history.
/// The checked-out branch takes the toolbar's normal pull; any other branch is only ever fast-forwarded, and a diverged one is left alone with a way out offered.
@MainActor
final class BranchPullController {
    private let viewModel: GraphViewModel
    private let pullPush: PullPushController
    private var prompter: ActionPrompter { pullPush.prompter }
    /// Moves the tab to another worktree, like a double click on it in the sidebar.
    var onSwitchWorktree: ((String) -> Void)?
    /// Says briefly what a pull did, in a toast.
    var onToast: ((RefString) -> Void)?

    init(viewModel: GraphViewModel, pullPush: PullPushController) {
        self.viewModel = viewModel
        self.pullPush = pullPush
    }

    /// "Pull <branch>" for a local branch with an upstream, nil for anything else.
    func item(for ref: Ref) -> NSMenuItem? {
        guard ref.kind == .localBranch, let upstream = ref.upstream else { return nil }
        let name = ref.name
        let item = ActionMenuItem(LocalizedStringResource("branch.menu.pull", defaultValue: "Pull \(RefName.branch(name))", bundle: .module)) { [weak self] in self?.pull(name) }
        item.toolTip = String(localized: "branch.pull.toolTip", defaultValue: "Fetches \(upstream) and fast-forwards \(name) when that works without a merge.", bundle: .module)
        return item
    }

    func pull(_ branch: String) {
        let repository = viewModel.repository
        Task {
            let result: BranchPullResult
            do {
                result = try await repository.fastForwardBranch(branch)
            } catch BranchPullError.isCurrentBranch {
                pullPush.pull(PullVariant(mode: pullPush.defaultMode))
                return
            } catch {
                await viewModel.refresh(note: nil)
                prompter.report(error, title: LocalizedStringResource("failure.branch.notPulled", defaultValue: "\(RefName.branch(branch)) not pulled", bundle: .module))
                return
            }
            // The pull needed the upstream, so only a race can lose it here; git's own name for it stands in then.
            let upstream = await repository.upstream(of: branch)?.name ?? "\(branch)@{upstream}"
            switch result.outcome {
            case .fastForwarded(let commits):
                let summary = Self.fastForwarded(branch, by: commits, to: upstream, place: result.place, conflicted: result.localChangesConflicted)
                await viewModel.refresh(note: summary.plain + " · " + result.commandLine)
                onToast?(summary)
            case .upToDate(let ahead):
                let summary: RefString = if ahead > 0 {
                    RefString(LocalizedStringResource("branch.pull.upToDateUnpushed", defaultValue: "\(RefName.branch(branch)) is up to date with \(RefName.remoteBranch(upstream)), \(ahead) local commits not pushed yet", bundle: .module))
                } else {
                    RefString(LocalizedStringResource("branch.pull.upToDate", defaultValue: "\(RefName.branch(branch)) is up to date with \(RefName.remoteBranch(upstream))", bundle: .module))
                }
                await viewModel.refresh(note: summary.plain + " · " + result.commandLine)
                onToast?(summary)
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
        let title = RefString(LocalizedStringResource("branch.diverged.title", defaultValue: "\(RefName.branch(branch)) and \(RefName.remoteBranch(upstream)) have diverged", bundle: .module))
        let local = Self.newCommits(ahead)
        let remote = Self.newCommits(behind)
        let cancel = String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        if case .worktree(let path) = place {
            let folder = (path as NSString).lastPathComponent
            alert.setText(title, info: RefString(LocalizedStringResource("branch.pull.divergedInWorktree", defaultValue: "Local has \(local), \(RefName.remoteBranch(upstream)) has \(remote). A fast-forward is not possible; nothing was changed. \(RefName.branch(branch)) is checked out in the worktree \(RefName.worktree(folder)); it can be pulled there with merge or rebase.", bundle: .module)))
            alert.addButton(withTitle: String(localized: "worktree.action.switchTo", defaultValue: "Switch to Worktree \(folder)", bundle: .module))
            alert.addButton(withTitle: cancel)
            if await prompter.confirm(alert) { onSwitchWorktree?(path) }
            return
        }
        alert.setText(title, info: RefString(LocalizedStringResource("branch.pull.divergedInfo", defaultValue: "Local has \(local), \(RefName.remoteBranch(upstream)) has \(remote). A fast-forward is not possible; nothing was changed. Checkout and Pull offers merge and rebase; resetting drops the local commits.", bundle: .module)))
        alert.addButton(withTitle: String(localized: "branch.pull.checkoutAndPull", defaultValue: "Checkout and Pull…", bundle: .module))
        alert.addButton(withTitle: String(localized: "branch.pull.resetTo", defaultValue: "Reset to \(upstream)…", bundle: .module))
        alert.addButton(withTitle: cancel)
        switch await prompter.choose(alert) {
        case .alertFirstButtonReturn: await checkoutAndPull(branch)
        case .alertSecondButtonReturn: await reset(branch, to: upstream, losing: ahead)
        default: break
        }
    }

    private func checkoutAndPull(_ branch: String) async {
        switch await viewModel.checkout(.localBranch(branch)) {
        case .done:
            // The toolbar's pull works on what it last read, which was the branch before the checkout.
            await pullPush.refresh().value
            pullPush.pull(PullVariant(mode: pullPush.defaultMode))
        case .changesLeftInStash(let conflict):
            prompter.report(GitError(arguments: ["switch", branch], exitCode: 1, stderr: conflict.conflictedPaths.joined(separator: "\n")), title: LocalizedStringResource("failure.branch.switchedNotPulled", defaultValue: "Switched, but the carried-over changes conflict; not pulled", bundle: .module))
        case .failed(let message):
            prompter.report(GitError(arguments: ["switch", branch], exitCode: 1, stderr: message), title: LocalizedStringResource("failure.checkout.notCheckedOut", defaultValue: "\(RefName.branch(branch)) not checked out", bundle: .module))
        }
    }

    /// Asks again with the number of commits that would be lost; the reset refuses if the branch moved meanwhile.
    private func reset(_ branch: String, to upstream: String, losing ahead: Int) async {
        let repository = viewModel.repository
        guard let head = try? await repository.branchHead(branch) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.setText(LocalizedStringResource("branch.reset.title", defaultValue: "Reset \(RefName.branch(branch)) to \(RefName.remoteBranch(upstream))?", bundle: .module), info: LocalizedStringResource("branch.reset.info", defaultValue: "\(ahead) local commits will be lost; the reflog keeps them for a while.", bundle: .module))
        alert.addButton(withTitle: String(localized: "common.reset", defaultValue: "Reset", bundle: .module, comment: "Button that resets a branch."))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        alert.buttons.first?.hasDestructiveAction = true
        guard await prompter.confirm(alert) else { return }
        do {
            try await repository.resetBranchToUpstream(branch, expecting: head)
            let done = String(localized: "branch.reset.done", defaultValue: "\(branch) reset to \(upstream)", bundle: .module)
            await viewModel.refresh(note: done + " · git update-ref refs/heads/\(branch)")
            onToast?(RefString(LocalizedStringResource("branch.reset.done", defaultValue: "\(RefName.branch(branch)) reset to \(RefName.remoteBranch(upstream))", bundle: .module)))
        } catch {
            await viewModel.refresh(note: nil)
            prompter.report(error, title: LocalizedStringResource("failure.branch.notReset", defaultValue: "\(RefName.branch(branch)) not reset", bundle: .module))
        }
    }

    /// A count of its own inside the diverged message, which names two of them.
    private static func newCommits(_ count: Int) -> String {
        String(localized: "branch.pull.newCommits", defaultValue: "\(count) new commits", bundle: .module, comment: "One side's count in “Local has 2 new commits, origin/main has 1 new commit.”")
    }
}
