import AppKit
import GitEngine
import Synchronization

/// The rebase group of the commit menu. On a commit outside the current branch: a one-click rebase from the detected base, and the interactive sheet onto the commit.
/// On a commit of the branch: the interactive sheet in place. Both forms share one detection and run through the interactive rebase engine, so the status line can undo them.
/// Rewriting published commits only gets the hint in the status line, as everywhere else.
@MainActor
final class RebaseOntoController {
    /// Runs a rebase git cannot take as a todo list (a merge in the range, a fast-forward), with the status line's note.
    typealias Runner = (_ note: String, _ operation: @escaping @Sendable (Repository) async throws -> OperationReport?) -> Void

    private let viewModel: GraphViewModel
    private let interactive: InteractiveRebaseController
    private let runPlainRebase: Runner

    init(viewModel: GraphViewModel, interactive: InteractiveRebaseController, runPlainRebase: @escaping Runner) {
        self.viewModel = viewModel
        self.interactive = interactive
        self.runPlainRebase = runPlainRebase
    }

    // MARK: Menu

    func items(branch: String, commit: Commit) -> [NSMenuItem] {
        let place = placeName(of: commit)
        let interactiveTitle: RefString = "Rebase \(branch: branch) interaktiv auf \(place) …"
        guard !viewModel.isReachableFromHead(commit.id) else {
            if let reason = interactive.inPlaceReason(for: commit) { return [Self.disabled(interactiveTitle, reason)] }
            return [ActionMenuItem(interactiveTitle) { [weak self] in self?.interactive.openSheet(branch: branch, onto: commit, targetName: place, detection: .plain(moving: 0)) }]
        }
        let repository = viewModel.repository
        let targetRef = branchRef(at: commit)
        let found = DetectionResult()
        let detection = Task.detached {
            let result = await repository.detectRebaseBase(of: branch, onto: commit.id, targetRef: targetRef)
            found.store(result)
            return result
        }
        let oneClick = ActionMenuItem("Rebase \(branch: branch) auf \(place) (Basis wird gesucht …)") { [weak self] in
            Task { await self?.rebase(branch, onto: commit, place: place, detection: detection.value) }
        }
        let sheet = ActionMenuItem(interactiveTitle) { [weak self] in
            Task {
                let result = await detection.value
                self?.interactive.openSheet(branch: branch, onto: commit, targetName: place, detection: result)
            }
        }
        // An open menu runs its own tracking loop, which serves no main-actor tasks; a timer in the common modes still fires and updates the entry in place.
        let started = Date()
        // The timer fires on the main run loop; the entry only crosses into its closure.
        nonisolated(unsafe) weak let entry = oneClick
        let poll = Timer(timeInterval: 0.05, repeats: true) { timer in
            let finished = MainActor.assumeIsolated {
                guard let entry, Date().timeIntervalSince(started) < Self.searchTimeout else { return true }
                guard let result = found.value else { return false }
                entry.setTitle(Self.title(branch: branch, place: place, detection: result))
                return true
            }
            if finished { timer.invalidate() }
        }
        RunLoop.main.add(poll, forMode: .common)
        return [oneClick, sheet]
    }

    /// After this many seconds an open menu stops waiting for the detected base; choosing the entry still waits for it.
    private static let searchTimeout: TimeInterval = 30

    private static func disabled(_ title: RefString, _ reason: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.setTitle(title)
        item.isEnabled = false
        item.toolTip = reason
        return item
    }

