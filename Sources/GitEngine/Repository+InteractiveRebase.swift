import Foundation

/// Why the app refuses to plan or start an interactive rebase.
public enum RebasePlanError: Error, Sendable, Equatable {
    /// The base is not an ancestor of HEAD.
    case baseNotInHistory
    /// A merge between the base and HEAD brings in these commits, which the base does not have; flattening it would replay or lose them.
    case mergeInRange(bringsIn: [RebaseCommit])
    /// The base is HEAD itself.
    case nothingToRebase
    /// The commit is not on the current branch's own line of commits.
    case notOnCurrentBranch
    /// The root commit has no parent to start from.
    case rootCommit
    /// HEAD has no commit above it to swap with.
    case nothingAbove
    case invalidPlan(RebasePlanProblem)
}

/// How a started interactive rebase ended for now.
public enum InteractiveRebaseOutcome: Sendable, Equatable {
    case finished
    /// git stopped at an `edit`, a conflict or a failed `exec`; `output` is what git said.
    case stopped(OperationProgress, output: String)
}

/// Where a reword left the commit, or why it has not finished.
public enum RewordOutcome: Sendable, Equatable {
    /// The commit with its new message.
    case rewritten(String)
    /// git stopped while replaying the commits above it; `output` is what git said.
    case stopped(OperationProgress, output: String)
}

/// The context menu's one-step forms of an interactive rebase.
public enum RebaseSingleStep: Sendable, Equatable {
    case reword(String)
    case drop
    /// Swaps the commit with the one above it, its child.
    case moveUp
    /// Swaps the commit with the one below it, its parent.
    case moveDown
}

extension RebasePlan {
    /// The plan touches HEAD and nothing else: no commit above it and no other branch that would have to move along.
    public var rewordsHeadAlone: Bool { onto == nil && steps.count == 1 && branches.isEmpty }
}

extension Repository {
    /// The commits `base..HEAD`, oldest first, which an interactive rebase from `base` replays. Refuses a base outside HEAD's history and a range with merges that bring in commits the base lacks.
    public func rebaseCommits(after base: String) async throws -> [RebaseCommit] {
        try await inPlaceRange(after: base).commits
    }

    /// The first-parent line `base..HEAD` without its merges, and how many merges it drops. A merge whose other parents only bring in what `base` already has (the target pulled in earlier) is flattened like `git rebase -i` does; any other merge is refused with the commits it brings in.
    private func inPlaceRange(after base: String) async throws -> (commits: [RebaseCommit], merges: Int) {
        guard (try? await runner.run(["merge-base", "--is-ancestor", base, "HEAD"])) != nil else { throw RebasePlanError.baseNotInHistory }
        let format = "--format=%H%x1f%P%x1f%s%x1f%B%x1e"
        let line = Self.parseRebaseCommits(try await runner.run(["log", "--reverse", "--first-parent", format, "\(base)..HEAD"]).stdout)
        let merges = line.filter { $0.parents.count > 1 }
        if !merges.isEmpty {
            // Commits of the range off the first-parent line came in through a merge and are not in the base.
            let all = Self.parseRebaseCommits(try await runner.run(["log", "--reverse", "--topo-order", "--no-merges", format, "\(base)..HEAD"]).stdout)
            let onLine = Set(line.map(\.id))
            let broughtIn = all.filter { !onLine.contains($0.id) }
            if !broughtIn.isEmpty { throw RebasePlanError.mergeInRange(bringsIn: broughtIn) }
        }
        let commits = line.filter { $0.parents.count <= 1 }
        if commits.isEmpty { throw RebasePlanError.nothingToRebase }
        return (commits, merges.count)
    }

