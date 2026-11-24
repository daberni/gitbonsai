import Foundation

/// A commit of a branch below which the branch's own work starts, so that `git rebase --onto <target> <commit> <branch>` moves only that work.
public struct RebaseBase: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The commit is, or per its reflog was, the tip of this other local branch: the branch is stacked on it.
        case branch(String)
        /// The branch's commits up to here add up to this commit of the target, which squash-merged them.
        case squashed(into: String)
        /// The target ref named here pointed at the commit before it was rewritten (`git merge-base --fork-point`).
        case forkPoint(String)
    }

    public let commit: String
    public let reason: Reason
    /// Commits in `commit..branch`, which the rebase moves.
    public let moving: Int

    public init(commit: String, reason: Reason, moving: Int) {
        self.commit = commit
        self.reason = reason
        self.moving = moving
    }
}

public enum RebaseBaseDetection: Sendable, Equatable {
    case detected(RebaseBase)
    /// Equally near candidates; the user picks one.
    case tie([RebaseBase])
    /// Nothing better than the merge base: a plain `git rebase <target>` moving this many commits.
    case plain(moving: Int)
}

extension Repository {
    /// Own commits beyond this many are not searched for a squash merge; each one costs a `git diff`.
    static let squashSearchLimit = 50
    /// Target commits beyond this many are not searched for a squash merge.
    static let squashTargetLimit = 500

    /// Finds where the own work of `branch` starts relative to `target`, trying in order: the nearest commit that is or was the tip of another local branch,
    /// the longest run of the branch's oldest commits that a target commit squash-merged, and the fork point of `targetRef` (a branch name with a reflog).
    public func detectRebaseBase(of branch: String, onto target: String, targetRef: String?) async -> RebaseBaseDetection {
        let own = (try? await revList(["^\(target)", branch])) ?? []
        let plain = RebaseBaseDetection.plain(moving: own.count)
        guard own.count > 1 else { return plain }
        let ownSet = Set(own)
        if let stacked = await stackedBases(of: branch, ownCommits: ownSet) { return stacked }
        if let squashed = await squashedBase(of: branch, onto: target) { return .detected(squashed) }
        if let targetRef, let forkPoint = await forkPointBase(of: branch, onto: target, targetRef: targetRef, ownCommits: ownSet) { return .detected(forkPoint) }
        return plain
    }

    /// What a rebase of the current branch onto `target` replays. A target in HEAD's history is the in-place rebase from there; otherwise the range starts at the detected base,
    /// the first of tied candidates, or the merge base when nothing better was found.
    public func rebaseRange(onto target: String, detection: RebaseBaseDetection) async throws -> RebaseRange {
        if await isAncestorOfHead(target) { return try await rebaseRange(from: target, onto: target) }
        let detected: String? = switch detection {
        case .detected(let base): base.commit
        case .tie(let bases): bases.first?.commit
        case .plain: nil
        }
        let mergeBase = await mergeBase(target, "HEAD")
        guard let base = detected ?? mergeBase else { throw RebasePlanError.baseNotInHistory }
        return try await rebaseRange(from: base, onto: target)
    }

    /// Rule 1. Candidates are own commits below the tip that some other local branch points at or pointed at; the one leaving the fewest commits to move wins.
    private func stackedBases(of branch: String, ownCommits: Set<String>) async -> RebaseBaseDetection? {
        guard let tip = await resolveCommit(branch) else { return nil }
        var names: [String: [String]] = [:]
        for (commit, name) in await branchTips() where name != branch && commit != tip && ownCommits.contains(commit) {
            if !(names[commit]?.contains(name) ?? false) { names[commit, default: []].append(name) }
        }
        var bases: [RebaseBase] = []
        for (commit, branches) in names {
            guard let moving = try? await commitCount(from: commit, to: branch) else { continue }
            bases.append(RebaseBase(commit: commit, reason: .branch(branches[0]), moving: moving))
        }
        guard let nearest = bases.map(\.moving).min() else { return nil }
        let winners = bases.filter { $0.moving == nearest }.sorted { $0.commit < $1.commit }
        return winners.count == 1 ? .detected(winners[0]) : .tie(winners)
    }

