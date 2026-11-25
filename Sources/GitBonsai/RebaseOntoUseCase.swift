import AppKit
import GitEngine
import Synchronization

/// The rebase group of the commit menu. On a commit outside the current branch: a one-click rebase from the detected base, and the interactive sheet onto the commit.
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
    /// With a branch's plain rebase (`allCommits`) next to the detected one there are several variants; they go into one entry with a submenu: all commits, only the branch's own, interactively.
    func entries(branch: String, commit: Commit, allCommits: MenuEntry? = nil) -> [MenuEntry] {
        let plain = allCommits.map { [$0] } ?? []
        if let head = viewModel.headSHA, head != commit.id, viewModel.history.reachable(from: commit.id).contains(head) { return plain }
        let place = placeName(of: commit)
        let name = RefName.branch(branch)
        let interactiveTitle: LocalizedStringResource = if let place { LocalizedStringResource("rebase.onto.interactive", defaultValue: "Rebase \(name) interactively onto \(place.marked)…", bundle: .module) } else { LocalizedStringResource("rebase.onto.interactiveHere", defaultValue: "Rebase \(name) interactively onto this Commit…", bundle: .module) }
        // The sheet names the target in its own sentences; a commit without a branch or tag is "this commit" there too.
        let targetName = place ?? RefString(LocalizedStringResource("rebase.onto.thisCommit", defaultValue: "this commit", bundle: .module))
        guard !viewModel.isReachableFromHead(commit.id) else {
            if let reason = interactive.inPlaceReason(for: commit) { return plain + [Self.disabled(RefString(interactiveTitle), reason)] }
            return plain + [MenuEntry(interactiveTitle) { [weak self] in self?.interactive.openSheet(branch: branch, onto: commit, targetName: targetName, detection: .plain(moving: 0)) }]
        }
        let repository = viewModel.repository
        let targetRef = branchRef(at: commit)
        let found = DetectionResult()
        let key = "\(branch) \(viewModel.headSHA ?? "") \(commit.id)"
        let detection = Task.detached {
            let result = await repository.detectRebaseBase(of: branch, onto: commit.id, targetRef: targetRef)
            found.store(result)
            return result
        }
        let searchingTitle: LocalizedStringResource = if let place { LocalizedStringResource("rebase.onto.finding", defaultValue: "Rebase \(name) onto \(place.marked) (finding base…)", bundle: .module) } else { LocalizedStringResource("rebase.onto.findingHere", defaultValue: "Rebase \(name) onto this Commit (finding base…)", bundle: .module) }
        var oneClick = MenuEntry(searchingTitle) { [weak self] in
            Task { await self?.rebase(branch, onto: commit, targetName: targetName, detection: detection.value) }
        }
        var sheet = MenuEntry(interactiveTitle) { [weak self] in
            Task {
                let result = await detection.value
                self?.interactive.openSheet(branch: branch, onto: commit, targetName: targetName, detection: result)
            }
        }
        let isVariant = allCommits != nil
        let known = isVariant ? detections[key] ?? Self.briefly(found) : nil
        // Nothing left out: the branch's own commits are all of them, so the plain rebase and the interactive one stay single entries.
        if let allCommits, let known, Self.ownCommitsTitle(branch: branch, place: place, detection: known) == nil {
            detections[key] = known
            return [allCommits, sheet]
        }
        if allCommits != nil {
            oneClick.title = Self.ownCommits(branch: branch, notes: [RefString(LocalizedStringResource("rebase.onto.note.findingBase", defaultValue: "finding base…", bundle: .module))])
            sheet.title = RefString(LocalizedStringResource("rebase.onto.variant.interactive", defaultValue: "Interactively…", bundle: .module))
        }
        let live = LiveMenuTitle(oneClick.title)
        oneClick.liveTitle = live
        let grouped = allCommits.map { variants($0, oneClick: oneClick, sheet: sheet, commit: commit) }
        // The timer fires on the main run loop; storing the result only crosses into its closure.
        nonisolated(unsafe) let remember: (RebaseBaseDetection) -> Void = { [weak self] result in self?.detections[key] = result }
        // An open menu runs its own tracking loop, which serves no main-actor tasks; a timer in the common modes still fires and updates the entry in place.
        let started = Date()
        // The timer fires on the main run loop; an item that closed takes the title along.
        let poll = Timer(timeInterval: 0.05, repeats: true) { [weak live] timer in
            let finished = MainActor.assumeIsolated {
                guard let entry = live, Date().timeIntervalSince(started) < Self.searchTimeout else { return true }
                guard let result = found.value else { return false }
                if isVariant {
                    remember(result)
                    entry.update(Self.ownCommitsTitle(branch: branch, place: place, detection: result) ?? Self.allOwn(branch: branch, result))
                } else {
                    entry.update(Self.title(branch: branch, place: place, detection: result))
                }
                return true
            }
            if finished {
                timer.invalidate()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        return grouped.map { [$0] } ?? [oneClick, sheet]
    }

    /// The branch's rebase entry keeps its title and gets the variants as its submenu.
    private func variants(_ allCommits: MenuEntry, oneClick: MenuEntry, sheet: MenuEntry, commit: Commit) -> MenuEntry {
        let moving = viewModel.headSHA.map { viewModel.history.reachable(from: $0).subtracting(viewModel.history.reachable(from: commit.id)).count } ?? 0
        var all = allCommits
        all.role = nil
        all.title = RefString(LocalizedStringResource("rebase.onto.variant.all", defaultValue: "All commits (\(moving))", bundle: .module))
        return MenuEntry(allCommits.title, submenu: [[all, oneClick, sheet]])
    }

    /// "Only main's own commits (1 commit, without feature/a)"; nil when the detection leaves nothing out, so the variant equals all commits.
    private static func ownCommitsTitle(branch: String, place: RefString?, detection: RebaseBaseDetection) -> RefString? {
        switch detection {
        case .plain: return nil
        case .tie: return ownCommits(branch: branch, notes: [RefString(LocalizedStringResource("rebase.onto.note.ambiguousBase", defaultValue: "ambiguous base", bundle: .module))])
        case .detected(let base):
            let reason = if case .branch(let target) = base.reason, place?.containsNames == true, target == place?.plain { without(.forkPoint(target)) } else { without(base.reason) }
            return ownCommits(branch: branch, notes: [commits(base.moving), reason])
        }
    }

    /// The shape stays while the menu is open: a detection that leaves nothing out names the count of all commits.
    private static func allOwn(branch: String, _ detection: RebaseBaseDetection) -> RefString {
        guard case .plain(let moving) = detection else { return ownCommits(branch: branch, notes: []) }
        return ownCommits(branch: branch, notes: [commits(moving)])
    }

    private static func ownCommits(branch: String, notes: [RefString]) -> RefString {
        let list = notes.map(\.marked).joined(separator: ", ")
        return RefString(LocalizedStringResource("rebase.onto.variant.own", defaultValue: "Only \(RefName.branch(branch))'s own commits (\(list))", bundle: .module))
    }

    /// A detection that finishes within this time decides the menu's shape before it opens.
    private static let menuWait: TimeInterval = 0.15

    private static func briefly(_ found: DetectionResult) -> RebaseBaseDetection? {
        let deadline = Date().addingTimeInterval(menuWait)
        while found.value == nil, Date() < deadline { usleep(5_000) }
        return found.value
    }

    /// After this many seconds an open menu stops waiting for the detected base; choosing the entry still waits for it.
    private static let searchTimeout: TimeInterval = 30

    private static func disabled(_ title: RefString, _ reason: String) -> MenuEntry {
        var entry = MenuEntry(title) {}
        entry.disabledReason = reason
        return entry
    }

    /// "Rebase feature/b onto main (3 commits, without feature/a)", or with the commit count alone when the merge base is all there is. `place` nil is a commit without a branch or tag.
    static func title(branch: String, place: RefString?, detection: RebaseBaseDetection) -> RefString {
        let name = RefName.branch(branch)
        switch detection {
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
            let hint = CommitActions.publishedHint(await repository.publishedCommitCount(rewrittenBy: range.base), upstream: upstream)
            interactive.start(plan, note: CommitActions.note(InteractiveRebaseUseCase.command(plan), hint))
        } catch {
            let base: String? = if case .detected(let found) = detection { found.commit } else { nil }
            let hint = CommitActions.publishedHint(await repository.publishedCommitCount(rewrittenBy: base ?? target.id), upstream: upstream)
            if let base {
                runPlainRebase(CommitActions.note("git rebase --onto \(target.id.prefix(RefString.shortSHA)) \(base.prefix(RefString.shortSHA))", hint)) { repository in try await Signposts.measure("rebase", branch) { try await repository.rebase(onto: target.id, from: base, branch: branch) } }
            } else {
                runPlainRebase(CommitActions.note("git rebase", hint)) { repository in try await Signposts.measure("rebase", branch) { try await repository.rebaseCurrentBranch(onto: target.id) } }
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
