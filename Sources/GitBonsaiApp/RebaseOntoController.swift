import AppKit
import GitEngine
import Synchronization

/// The rebase entries of the commit menu: a plain rebase onto the row, one with a detected old base, and `--onto` with a base chosen in a sheet.
/// Rewriting published commits only gets the hint in the status line, as everywhere else; the rebase's undo covers mistakes.
@MainActor
final class RebaseOntoController {
    /// Runs a rebase with the status line's note, refreshing the tab and ending like a rebase finished through the banner.
    typealias Runner = (_ note: String, _ operation: @escaping @Sendable (Repository) async throws -> OperationReport?) -> Void

    private let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    private let runRebase: Runner

    init(viewModel: GraphViewModel, prompter: ActionPrompter, runRebase: @escaping Runner) {
        self.viewModel = viewModel
        self.prompter = prompter
        self.runRebase = runRebase
    }

    // MARK: Menu

    /// Entries on a row outside the current branch. The detected base is searched while the menu is open; its entry names what moves once known and disappears when a plain rebase is all there is.
    func targetItems(branch: String, target: Commit) -> [NSMenuItem] {
        let place = placeName(of: target)
        let repository = viewModel.repository
        let targetRef = branchRef(at: target)
        let found = DetectionResult()
        let detection = Task.detached {
            let result = await repository.detectRebaseBase(of: branch, onto: target.id, targetRef: targetRef)
            found.store(result)
            return result
        }
        let plain = ActionMenuItem("Rebase „\(branch)“ auf \(place)") { [weak self] in self?.rebase(onto: target) }
        let detected = ActionMenuItem("Rebase „\(branch)“ auf \(place) (Basis wird gesucht …)") { [weak self] in
            Task { await self?.rebase(branch, onto: target, detected: detection.value) }
        }
        let choose = ActionMenuItem("Basis selbst wählen …") { [weak self] in
            Task { await self?.chooseBase(of: branch, onto: target, detection: detection.value) }
        }
        // An open menu runs its own tracking loop, which serves no main-actor tasks; a timer in the common modes still fires and updates the entry in place.
        let started = Date()
        // The timer fires on the main run loop; the entry only crosses into its closure.
        nonisolated(unsafe) weak var entry = detected
        let poll = Timer(timeInterval: 0.05, repeats: true) { timer in
            let finished = MainActor.assumeIsolated {
                guard let entry, Date().timeIntervalSince(started) < Self.searchTimeout else { return true }
                guard let result = found.value else { return false }
                if let title = Self.title(branch: branch, place: place, detection: result) { entry.title = title } else { entry.isHidden = true }
                return true
            }
            if finished { timer.invalidate() }
        }
        RunLoop.main.add(poll, forMode: .common)
        return [plain, detected, choose]
    }

    /// After this many seconds an open menu stops waiting for the detected base; choosing the entry still waits for it.
    private static let searchTimeout: TimeInterval = 30

    /// The entry on a commit of the current branch: its later commits go onto a base the sheet asks for.
    func fromHereItem(branch: String, oldBase: Commit) -> NSMenuItem {
        ActionMenuItem("Rebase ab hier auf …") { [weak self] in self?.chooseNewBase(of: branch, from: oldBase) }
    }

    /// "Rebase „feature/b“ auf „main“ (3 Commits, ohne „feature/a“)", or nil when the detection found nothing better than a plain rebase.
    static func title(branch: String, place: String, detection: RebaseBaseDetection) -> String? {
        switch detection {
        case .plain: return nil
        case .tie: return "Rebase „\(branch)“ auf \(place) (Basis mehrdeutig) …"
        case .detected(let base):
            // A former tip of the target branch itself means the target was rewritten, like a fork point.
            let reason = if case .branch(let name) = base.reason, "„\(name)“" == place { without(.forkPoint(name)) } else { without(base.reason) }
            return "Rebase „\(branch)“ auf \(place) (\(commits(base.moving)), \(reason))"
        }
    }

    private static func commits(_ count: Int) -> String { count == 1 ? "1 Commit" : "\(count) Commits" }

    private static func without(_ reason: RebaseBase.Reason) -> String {
        switch reason {
        case .branch(let name): "ohne „\(name)“"
        case .squashed(let commit): "ohne die in \(commit.prefix(7)) gesquashten"
        case .forkPoint(let ref): "ohne die alten von „\(ref)“"
        }
    }

