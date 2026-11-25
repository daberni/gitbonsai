import AppKit
import GitEngine

/// The rebase group of the commit menu. On a commit outside the current branch: a one-click rebase that moves only the branch's own commits when their base is clear, and the interactive sheet onto the commit.
/// On a commit of the branch: the interactive sheet in place. Both forms share one detection and run through the interactive rebase engine, so the status line can undo them.
/// Rewriting published commits only gets the hint in the status line, as everywhere else.
@MainActor
final class RebaseOntoUseCase {
    /// Runs a rebase git cannot take as a todo list (a merge in the range, a fast-forward), with the status line's note.
    typealias Runner = (_ note: String, _ operation: @escaping @Sendable (Repository) async throws -> OperationReport?) -> Void

    private let viewModel: GraphViewModel
    private let interactive: InteractiveRebaseUseCase
    private let runPlainRebase: Runner
    /// Detections of earlier menus by branch, HEAD and target: an open menu keeps its shape, so a result that would change it shows from the next open on.
    private var detections: [String: RebaseBaseDetection] = [:]

    init(viewModel: GraphViewModel, interactive: InteractiveRebaseUseCase, runPlainRebase: @escaping Runner) {
        self.viewModel = viewModel
        self.interactive = interactive
        self.runPlainRebase = runPlainRebase
    }

    // MARK: Menu

    /// Nothing on a descendant of HEAD: the rebase would only fast-forward, which the menu's Fast-Forward entry offers.
    /// Off the branch: the one-click rebase and the interactive sheet, both waiting for the base detection that starts when the menu opens.
    func entries(branch: String, commit: Commit) -> [MenuEntry] {
        if let head = viewModel.headSHA, head != commit.id, viewModel.history.reachable(from: commit.id).contains(head) { return [] }
        let place = placeName(of: commit)
        let name = RefName.branch(branch)
        let interactiveTitle: LocalizedStringResource = if let place { LocalizedStringResource("rebase.onto.interactive", defaultValue: "Rebase \(name) interactively onto \(place.marked)…", bundle: .module) } else { LocalizedStringResource("rebase.onto.interactiveHere", defaultValue: "Rebase \(name) interactively onto this Commit…", bundle: .module) }
        // The sheet names the target in its own sentences; a commit without a branch or tag is "this commit" there too.
        let targetName = place ?? RefString(LocalizedStringResource("rebase.onto.thisCommit", defaultValue: "this commit", bundle: .module))
        guard !viewModel.isReachableFromHead(commit.id) else {
            if let reason = interactive.inPlaceReason(for: commit) { return [Self.disabled(RefString(interactiveTitle), reason)] }
            return [MenuEntry(interactiveTitle) { [weak self] in self?.interactive.openSheet(branch: branch, onto: commit, targetName: targetName, detection: .plain(moving: 0)) }.movingHead]
        }
        let repository = viewModel.repository
        let targetRef = branchRef(at: commit)
        let detection = Task.detached { await repository.detectRebaseBase(of: branch, onto: commit.id, targetRef: targetRef) }
        let title: LocalizedStringResource = if let place { LocalizedStringResource("rebase.onto.title", defaultValue: "Rebase \(name) onto \(place.marked)", bundle: .module) } else { LocalizedStringResource("rebase.onto.titleHere", defaultValue: "Rebase \(name) onto this Commit", bundle: .module) }
        let oneClick = MenuEntry(title) { [weak self] in
            Task { await self?.rebase(branch, onto: commit.id, targetRef: targetRef, detection: detection.value) }
        }
        let sheet = MenuEntry(interactiveTitle) { [weak self] in
            Task {
                let result = await detection.value
                self?.interactive.openSheet(branch: branch, onto: commit, targetName: targetName, detection: result)
            }
        }
        return [oneClick.movingHead, sheet.movingHead]
    }

    private static func disabled(_ title: RefString, _ reason: String) -> MenuEntry {
        var entry = MenuEntry(title) {}
        entry.disabledReason = reason
        return entry
    }

    /// "Rebased only main's own 3 commits, without feature/a": what the one-click rebase left out.
    static func leftOutToast(branch: String, base: RebaseBase, target: String?) -> RefString {
        // A former tip of the target branch itself means the target was rewritten, like a fork point.
        let reason = if case .branch(let name) = base.reason, name == target { without(.forkPoint(name)) } else { without(base.reason) }
        return RefString(LocalizedStringResource("rebase.onto.toast.ownCommits", defaultValue: "Rebased only \(RefName.branch(branch))'s own \(commits(base.moving).marked), \(reason.marked)", bundle: .module))
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

    /// The same name for a commit known only by its ID, such as a merge's parent.
    func placeName(ofCommit id: String) -> RefString? {
        guard let row = viewModel.rowIndex(of: id) else { return nil }
        return placeName(of: viewModel.commits[row])
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

    /// The one-click rebase of `branch` onto a ref's tip, as the sidebar's branch menus offer it: the same detection and the same choice as the history's entry.
    func rebase(_ branch: String, onto ref: Ref) {
        let repository = viewModel.repository
        let target = ref.target
        let targetRef = ref.name
        Task {
            let detection = await repository.detectRebaseBase(of: branch, onto: target, targetRef: targetRef)
            await rebase(branch, onto: target, targetRef: targetRef, detection: detection)
        }
    }

    /// The one-click form. A base found without doubt moves only the branch's own commits (`--onto`), and a toast names what stayed behind; an ambiguous base, or none better than the merge base, runs a plain `git rebase <target>`.
    /// A merge in the range or a fast-forward also goes to plain `git rebase`.
    private func rebase(_ branch: String, onto target: String, targetRef: String?, detection: RebaseBaseDetection) async {
        let repository = viewModel.repository
        let upstream = viewModel.status?.branch.upstream
        guard case .detected(let base) = detection else {
            let hint = CommitActions.publishedHint(await repository.publishedCommitCount(rewrittenBy: target), upstream: upstream)
            return runPlainRebase(CommitActions.note("git rebase", hint)) { repository in try await Signposts.measure("rebase", branch) { try await repository.rebaseCurrentBranch(onto: target) } }
        }
        let toast = Self.leftOutToast(branch: branch, base: base, target: targetRef)
        do {
            let range = try await repository.rebaseRange(onto: target, detection: detection)
            let plan = RebasePlan(range: range, branches: await repository.stackedBranches(in: range.commits))
            let hint = CommitActions.publishedHint(await repository.publishedCommitCount(rewrittenBy: range.base), upstream: upstream)
            interactive.start(plan, note: CommitActions.note(InteractiveRebaseUseCase.command(plan), hint), finished: toast)
        } catch {
            let hint = CommitActions.publishedHint(await repository.publishedCommitCount(rewrittenBy: base.commit), upstream: upstream)
            runPlainRebase(CommitActions.note("git rebase --onto \(target.prefix(RefString.shortSHA)) \(base.commit.prefix(RefString.shortSHA))", hint)) { repository in try await Signposts.measure("rebase", branch) { try await repository.rebase(onto: target, from: base.commit, branch: branch) } }
        }
    }
}

