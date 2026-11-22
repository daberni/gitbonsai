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
        let name = RefName.branch(branch)
        let interactiveTitle: LocalizedStringResource = if let place { LocalizedStringResource("rebase.onto.interactive", defaultValue: "Rebase \(name) interactively onto \(place.marked)…", bundle: .module) } else { LocalizedStringResource("rebase.onto.interactiveHere", defaultValue: "Rebase \(name) interactively onto this Commit…", bundle: .module) }
        // The sheet names the target in its own sentences; a commit without a branch or tag is "this commit" there too.
        let targetName = place ?? RefString(LocalizedStringResource("rebase.onto.thisCommit", defaultValue: "this commit", bundle: .module))
        guard !viewModel.isReachableFromHead(commit.id) else {
            if let reason = interactive.inPlaceReason(for: commit) { return [Self.disabled(RefString(interactiveTitle), reason)] }
            return [ActionMenuItem(interactiveTitle) { [weak self] in self?.interactive.openSheet(branch: branch, onto: commit, targetName: targetName, detection: .plain(moving: 0)) }]
        }
        let repository = viewModel.repository
        let targetRef = branchRef(at: commit)
        let found = DetectionResult()
        let detection = Task.detached {
            let result = await repository.detectRebaseBase(of: branch, onto: commit.id, targetRef: targetRef)
            found.store(result)
            return result
        }
        let searchingTitle: LocalizedStringResource = if let place { LocalizedStringResource("rebase.onto.finding", defaultValue: "Rebase \(name) onto \(place.marked) (finding base…)", bundle: .module) } else { LocalizedStringResource("rebase.onto.findingHere", defaultValue: "Rebase \(name) onto this Commit (finding base…)", bundle: .module) }
        let oneClick = ActionMenuItem(searchingTitle) { [weak self] in
            Task { await self?.rebase(branch, onto: commit, targetName: targetName, detection: detection.value) }
        }
        let sheet = ActionMenuItem(interactiveTitle) { [weak self] in
            Task {
                let result = await detection.value
                self?.interactive.openSheet(branch: branch, onto: commit, targetName: targetName, detection: result)
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

    /// "Rebase feature/b onto main (3 commits, without feature/a)", or with the commit count alone when the merge base is all there is. `place` nil is a commit without a branch or tag.
    static func title(branch: String, place: RefString?, detection: RebaseBaseDetection) -> RefString {
        let name = RefName.branch(branch)
        switch detection {
        // Without own commits the rebase only fast-forwards; a count of none would read odd.
        case .plain(let moving) where moving == 0:
            guard let place else { return RefString(LocalizedStringResource("rebase.onto.fastForwardHere", defaultValue: "Rebase \(name) onto this Commit (fast-forward)", bundle: .module)) }
            return RefString(LocalizedStringResource("rebase.onto.fastForward", defaultValue: "Rebase \(name) onto \(place.marked) (fast-forward)", bundle: .module))
        case .plain(let moving):
            return title(branch: branch, place: place, notes: [commits(moving)])
        case .tie:
            guard let place else { return RefString(LocalizedStringResource("rebase.onto.ambiguousHere", defaultValue: "Rebase \(name) onto this Commit (ambiguous base)…", bundle: .module)) }
            return RefString(LocalizedStringResource("rebase.onto.ambiguous", defaultValue: "Rebase \(name) onto \(place.marked) (ambiguous base)…", bundle: .module))
        case .detected(let base):
            // A former tip of the target branch itself means the target was rewritten, like a fork point.
            let reason = if case .branch(let target) = base.reason, place?.containsNames == true, target == place?.plain { without(.forkPoint(target)) } else { without(base.reason) }
            return title(branch: branch, place: place, notes: [commits(base.moving), reason])
        }
    }

    /// The notes are complete phrases of their own, also shown alone elsewhere, listed in parentheses after the title.
    private static func title(branch: String, place: RefString?, notes: [RefString]) -> RefString {
        let name = RefName.branch(branch)
        let list = notes.map(\.marked).joined(separator: ", ")
        guard let place else { return RefString(LocalizedStringResource("rebase.onto.withDetailHere", defaultValue: "Rebase \(name) onto this Commit (\(list))", bundle: .module)) }
        return RefString(LocalizedStringResource("rebase.onto.withDetail", defaultValue: "Rebase \(name) onto \(place.marked) (\(list))", bundle: .module))
    }

    private static func commits(_ count: Int) -> RefString { RefString(LocalizedStringResource("common.commitCount", defaultValue: "\(count) commits", bundle: .module)) }

    static func without(_ reason: RebaseBase.Reason) -> RefString {
        switch reason {
        case .branch(let name): RefString(LocalizedStringResource("rebase.onto.withoutBranch", defaultValue: "without \(RefName.branch(name))", bundle: .module))
        case .squashed(let commit): RefString(LocalizedStringResource("rebase.onto.withoutSquashed", defaultValue: "without those squashed in \(RefName.commit(commit))", bundle: .module))
        case .forkPoint(let ref): RefString(LocalizedStringResource("rebase.onto.withoutForkPoint", defaultValue: "without the old ones from \(RefName.branch(ref))", bundle: .module))
        }
    }

    /// main for a row with a branch or tag, else nil for "this commit". Local branches come first, then remote branches, then tags.
    func placeName(of commit: Commit) -> RefString? {
        let refs = viewModel.refsByCommit[commit.id] ?? []
        if let local = branch(at: commit, local: true) { return RefString(marked: RefName.branch(local)) }
        if let remote = branch(at: commit, local: false) { return RefString(marked: RefName.remoteBranch(remote)) }
        if let tag = refs.first(where: { $0.kind == .tag })?.name { return RefString(marked: RefName.tag(tag)) }
        return nil
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
    private func rebase(_ branch: String, onto target: Commit, targetName: RefString, detection: RebaseBaseDetection) async {
        if case .tie = detection { return interactive.openSheet(branch: branch, onto: target, targetName: targetName, detection: detection) }
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
                runPlainRebase(CommitActionsController.note("git rebase --onto \(target.id.prefix(RefString.shortSHA)) \(base.prefix(RefString.shortSHA))", hint)) { try await $0.rebase(onto: target.id, from: base, branch: branch) }
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
