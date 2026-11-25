import AppKit
import GitEngine

/// The last local operation of the tab that can be undone, with the git command it ran.
struct UndoOffer {
    let point: UndoPoint
    let operation: String
}

/// Which refs a local operation may move besides HEAD, and how HEAD's branch goes back.
struct UndoScope {
    var refs: [String] = []
    var headRestore: UndoPoint.HeadRestore = .keep

    static let head = UndoScope()

    static func branch(_ name: String) -> UndoScope { UndoScope(refs: ["refs/heads/\(name)"]) }

    static func reset(_ mode: ResetMode) -> UndoScope {
        let restore: UndoPoint.HeadRestore = switch mode {
        case .soft: .soft
        case .mixed: .mixed
        case .hard: .keep
        }
        return UndoScope(headRestore: restore)
    }
}

extension CheckoutTarget {
    /// A checkout moves HEAD; one that creates, fast-forwards or resets a branch moves that branch too.
    var undoScope: UndoScope {
        switch self {
        case .localBranch, .commit: .head
        case .remoteBranch(_, let branch), .fastForward(let branch, _), .reset(let branch, _): .branch(branch)
        }
    }
}

extension GraphViewModel {
    /// Runs `body` and, when it moved HEAD or a ref of `scope`, offers to undo it; nil runs it without.
    func withUndoPoint<T>(scope: UndoScope?, operation: String, _ body: () async throws -> T) async throws -> T {
        guard let scope else { return try await body() }
        let repository = repository
        let point = await repository.undoPoint(watching: scope.refs, headRestore: scope.headRestore)
        let result = try await body()
        if let finished = await repository.finishUndoPoint(point) { undoOffer = UndoOffer(point: finished, operation: operation) }
        return result
    }
}

/// "Undo" in the status line after a local operation that lost no commits: a rebase, cherry-pick, revert, merge, reset, checkout or branch deletion, and an interactive rebase of the app.
/// Local operations run without asking, because this puts the refs back; it is offered only while HEAD and the refs are still where the operation left them.
@MainActor
final class UndoHistory {
    private enum Pending {
        case point(UndoOffer)
        case rebase(RebaseUndo)
    }

    let button = NSButton(title: String(localized: "history.undo.button", defaultValue: "Undo", bundle: .module, comment: "Status line button that undoes the last local operation."), target: nil, action: nil)
    private let viewModel: GraphViewModel
    private let runner: ActionRunner
    private var pending: Pending?
    /// Each update starts a new check; only the latest one may change the button.
    private var generation = 0

    init(context: RepositoryContext) {
        viewModel = context.model
        runner = context.runner
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = Theme.caption
        button.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(pressed)
        button.isHidden = true
    }

    /// Picks up a rebase git has finished since and checks whether the last operation can still be undone; called on every read of the repository.
    func update() {
        generation += 1
        let current = generation
        let repository = viewModel.repository
        let offer = viewModel.undoOffer
        Task {
            let rebase = await repository.finishedInteractiveRebase()
            var found: Pending?
            // An interactive rebase that finished after the offer was made is the newer operation.
            if rebase == nil, let offer, await repository.canUndo(offer.point) {
                found = .point(offer)
            } else if let last = await repository.lastRebaseUndo() {
                found = .rebase(last)
            }
            guard current == generation else { return }
            if case .point = found {} else if viewModel.undoOffer?.point == offer?.point { viewModel.undoOffer = nil }
            pending = found
            show()
        }
    }

    private func show() {
        button.isHidden = pending == nil
        switch pending {
        case .point(let offer):
            button.toolTip = String(localized: "history.undo.toolTip", defaultValue: "Undoes \(offer.operation) (\(offer.point.commandLine))", bundle: .module, comment: "Tooltip of the status line's Undo; the arguments are git commands.")
        case .rebase(let undo):
            let sha = String(undo.before.prefix(RefString.shortSHA))
            button.toolTip = String(localized: "rebase.undo.toolTip", defaultValue: "Resets \(undo.shortBranch ?? "HEAD") to where it was before the rebase (ORIG_HEAD \(sha))", bundle: .module)
        case nil:
            button.toolTip = nil
        }
    }

    @objc private func pressed() {
        guard let pending else { return }
        self.pending = nil
        viewModel.undoOffer = nil
        show()
        let failure = LocalizedStringResource("failure.undo.failed", defaultValue: "Not undone", bundle: .module)
        switch pending {
        case .point(let offer):
            runner.run(failure: failure, note: offer.point.commandLine, focus: .followHead) { try await $0.undo(offer.point) }
        case .rebase(let undo):
            runner.run(failure: failure, note: "git reset --keep ORIG_HEAD", focus: .followHead) { try await $0.undoRebase(undo) }
        }
    }
}
