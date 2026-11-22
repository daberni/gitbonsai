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
    var onToast: ((String) -> Void)?

    init(viewModel: GraphViewModel, pullPush: PullPushController) {
        self.viewModel = viewModel
        self.pullPush = pullPush
    }

    /// "„<branch>“ pullen" for a local branch with an upstream, nil for anything else.
    func item(for ref: Ref) -> NSMenuItem? {
        guard ref.kind == .localBranch, let upstream = ref.upstream else { return nil }
        let name = ref.name
        let item = ActionMenuItem("„\(name)“ pullen") { [weak self] in self?.pull(name) }
        item.toolTip = "Holt \(upstream) und spult „\(name)“ vor, wenn das ohne Merge geht."
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
                prompter.report(error, title: "„\(branch)“ nicht gepullt")
                return
            }
            let upstream = await repository.upstream(of: branch)?.name ?? "Upstream"
            switch result.outcome {
            case .fastForwarded(let commits):
                let what = commits == 1 ? "1 Commit" : "\(commits) Commits"
                let summary = "„\(branch)“ um \(what) auf \(upstream) vorgespult" + Self.whereText(result.place)
                let conflicted = result.localChangesConflicted ? ", " + PullPushController.conflictedChanges : ""
                await viewModel.refresh(note: summary + conflicted + " · " + result.commandLine)
                onToast?(summary + conflicted)
            case .upToDate(let ahead):
                let summary = "„\(branch)“ ist auf dem Stand von \(upstream)" + (ahead > 0 ? ", \(ahead) lokale Commits noch nicht gepusht" : "")
                await viewModel.refresh(note: summary + " · " + result.commandLine)
                onToast?(summary)
            case .diverged(let ahead, let behind):
                await viewModel.refresh(note: "„\(branch)“ weicht von \(upstream) ab · " + result.commandLine)
                await offerWayOut(branch: branch, upstream: upstream, ahead: ahead, behind: behind, place: result.place)
            }
        }
    }

    private static func whereText(_ place: BranchPullPlace) -> String {
        guard case .worktree(let path) = place else { return "" }
        return " (im Worktree „\((path as NSString).lastPathComponent)“)"
    }

    // MARK: Diverged

    /// Nothing merges or rebases on its own: the branch can be checked out and pulled with the normal pull, or reset to its upstream.
    /// A branch checked out in another worktree is pulled there, so the tab moves to that worktree instead.
    private func offerWayOut(branch: String, upstream: String, ahead: Int, behind: Int, place: BranchPullPlace) async {
        let alert = NSAlert()
        alert.messageText = "„\(branch)“ und \(upstream) sind auseinandergelaufen"
        let counts = "Lokal \(Self.commits(ahead)), auf \(upstream) \(Self.commits(behind)). Ein Fast-Forward ist nicht möglich; geändert wurde nichts."
        if case .worktree(let path) = place {
            let folder = (path as NSString).lastPathComponent
            alert.informativeText = counts + " „\(branch)“ ist im Worktree „\(folder)“ ausgecheckt; dort lässt es sich mit Merge oder Rebase pullen."
            alert.addButton(withTitle: "Zu Worktree „\(folder)“ wechseln")
            alert.addButton(withTitle: "Abbrechen")
            if await prompter.confirm(alert) { onSwitchWorktree?(path) }
            return
        }
        alert.informativeText = counts + " Auschecken und pullen bietet Merge und Rebase; Zurücksetzen verwirft die lokalen Commits."
        alert.addButton(withTitle: "Auschecken und pullen …")
        alert.addButton(withTitle: "Auf \(upstream) zurücksetzen …")
        alert.addButton(withTitle: "Abbrechen")
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
            prompter.report(GitError(arguments: ["switch", branch], exitCode: 1, stderr: conflict.conflictedPaths.joined(separator: "\n")), title: "Gewechselt, aber die mitgenommenen Änderungen kollidieren; nicht gepullt")
        case .failed(let message):
            prompter.report(GitError(arguments: ["switch", branch], exitCode: 1, stderr: message), title: "„\(branch)“ nicht ausgecheckt")
        }
    }

    /// Asks again with the number of commits that would be lost; the reset refuses if the branch moved meanwhile.
    private func reset(_ branch: String, to upstream: String, losing ahead: Int) async {
        let repository = viewModel.repository
        guard let head = try? await repository.branchHead(branch) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "„\(branch)“ auf \(upstream) zurücksetzen?"
        let loss = ahead == 1 ? "Ein lokaler Commit geht verloren; das Reflog behält ihn" : "\(ahead) lokale Commits gehen verloren; das Reflog behält sie"
        alert.informativeText = "\(loss) noch eine Weile."
        alert.addButton(withTitle: "Zurücksetzen")
        alert.addButton(withTitle: "Abbrechen")
        alert.buttons.first?.hasDestructiveAction = true
        guard await prompter.confirm(alert) else { return }
        do {
            try await repository.resetBranchToUpstream(branch, expecting: head)
            await viewModel.refresh(note: "„\(branch)“ auf \(upstream) zurückgesetzt · git update-ref refs/heads/\(branch)")
            onToast?("„\(branch)“ auf \(upstream) zurückgesetzt")
        } catch {
            await viewModel.refresh(note: nil)
            prompter.report(error, title: "„\(branch)“ nicht zurückgesetzt")
        }
    }

    private static func commits(_ count: Int) -> String {
        count == 1 ? "1 neuer Commit" : "\(count) neue Commits"
    }
}