    /// The commits an interactive rebase of the current branch onto `target` replays, from `base` on. With `base == target` it is the in-place rebase of `rebaseCommits(after:)`;
    /// otherwise `base` need not be an ancestor of HEAD (a branch whose commits stay behind, say), merges are flattened, and commits whose changes the target already has are marked by `git cherry`.
    public func rebaseRange(from base: String, onto target: String) async throws -> RebaseRange {
        guard base != target else {
            let range = try await inPlaceRange(after: base)
            return RebaseRange(base: base, target: target, commits: range.commits, alreadyOnTarget: [], flattenedMerges: range.merges)
        }
        // Like a plain `git rebase` without --rebase-merges, merges in the range are flattened: only their commits are replayed, in topological order.
        let result = try await runner.run(["log", "--reverse", "--topo-order", "--no-merges", "--format=%H%x1f%P%x1f%s%x1f%B%x1e", "\(base)..HEAD"])
        let commits = Self.parseRebaseCommits(result.stdout)
        if commits.isEmpty { throw RebasePlanError.nothingToRebase }
        let merges = try await runner.run(["rev-list", "--count", "--merges", "\(base)..HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        // `git cherry <upstream> <head> <limit>` marks with "-" each commit of limit..head whose patch-id the upstream has.
        let cherry = (try? await runner.run(["cherry", target, "HEAD", base]))?.stdoutString ?? ""
        let applied = Set(cherry.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) })
        return RebaseRange(base: base, target: target, commits: commits, alreadyOnTarget: applied, flattenedMerges: Int(merges) ?? 0)
    }

    /// One commit with its message, as the rebase sheet shows its base and target; nil when `revision` names none.
    public func rebaseCommit(_ revision: String) async -> RebaseCommit? {
        guard let sha = await resolveCommit(revision), let result = try? await runner.run(["log", "-1", "--format=%H%x1f%P%x1f%s%x1f%B%x1e", sha]) else { return nil }
        return Self.parseRebaseCommits(result.stdout).first
    }

    /// The best common ancestor of two commits, or nil when they share none.
    public func mergeBase(_ first: String, _ second: String) async -> String? {
        guard let result = try? await runner.run(["merge-base", first, second]) else { return nil }
        let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Whether `commit` is HEAD or one of its ancestors, which makes a rebase onto it an in-place rebase.
    public func isAncestorOfHead(_ commit: String) async -> Bool {
        (try? await runner.run(["merge-base", "--is-ancestor", commit, "HEAD"])) != nil
    }

    static func parseRebaseCommits(_ data: Data) -> [RebaseCommit] {
        FieldRecords.parse(data, limit: 4).compactMap { fields in
            guard fields.count == 4, !fields[0].isEmpty else { return nil }
            let message = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            return RebaseCommit(id: fields[0], parents: fields[1].split(separator: " ").map(String.init), subject: fields[2], message: message)
        }
    }

    /// Local branches other than the current one that point at one of `commits`, by commit. Branches checked out in a worktree are left out: git refuses to move them.
    public func stackedBranches(in commits: [RebaseCommit]) async -> [String: [String]] {
        let ids = Set(commits.map(\.id))
        guard let result = try? await runner.run(["for-each-ref", "--format=%(objectname)%00%(refname)%00%(worktreepath)", "refs/heads"]) else { return [:] }
        var branches: [String: [String]] = [:]
        for line in result.stdoutString.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3, ids.contains(String(fields[0])), fields[2].isEmpty else { continue }
            branches[String(fields[0]), default: []].append(String(fields[1]))
        }
        return branches
    }

    /// The plan of a one-step change: the range starts right below the commits it touches, so nothing else is rewritten more than needed. Stacked branches move along.
    public func singleStepPlan(_ step: RebaseSingleStep, commit: String) async throws -> RebasePlan {
        let below = step == .moveDown ? "\(commit)^^" : "\(commit)^"
        guard let base = await resolveCommit(below) else {
            throw await resolveCommit(commit) == nil ? RebasePlanError.notOnCurrentBranch : RebasePlanError.rootCommit
        }
        let commits: [RebaseCommit]
        do {
            commits = try await rebaseCommits(after: base)
        } catch RebasePlanError.baseNotInHistory {
            throw RebasePlanError.notOnCurrentBranch
        }
        let position = step == .moveDown ? 1 : 0
        guard commits.indices.contains(position), commits[position].id == commit else { throw RebasePlanError.notOnCurrentBranch }
        var plan = RebasePlan(base: base, commits: commits, branches: await stackedBranches(in: commits))
        switch step {
        case let .reword(message):
            plan.steps[0].action = .reword
            plan.messages[commit] = message
        case .drop:
            plan.steps[0].action = .drop
        case .moveUp:
            guard commits.count > 1 else { throw RebasePlanError.nothingAbove }
            plan.steps.swapAt(0, 1)
        case .moveDown:
            plan.steps.swapAt(0, 1)
        }
        return plan
    }