    /// Every local branch's current tip first, then its earlier tips from the reflog, as (commit, branch name).
    private func branchTips() async -> [(String, String)] {
        var tips: [(String, String)] = []
        if let refs = try? await runner.run(["for-each-ref", "--format=%(objectname)%00%(refname:short)", "refs/heads"]) {
            tips += Self.pairs(refs.stdoutString)
        }
        if let reflog = try? await runner.run(["log", "--walk-reflogs", "--format=%H%x00%gD", "--branches"]) {
            // %gD reads `<branch>@{<n>}`.
            tips += Self.pairs(reflog.stdoutString).map { commit, selector in (commit, selector.range(of: "@{", options: .backwards).map { String(selector[..<$0.lowerBound]) } ?? selector) }
        }
        return tips
    }

    private static func pairs(_ output: String) -> [(String, String)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// Rule 2. The parent branch started at the merge base, so a run always starts with the oldest own commit; the longest run whose combined diff has the patch-id of a target commit wins.
    private func squashedBase(of branch: String, onto target: String) async -> RebaseBase? {
        guard let mergeBase = try? await runner.run(["merge-base", target, branch]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty else { return nil }
        let line = Array(((try? await revList(["--first-parent", "--reverse", "^\(target)", branch])) ?? []).prefix(Self.squashSearchLimit))
        // The whole branch would leave nothing to move.
        let runs = line.dropLast()
        guard !runs.isEmpty, let targetLog = try? await runner.run(["log", "-p", "--no-merges", "--no-color", "--no-ext-diff", "--no-textconv"] + Self.patchPrefixes + ["--max-count=\(Self.squashTargetLimit)", "\(mergeBase)..\(target)"]) else { return nil }
        let targetIDs = await patchIDs(targetLog.stdout)
        guard !targetIDs.isEmpty else { return nil }
        var combined = Data()
        for commit in runs {
            guard let diff = try? await runner.run(["diff", "--no-color", "--no-ext-diff", "--no-textconv"] + Self.patchPrefixes + [mergeBase, commit]) else { continue }
            combined.append(Data("commit \(commit)\n".utf8))
            combined.append(diff.stdout)
        }
        let runIDs = await patchIDs(combined)
        let squashCommits = Dictionary(targetIDs.map { ($0.patchID, $0.commit) }) { first, _ in first }
        for commit in runs.reversed() {
            guard let id = runIDs.first(where: { $0.commit == commit })?.patchID, let squash = squashCommits[id], let moving = try? await commitCount(from: commit, to: branch) else { continue }
            return RebaseBase(commit: commit, reason: .squashed(into: squash), moving: moving)
        }
        return nil
    }

    /// `git patch-id --stable` over a stream of patches, each led by a `commit <sha>` line.
    private func patchIDs(_ patches: Data) async -> [(patchID: String, commit: String)] {
        guard !patches.isEmpty, let result = try? await runner.run(["patch-id", "--stable"], stdin: patches) else { return [] }
        return result.stdoutString.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ").map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// Rule 3. Only a fork point other than the merge base says more than a plain rebase.
    private func forkPointBase(of branch: String, onto target: String, targetRef: String, ownCommits: Set<String>) async -> RebaseBase? {
        guard let result = try? await runner.run(["merge-base", "--fork-point", targetRef, branch], accepting: [0, 1]) else { return nil }
        let forkPoint = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ownCommits.contains(forkPoint), let moving = try? await commitCount(from: forkPoint, to: branch), moving > 0 else { return nil }
        return RebaseBase(commit: forkPoint, reason: .forkPoint(targetRef), moving: moving)
    }

    private func revList(_ arguments: [String]) async throws -> [String] {
        try await runner.run(["rev-list"] + arguments).stdoutString.split(separator: "\n").map(String.init)
    }
}
