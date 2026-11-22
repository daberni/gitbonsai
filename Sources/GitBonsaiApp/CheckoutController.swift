import AppKit
import GitEngine

/// Checking out from the history: what a row offers, and running the checkout with the questions it may raise.
@MainActor
final class CheckoutController: NSObject {
    struct Choice {
        let title: String
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

    private let viewModel: GraphViewModel

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
                return Choice(title: "Zu Worktree „\((worktree.path as NSString).lastPathComponent)“ wechseln (\(checkout.branch))", target: .localBranch(checkout.branch), worktreePath: worktree.path)
            }
            var choice = Choice(title: title(of: checkout), target: checkout.target, worktreePath: nil)
            if case .diverged(let upstream, let lost) = checkout.kind {
                choice.reset = ResetOffer(branch: checkout.branch, upstream: upstream, lostCommits: lost, isCurrent: checkout.branch == viewModel.currentBranch)
            }
            return choice
        }
        if commit.id != viewModel.headSHA || viewModel.currentBranch != nil {
            choices.append(Choice(title: "Commit \(commit.id.prefix(7)) auschecken (Detached HEAD)", target: .commit(commit.id), worktreePath: nil))
        }
        return choices
    }

    private func title(of checkout: BranchCheckout) -> String {
        switch checkout.kind {
        case .local: "„\(checkout.branch)“ auschecken"
        case .fastForward(let upstream) where checkout.branch == viewModel.currentBranch: "„\(checkout.branch)“ auf „\(upstream)“ vorspulen"
        case .fastForward(let upstream): "„\(checkout.branch)“ auschecken und auf „\(upstream)“ vorspulen"
        case .diverged(let upstream, _) where checkout.branch == viewModel.currentBranch: "„\(checkout.branch)“ auf „\(upstream)“ zurücksetzen …"
        case .diverged(let upstream, _): "„\(checkout.branch)“ auschecken (weicht von „\(upstream)“ ab) …"
        case .createTracking(let remote): "„\(remote)/\(checkout.branch)“ als lokalen Branch auschecken"
        }
    }

    /// A double click checks out the branch at the row. A row without a branch does nothing: a detached HEAD should be asked for, not happen by accident.
    func activate(row index: Int) {
        guard let choice = choices(forRow: index).first, choice.target != .commit(viewModel.commits[index].id) else { return }
        perform(choice)
    }

    func menuItems(forRow index: Int) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (offset, choice) in choices(forRow: index).enumerated() {
            if case .commit = choice.target, offset > 0 { items.append(.separator()) }
            let item = NSMenuItem(title: choice.title, action: #selector(performFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuChoice(choice)
            items.append(item)
        }
        return items
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
        alert.messageText = "„\(offer.branch)“ und „\(offer.upstream)“ sind auseinandergelaufen"
        let loss = offer.lostCommits == 1 ? "geht ein lokaler Commit verloren; das Reflog behält ihn" : "gehen \(offer.lostCommits) lokale Commits verloren; das Reflog behält sie"
        alert.informativeText = "„\(offer.branch)“ lässt sich nicht vorspulen. Beim Zurücksetzen auf „\(offer.upstream)“ \(loss) noch eine Weile."
        alert.addButton(withTitle: "Auf „\(offer.upstream)“ zurücksetzen")
        if !offer.isCurrent { alert.addButton(withTitle: "Nur auschecken") }
        alert.addButton(withTitle: "Abbrechen")
        alert.buttons.first?.hasDestructiveAction = true
        if ScreenshotHarness.isActive { return ScreenshotHarness.answerReset(alert) }
        guard let window = window?() else { return .cancel }
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
                alert.messageText = "Gewechselt, aber die mitgenommenen Änderungen kollidieren"
                alert.informativeText = "Die Konflikte stehen im Arbeitsverzeichnis. Die Änderungen bleiben im Stash „\(conflict.stashMessage)“; nach dem Lösen kann er gelöscht werden."
                if !conflict.conflictedPaths.isEmpty { alert.informativeText += "\n\n" + conflict.conflictedPaths.joined(separator: "\n") }
                present(alert) { _ in }
            case .failed(let message):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Wechsel fehlgeschlagen"
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
        alert.beginSheetModal(for: window) { response in completion(response) }
    }

    /// Menu items carry objects; this boxes a choice for one.
    private final class MenuChoice: NSObject {
        let choice: Choice
        init(_ choice: Choice) { self.choice = choice }
    }
}
