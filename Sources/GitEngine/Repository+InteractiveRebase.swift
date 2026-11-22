import Foundation

/// Why the app refuses to plan or start an interactive rebase.
public enum RebasePlanError: Error, Sendable, Equatable {
    /// The base is not an ancestor of HEAD.
    case baseNotInHistory
    /// A merge lies between the base and HEAD; replaying it would flatten it.
    case mergeInRange
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

/// The context menu's one-step forms of an interactive rebase.
public enum RebaseSingleStep: Sendable, Equatable {
    case reword(String)
    case drop
    /// Swaps the commit with the one above it, its child.
    case moveUp
    /// Swaps the commit with the one below it, its parent.
    case moveDown
}

extension Repository {
    /// The commits `base..HEAD`, oldest first, which an interactive rebase from `base` replays. Refuses a base outside HEAD's history and a range with merges.
    public func rebaseCommits(after base: String) async throws -> [RebaseCommit] {
        guard (try? await runner.run(["merge-base", "--is-ancestor", base, "HEAD"])) != nil else { throw RebasePlanError.baseNotInHistory }
        let result = try await runner.run(["log", "--reverse", "--format=%H%x1f%P%x1f%s%x1f%B%x1e", "\(base)..HEAD"])
        let commits = Self.parseRebaseCommits(result.stdout)
        if commits.contains(where: { $0.parents.count > 1 }) { throw RebasePlanError.mergeInRange }
        if commits.isEmpty { throw RebasePlanError.nothingToRebase }
        return commits
    }

    static func parseRebaseCommits(_ data: Data) -> [RebaseCommit] {
        String(decoding: data, as: UTF8.self).split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0.isNewline }.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty else { return nil }
            let message = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            return RebaseCommit(id: String(fields[0]), parents: fields[1].split(separator: " ").map(String.init), subject: String(fields[2]), message: message)
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

    /// Runs `git rebase --interactive` with the todo list and messages of `plan`. git stopping at an `edit`, a conflict or a failed `exec` is no error: the rebase stays in progress and the banner takes over.
    public func startInteractiveRebase(_ plan: RebasePlan) async throws -> InteractiveRebaseOutcome {
        if let problem = plan.problem { throw RebasePlanError.invalidPlan(problem) }
        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (try? await runner.run(["symbolic-ref", "-q", "HEAD"]))?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stacked = plan.updateRefs ? plan.branches.flatMap { sha, refs in refs.map { RebaseUndo.Move(ref: $0, before: sha, after: nil) } }.sorted { $0.ref < $1.ref } : []
        let session = try await rebaseSession()
        try session.create(for: plan, state: RebaseUndo(branch: branch?.isEmpty == false ? branch : nil, before: head, after: nil, stacked: stacked))
        let arguments = Self.messageConfig + [
            "rebase", "--interactive", "--no-autosquash", "--empty=drop",
            plan.updateRefs ? "--update-refs" : "--no-update-refs",
            plan.autostash ? "--autostash" : "--no-autostash",
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
        let branch = (try? await runner.run(["symbolic-ref", "-q", "HEAD"]))?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (branch?.isEmpty == false ? branch : nil) == undo.branch else { return false }
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
