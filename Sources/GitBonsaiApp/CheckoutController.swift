import AppKit
import GitEngine

/// Checking out from the history: what a row offers, and running the checkout with the questions it may raise.
@MainActor
final class CheckoutController: NSObject {
    struct Choice {
        let title: RefString
        let target: CheckoutTarget
        /// Set when the branch is checked out in another worktree; going there is the checkout.
        let worktreePath: String?
        /// Set for a local branch that diverged from the remote branch it follows: the checkout first asks whether to reset it there.
        var reset: ResetOffer? = nil
    }

    struct ResetOffer {
        let branch: String
        let upstream: String
        let lostCommits: Int
        let isCurrent: Bool
    }

    /// A worktree was chosen instead of a checkout.
    var onSwitchWorktree: ((String) -> Void)?
    /// The window that questions and errors are shown on.
    var window: (() -> NSWindow?)?

    let viewModel: GraphViewModel

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
    }

    /// What a double click or the context menu offers on a history row: its branches first, the bare commit last.
    func choices(forRow index: Int) -> [Choice] {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return [] }
        let commit = viewModel.commits[index]
        let elsewhere = viewModel.branchesInOtherWorktrees
        var choices = BranchCheckout.choices(at: commit.id, refs: viewModel.refs).map { checkout in
            // A branch checked out in another worktree can only be reached by going there.
            let worktree = elsewhere["refs/heads/\(checkout.branch)"]
            if let worktree {
                let folder = (worktree.path as NSString).lastPathComponent
                return Choice(title: RefString(LocalizedStringResource("checkout.choice.switchWorktree", defaultValue: "Switch to Worktree \(RefName.worktree(folder)) (\(RefName.branch(checkout.branch)))", bundle: .module)), target: .localBranch(checkout.branch), worktreePath: worktree.path)
            }
            var choice = Choice(title: title(of: checkout), target: checkout.target, worktreePath: nil)
            if case .diverged(let upstream, let lost) = checkout.kind {
                choice.reset = ResetOffer(branch: checkout.branch, upstream: upstream, lostCommits: lost, isCurrent: checkout.branch == viewModel.currentBranch)
            }
            return choice
        }
        if commit.id != viewModel.headSHA || viewModel.currentBranch != nil {
            choices.append(Choice(title: RefString(LocalizedStringResource("checkout.choice.commit", defaultValue: "Checkout Commit \(RefName.commit(commit.id)) (Detached HEAD)", bundle: .module)), target: .commit(commit.id), worktreePath: nil))
        }
        return choices
    }

    private func title(of checkout: BranchCheckout) -> RefString {
        let branch = RefName.branch(checkout.branch)
        let title: LocalizedStringResource = switch checkout.kind {
        case .local: LocalizedStringResource("checkout.action.branch", defaultValue: "Checkout \(branch)", bundle: .module)
        case .fastForward(let upstream) where checkout.branch == viewModel.currentBranch: LocalizedStringResource("checkout.choice.fastForward", defaultValue: "Fast-Forward \(branch) to \(RefName.remoteBranch(upstream))", bundle: .module)
        case .fastForward(let upstream): LocalizedStringResource("checkout.choice.checkoutAndFastForward", defaultValue: "Checkout \(branch) and Fast-Forward to \(RefName.remoteBranch(upstream))", bundle: .module)
        case .diverged(let upstream, _) where checkout.branch == viewModel.currentBranch: LocalizedStringResource("checkout.choice.reset", defaultValue: "Reset \(branch) to \(RefName.remoteBranch(upstream))…", bundle: .module)
        case .diverged(let upstream, _): LocalizedStringResource("checkout.choice.diverged", defaultValue: "Checkout \(branch) (diverged from \(RefName.remoteBranch(upstream)))…", bundle: .module)
        case .createTracking(let remote): LocalizedStringResource("checkout.action.asLocalBranch", defaultValue: "Checkout \(RefName.remoteBranch("\(remote)/\(checkout.branch)")) as local Branch", bundle: .module)
        }
        return RefString(title)
    }

    /// A double click checks out the branch at the row. A row without a branch does nothing: a detached HEAD should be asked for, not happen by accident.
    func activate(row index: Int) {
        guard let choice = choices(forRow: index).first, choice.target != .commit(viewModel.commits[index].id) else { return }
        perform(choice)
    }

    func menuItems(forRow index: Int) -> [NSMenuItem] {
        choices(forRow: index).map { choice in
            let item = NSMenuItem(title: "", action: #selector(performFromMenu(_:)), keyEquivalent: "")
            item.setTitle(choice.title)
            item.target = self
            item.representedObject = MenuChoice(choice)
            return item
        }
    }

    /// Branches from the sidebar come in here too.
    func perform(_ target: CheckoutTarget, worktreePath: String?) {
        if let worktreePath { onSwitchWorktree?(worktreePath) } else { checkout(target) }
    }

    private func perform(_ choice: Choice) {
        guard let offer = choice.reset else { return perform(choice.target, worktreePath: choice.worktreePath) }
        Task { [weak self] in
            guard let self else { return }
            switch await askReset(offer) {
            case .alertFirstButtonReturn: checkout(.reset(branch: offer.branch, to: offer.upstream))
            case .alertSecondButtonReturn where !offer.isCurrent: checkout(choice.target)
            default: break
            }
        }
    }

    /// Resetting drops the local commits, so it is asked for with their number; the current branch has nothing else to offer.
    private func askReset(_ offer: ResetOffer) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        let branch = RefName.branch(offer.branch)
        let upstream = RefName.remoteBranch(offer.upstream)
        alert.setText(LocalizedStringResource("branch.diverged.title", defaultValue: "\(branch) and \(upstream) have diverged", bundle: .module), info: LocalizedStringResource("checkout.diverged.info", defaultValue: "\(branch) cannot be fast-forwarded. Resetting it to \(upstream) drops \(offer.lostCommits) local commits; the reflog keeps them for a while.", bundle: .module))
        // Buttons take plain text only, so the name stands bare there.
        alert.addButton(withTitle: String(localized: "checkout.diverged.resetTo", defaultValue: "Reset to \(offer.upstream)", bundle: .module))
        if !offer.isCurrent { alert.addButton(withTitle: String(localized: "checkout.diverged.justCheckout", defaultValue: "Just Checkout", bundle: .module)) }
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        alert.buttons.first?.hasDestructiveAction = true
        if ScreenshotHarness.isActive { return ScreenshotHarness.answerReset(alert) }
        guard let window = window?() else { return .cancel }
        alert.applyRefText()
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    @objc private func performFromMenu(_ sender: NSMenuItem) {
        guard let choice = (sender.representedObject as? MenuChoice)?.choice else { return }
        perform(choice)
    }

    func checkout(_ target: CheckoutTarget) {
        Task { [weak self] in
            guard let self else { return }
            switch await viewModel.checkout(target) {
            case .done:
                break
            case .changesLeftInStash(let conflict):
                let alert = NSAlert()
                alert.alertStyle = .warning
                let stash = conflict.stashMessage
                let info: LocalizedStringResource = if conflict.conflictedPaths.isEmpty {
                    LocalizedStringResource("checkout.conflict.info", defaultValue: "The conflicts are in the working directory. The changes stay in the stash “\(stash)”; once they are resolved, it can be deleted.", bundle: .module)
                } else {
                    LocalizedStringResource("checkout.conflict.infoWithDetails", defaultValue: "The conflicts are in the working directory. The changes stay in the stash “\(stash)”; once they are resolved, it can be deleted.\n\n\(RefName.paths(conflict.conflictedPaths, separator: "\n"))", bundle: .module)
                }
                alert.setText(LocalizedStringResource("checkout.conflict.title", defaultValue: "Switched, but the carried-over changes conflict", bundle: .module), info: info)
                present(alert) { _ in }
            case .failed(let message):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "failure.checkout.switchFailed", defaultValue: "Switch failed", bundle: .module)
                alert.informativeText = message
                present(alert) { _ in }
            }
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard ScreenshotHarness.outputPath == nil, let window = window?() else {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        alert.applyRefText()
        alert.beginSheetModal(for: window) { response in completion(response) }
    }

    /// Menu items carry objects; this boxes a choice for one.
    private final class MenuChoice: NSObject {
        let choice: Choice
        init(_ choice: Choice) { self.choice = choice }
    }
}

extension CheckoutTarget {
    /// The message of the stash that carries uncommitted changes across this checkout, in the interface's language like everything the app writes into a repository.
    var stashMessage: String {
        String(localized: "stash.message.switching", defaultValue: "GitBonsai: changes when switching to \(label)", bundle: .module, comment: "Message of the stash that carries local changes across a checkout; the argument is the branch or commit switched to.")
    }
}