    /// Gives the commit a plan of `singleStepPlan(.reword(_:), commit:)` starts with the new `message`.
    /// HEAD alone is amended with `git commit --amend --only`, which leaves the index out, so staged changes stay staged and outside the commit; it can be undone like a rebase.
    /// Everything else runs the plan; uncommitted changes are stashed for it and brought back with their staged state when `plan.autostash` is on.
    public func reword(_ plan: RebasePlan, message: String) async throws -> RewordOutcome {
        guard let commit = plan.steps.first?.commit else { throw RebasePlanError.nothingToRebase }
        if plan.rewordsHeadAlone, await operationInProgress() == nil {
            return .rewritten(try await amendHeadMessage(message))
        }
        var plan = plan
        plan.steps[0].action = .reword
        plan.messages[commit.id] = message
        switch try await startInteractiveRebase(plan) {
        case let .stopped(progress, output):
            return .stopped(progress, output: output)
        case .finished:
            // Nothing above it was dropped, so the commit is as many first parents below HEAD as there are steps above it.
            let position = plan.steps.count - 1
            guard let sha = await resolveCommit(position == 0 ? "HEAD" : "HEAD~\(position)") else { throw RebasePlanError.notOnCurrentBranch }
            return .rewritten(sha)
        }
    }

    /// Rewrites only HEAD's message and leaves `ORIG_HEAD` and an undo record as a finished rebase does; returns the new HEAD.
    private func amendHeadMessage(_ message: String) async throws -> String {
        let before = try await runner.run(["rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = await currentBranchRef()
        _ = try await runner.runWrite(["commit", "--amend", "--only", "--cleanup=whitespace", "-F", "-"], stdin: Data(message.utf8))
        guard let after = await resolveCommit("HEAD") else { throw RebasePlanError.nothingToRebase }
        _ = try await runner.runWrite(["update-ref", "ORIG_HEAD", before])
        try await rebaseSession().finish(with: RebaseUndo(branch: branch, before: before, after: after, stacked: []))
        return after
    }

    /// Runs `git rebase --interactive` with the todo list and messages of `plan`. git stopping at an `edit`, a conflict or a failed `exec` is no error: the rebase stays in progress and the banner takes over.
    public func startInteractiveRebase(_ plan: RebasePlan) async throws -> InteractiveRebaseOutcome {
        if let problem = plan.problem { throw RebasePlanError.invalidPlan(problem) }
        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = await currentBranchRef()
        let stacked = plan.updateRefs ? plan.branches.flatMap { sha, refs in refs.map { RebaseUndo.Move(ref: $0, before: sha, after: nil) } }.sorted { $0.ref < $1.ref } : []
        let session = try await rebaseSession()
        try session.create(for: plan, state: RebaseUndo(branch: branch, before: head, after: nil, stacked: stacked))
        let arguments = Self.messageConfig + [
            "rebase", "--interactive", "--no-autosquash", "--empty=drop",
            plan.updateRefs ? "--update-refs" : "--no-update-refs",
            plan.autostash ? "--autostash" : "--no-autostash",
        ] + (plan.onto.map { ["--onto", $0] } ?? []) + [
            "--end-of-options", plan.base,
        ]
        do {
            let result = try await runner.runWrite(arguments, environment: session.environment)
            if let progress = await operationInProgress() { return .stopped(progress, output: result.stderr + result.stdoutString) }
            return .finished
        } catch let error as GitError {
            if let progress = await operationInProgress() { return .stopped(progress, output: error.stderr) }
            session.remove()
            throw error
        }
    }

    /// Messages the app prepared are taken as they are: lines starting with `#` stay, as in the commit form.
    static let messageConfig = ["-c", "commit.cleanup=whitespace"]

    /// The undo record of an interactive rebase the app started and git has since finished, or nil. Reading it ends the session and keeps the record for `lastRebaseUndo`; an aborted rebase leaves nothing to undo.
    public func finishedInteractiveRebase() async -> RebaseUndo? {
        guard let session = try? await rebaseSession(), session.exists else { return nil }
        guard !FileManager.default.fileExists(atPath: session.rebaseDirectory.path) else { return nil }
        guard var undo = session.readState(), let head = await resolveCommit("HEAD"), head != undo.before else {
            session.remove()
            return nil
        }
        undo.after = head
        for index in undo.stacked.indices {
            undo.stacked[index].after = await resolveCommit(undo.stacked[index].ref)
        }
        session.finish(with: undo)
        return undo
    }

    /// The last finished interactive rebase while it can still be undone, also after the app was restarted. A record that no longer applies is removed.
    public func lastRebaseUndo() async -> RebaseUndo? {
        guard let session = try? await rebaseSession(), !session.exists, let undo = session.readUndo() else { return nil }
        guard await canUndoRebase(undo) else {
            session.remove()
            return nil
        }
        return undo
    }

    /// True while HEAD, its branch and `ORIG_HEAD` are still where the rebase left them and no other operation is in progress.
    public func canUndoRebase(_ undo: RebaseUndo) async -> Bool {
        guard let after = undo.after, await operationInProgress() == nil else { return false }
        let branch = await currentBranchRef()
        guard branch == undo.branch else { return false }
        let head = await resolveCommit("HEAD")
        let original = await resolveCommit("ORIG_HEAD")
        return head == after && original == undo.before
    }

    /// Puts the branch back on `ORIG_HEAD`, the commit before the rebase, keeping uncommitted changes (`git reset --keep`), and moves stacked branches back that are still where the rebase put them.
    public func undoRebase(_ undo: RebaseUndo) async throws {
        guard await canUndoRebase(undo) else { throw GitError(arguments: ["reset", "--keep", "ORIG_HEAD"], exitCode: 1, stderr: "HEAD has moved since the rebase; there is nothing to undo.") }
        _ = try await runner.runWrite(["reset", "--keep", undo.before])
        if let session = try? await rebaseSession(), !session.exists { session.remove() }
        let moves = undo.stacked.compactMap { move in move.after.map { "update \(move.ref) \(move.before) \($0)\n" } }
        guard !moves.isEmpty else { return }
        _ = try await runner.runWrite(["update-ref", "--stdin"], stdin: Data(("start\n" + moves.joined() + "commit\n").utf8))
    }

    /// The session folder of this worktree and git's own rebase folder next to it.
    func rebaseSession() async throws -> RebaseSession {
        let result = try await runner.run(["rev-parse", "--path-format=absolute", "--git-path", "gitbonsai-rebase", "--git-path", "rebase-merge"])
        let paths = result.stdoutString.split(separator: "\n").map(String.init)
        guard paths.count == 2 else { throw GitError(arguments: result.arguments, exitCode: 0, stderr: "unexpected output: \(result.stdoutString)") }
        return RebaseSession(directory: URL(fileURLWithPath: paths[0], isDirectory: true), rebaseDirectory: URL(fileURLWithPath: paths[1], isDirectory: true))
    }

    /// The environment and options for continuing or skipping a rebase: the app's message script while its session lasts, otherwise none that could open an editor.
    func rebaseContinuation() async -> (options: [String], environment: [String: String]) {
        guard let session = try? await rebaseSession(), session.exists else { return ([], ["GIT_EDITOR": "true"]) }
        return (Self.messageConfig, session.environment)
    }
}