    /// „main“ for a row with a branch or tag, else "diesen Commit". Local branches come first, then remote branches, then tags.
    func placeName(of commit: Commit) -> String {
        let refs = viewModel.refsByCommit[commit.id] ?? []
        let name = branchRef(at: commit) ?? refs.first { $0.kind == .tag }?.name
        return name.map { "„\($0)“" } ?? "diesen Commit"
    }

    /// A branch at the commit, whose reflog can tell an earlier position for `--fork-point`.
    private func branchRef(at commit: Commit) -> String? {
        let refs = viewModel.refsByCommit[commit.id] ?? []
        let local = refs.first { $0.kind == .localBranch }
        let remote = refs.first { if case .remoteBranch = $0.kind { !$0.name.hasSuffix("/HEAD") } else { false } }
        return (local ?? remote)?.name
    }

    // MARK: Actions

    private func rebase(onto target: Commit) {
        Task {
            let hint = await publishedHint(rewrittenBy: target.id)
            runRebase(CommitActionsController.note("git rebase", hint)) { try await $0.rebaseCurrentBranch(onto: target.id) }
        }
    }

    private func rebase(_ branch: String, onto target: Commit, detected detection: RebaseBaseDetection) async {
        switch detection {
        case .plain: rebase(onto: target)
        case .tie: await chooseBase(of: branch, onto: target, detection: detection)
        case .detected(let base): await rebase(branch, onto: target.id, from: base.commit)
        }
    }

    private func rebase(_ branch: String, onto newBase: String, from oldBase: String) async {
        let hint = await publishedHint(rewrittenBy: oldBase)
        runRebase(CommitActionsController.note("git rebase --onto \(newBase.prefix(7)) \(oldBase.prefix(7))", hint)) { try await $0.rebase(onto: newBase, from: oldBase, branch: branch) }
    }

    /// The sheet for the old base, offering the detected candidates first and preselecting the detected base.
    private func chooseBase(of branch: String, onto target: Commit, detection: RebaseBaseDetection) async {
        let found: [RebaseBase] = switch detection {
        case .detected(let base): [base]
        case .tie(let bases): bases
        case .plain: []
        }
        let detected = found.map { RebaseOntoSheet.Candidate(title: "\($0.commit.prefix(7)) – \(Self.without($0.reason)), \(Self.commits($0.moving))", revision: $0.commit) }
        let refs = viewModel.refs.filter { $0.kind == .localBranch && $0.name != branch || $0.kind == .tag }.map { RebaseOntoSheet.Candidate(title: $0.name, revision: $0.name) }
        let suggestion = found.count == 1 ? detected.first?.title : nil
        let sheet = RebaseOntoSheet(branch: branch, choice: .oldBase(newBase: target, place: placeName(of: target)), candidates: detected + refs, suggestion: suggestion, hint: nil, repository: viewModel.repository)
        guard let answer = await sheet.ask(using: prompter) else { return }
        await rebase(branch, onto: answer.newBase, from: answer.oldBase)
    }

    private func chooseNewBase(of branch: String, from oldBase: Commit) {
        let repository = viewModel.repository
        let candidates = viewModel.refs.filter { ref in
            switch ref.kind {
            case .localBranch: ref.name != branch
            case .remoteBranch: !ref.name.hasSuffix("/HEAD")
            case .tag: true
            default: false
            }
        }.map { RebaseOntoSheet.Candidate(title: $0.name, revision: $0.name) }
        let suggestion = ["main", "master", "origin/main", "origin/master"].first { name in candidates.contains { $0.title == name } }
        Task {
            let moving = (try? await repository.commitCount(from: oldBase.id, to: branch)) ?? 0
            let hint = await publishedHint(rewrittenBy: oldBase.id)
            let sheet = RebaseOntoSheet(branch: branch, choice: .newBase(oldBase: oldBase, moving: moving), candidates: candidates, suggestion: suggestion, hint: hint, repository: repository)
            guard let answer = await sheet.ask(using: prompter) else { return }
            runRebase(CommitActionsController.note("git rebase --onto \(answer.newBase.prefix(7))", hint)) { try await $0.rebase(onto: answer.newBase, from: answer.oldBase, branch: branch) }
        }
    }

    private func publishedHint(rewrittenBy commit: String) async -> String? {
        CommitActionsController.publishedHint(await viewModel.repository.publishedCommitCount(rewrittenBy: commit), upstream: viewModel.status?.branch.upstream)
    }
}

/// The detection's result, handed from the background search to the menu's timer.
private final class DetectionResult: Sendable {
    private let result = Mutex<RebaseBaseDetection?>(nil)

    var value: RebaseBaseDetection? { result.withLock { $0 } }

    func store(_ detection: RebaseBaseDetection) { result.withLock { $0 = detection } }
}