    /// "Rebase feature/b auf main (3 Commits, ohne feature/a)", or with the commit count alone when the merge base is all there is.
    static func title(branch: String, place: RefString, detection: RebaseBaseDetection) -> RefString {
        switch detection {
        // Without own commits the rebase only fast-forwards; a count of none would read odd.
        case .plain(let moving) where moving == 0: return "Rebase \(branch: branch) auf \(place)"
        case .plain(let moving): return "Rebase \(branch: branch) auf \(place) (\(commits(moving)))"
        case .tie: return "Rebase \(branch: branch) auf \(place) (Basis mehrdeutig) …"
        case .detected(let base):
            // A former tip of the target branch itself means the target was rewritten, like a fork point.
            let reason = if case .branch(let name) = base.reason, place.containsNames, name == place.plain { without(.forkPoint(name)) } else { without(base.reason) }
            return "Rebase \(branch: branch) auf \(place) (\(commits(base.moving)), \(reason))"
        }
    }

    private static func commits(_ count: Int) -> String { count == 1 ? "1 Commit" : "\(count) Commits" }

    static func without(_ reason: RebaseBase.Reason) -> RefString {
        switch reason {
        case .branch(let name): "ohne \(branch: name)"
        case .squashed(let commit): "ohne die in \(commit: commit) gesquashten"
        case .forkPoint(let ref): "ohne die alten von \(branch: ref)"
        }
    }

    /// main for a row with a branch or tag, else "diesen Commit". Local branches come first, then remote branches, then tags.
    func placeName(of commit: Commit) -> RefString {
        let refs = viewModel.refsByCommit[commit.id] ?? []
        if let local = branch(at: commit, local: true) { return "\(branch: local)" }
        if let remote = branch(at: commit, local: false) { return "\(remoteBranch: remote)" }
        if let tag = refs.first(where: { $0.kind == .tag })?.name { return "\(tag: tag)" }
        return "diesen Commit"
    }

    /// A branch at the commit, whose reflog can tell an earlier position for `--fork-point`.
    private func branchRef(at commit: Commit) -> String? {
        branch(at: commit, local: true) ?? branch(at: commit, local: false)
    }

    private func branch(at commit: Commit, local: Bool) -> String? {
        let refs = viewModel.refsByCommit[commit.id] ?? []
        if local { return refs.first { $0.kind == .localBranch }?.name }
        return refs.first { if case .remoteBranch = $0.kind { !$0.name.hasSuffix("/HEAD") } else { false } }?.name
    }

    // MARK: Running

    /// The one-click form: every commit of the detected range picked onto the target. A tie opens the sheet to choose; a merge in the range or a fast-forward goes to plain `git rebase`.
    private func rebase(_ branch: String, onto target: Commit, place: RefString, detection: RebaseBaseDetection) async {
        if case .tie = detection { return interactive.openSheet(branch: branch, onto: target, targetName: place, detection: detection) }
        let repository = viewModel.repository
        let upstream = viewModel.status?.branch.upstream
        do {
            let range = try await repository.rebaseRange(onto: target.id, detection: detection)
            let plan = RebasePlan(range: range, branches: await repository.stackedBranches(in: range.commits))
            let hint = CommitActionsController.publishedHint(await repository.publishedCommitCount(rewrittenBy: range.base), upstream: upstream)
            interactive.start(plan, note: CommitActionsController.note(InteractiveRebaseController.command(plan), hint))
        } catch {
            let base: String? = if case .detected(let found) = detection { found.commit } else { nil }
            let hint = CommitActionsController.publishedHint(await repository.publishedCommitCount(rewrittenBy: base ?? target.id), upstream: upstream)
            if let base {
                runPlainRebase(CommitActionsController.note("git rebase --onto \(target.id.prefix(7)) \(base.prefix(7))", hint)) { try await $0.rebase(onto: target.id, from: base, branch: branch) }
            } else {
                runPlainRebase(CommitActionsController.note("git rebase", hint)) { try await $0.rebaseCurrentBranch(onto: target.id) }
            }
        }
    }
}

/// The detection's result, handed from the background search to the menu's timer.
private final class DetectionResult: Sendable {
    private let result = Mutex<RebaseBaseDetection?>(nil)

    var value: RebaseBaseDetection? { result.withLock { $0 } }

    func store(_ detection: RebaseBaseDetection) { result.withLock { $0 = detection } }
}
