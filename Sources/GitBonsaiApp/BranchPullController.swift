import AppKit
import GitEngine

/// Pulling and pushing a local branch from its context menu, also when it is not checked out: in the sidebar and on its ref pill in the history.
/// The checked-out branch takes the toolbar's normal pull; any other branch is only ever fast-forwarded, and a diverged one is left alone with a way out offered.
@MainActor
final class BranchPullController {
    private let viewModel: GraphViewModel
    private let pullPush: PullPushController
    private let prompter: any Prompting
    /// Moves the tab to another worktree, like a double click on it in the sidebar.
    var onSwitchWorktree: ((String) -> Void)?

    init(context: RepositoryContext, pullPush: PullPushController) {
        viewModel = context.model
        prompter = context.prompter
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

    /// "Push <branch>" to its upstream for a local branch with an upstream on a known remote, nil for anything else. A rejected push offers the same ways out as the toolbar's.
    func pushItem(for ref: Ref) -> NSMenuItem? {
        guard ref.kind == .localBranch, let upstream = ref.upstream, let remote = pullPush.remotes.filter({ upstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return nil }
        let name = ref.name
        let remoteBranch = String(upstream.dropFirst(remote.count + 1))
        return ActionMenuItem(LocalizedStringResource("branch.menu.push", defaultValue: "Push \(RefName.branch(name))", bundle: .module)) { [weak self] in
            self?.pullPush.push(.branch(name, remote: remote, remoteBranch: remoteBranch, setUpstream: false, forceWithLease: false), upstream: upstream)
        }
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
            await pullPush.refresh().value
            pullPush.pull(PullVariant(mode: pullPush.defaultMode))
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
