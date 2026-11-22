import Foundation

/// A rebase, cherry-pick, revert or merge that git has stopped in the middle of, waiting for the user.
public struct OperationProgress: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case rebase
        case cherryPick
        case revert
        case merge

        /// The git subcommand that runs and continues the operation.
        public var command: String {
            switch self {
            case .rebase: "rebase"
            case .cherryPick: "cherry-pick"
            case .revert: "revert"
            case .merge: "merge"
            }
        }

        /// A merge has no single commit to leave out, so git offers no `--skip` for it.
        public var canSkip: Bool { self != .merge }
    }

    public let kind: Kind
    /// The step git stopped at and the number of steps, counted from 1; nil where git does not record them (a single cherry-pick or revert).
    public let step: Int?
    public let total: Int?
    /// The branch being rebased, without `refs/heads/`; nil for a detached rebase and for cherry-pick and revert.
    public let branch: String?
    /// The commit a rebase replays onto.
    public let onto: String?
    /// The commit a cherry-pick or revert stopped at, or the commit a merge brings in.
    public let commit: String?
    /// Why an interactive rebase waits; nil for the other operations.
    public let stop: RebaseStop?

    public init(kind: Kind, step: Int?, total: Int?, branch: String?, onto: String?, commit: String?, stop: RebaseStop? = nil) {
        self.kind = kind
        self.step = step
        self.total = total
        self.branch = branch
        self.onto = onto
        self.commit = commit
        self.stop = stop
    }
}

/// The todo line a rebase stopped at, read from the last line of git's `done` file.
public enum RebaseStop: Sendable, Equatable {
    /// An `edit` step: the commit is applied and waits to be amended.
    case edit(commit: String, subject: String)
    /// A step whose commit did not apply cleanly.
    case conflict(commit: String, subject: String)
    /// An `exec` command that failed.
    case exec(String)
    /// A `break` or another command that only waits.
    case other(String)

    /// `amend` is git's marker of an edit stop: it holds the commit that `--continue` may amend.
    static func read(done: String?, amendMarkerExists: Bool) -> RebaseStop? {
        guard let line = done.map(RebaseTodoLine.parseList)?.last else { return nil }
        switch line {
        case let .commit(action, sha, subject):
            return action == .edit && amendMarkerExists ? .edit(commit: sha, subject: subject) : .conflict(commit: sha, subject: subject)
        case let .exec(command):
            return .exec(command)
        case let .updateRef(ref):
            return .other("update-ref \(ref)")
        case let .other(command, _):
            return .other(command)
        }
    }
}

extension Repository {
    /// Replays the commits of `branch` after `oldBase` onto `newBase`: `git rebase --onto <newBase> <oldBase> <branch>`.
    /// A conflict stops git mid-rebase and is thrown; the rebase stays in progress.
    /// Commits that become empty on the new base, because their changes are already there, are dropped and counted.
    @discardableResult
    public func rebase(onto newBase: String, from oldBase: String, branch: String) async throws -> OperationReport {
        let result = try await runner.runWrite(["rebase", "--empty=drop", "--onto", newBase, oldBase, branch])
        return OperationReport(output: result.stderr + result.stdoutString)
    }

    /// The number of commits in `base..tip`, which a rebase from `base` moves.
    public func commitCount(from base: String, to tip: String) async throws -> Int {
        let result = try await runner.run(["rev-list", "--count", "\(base)..\(tip)"])
        return Int(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The full SHA of the commit `revision` names, or nil when it names none.
    public func resolveCommit(_ revision: String) async -> String? {
        guard !revision.isEmpty, !revision.hasPrefix("-"), let result = try? await runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(revision)^{commit}"]) else { return nil }
        let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Commits the resolved state and goes on with the next step. The commit message is taken as git prepared it, or, in an interactive rebase the app started, as the app prepared it.
    /// A step whose resolved state matches HEAD has nothing left to commit; it is skipped instead, so continuing never stops at git's "nothing to commit".
    @discardableResult
    public func continueOperation(_ kind: OperationProgress.Kind) async throws -> OperationReport {
        if kind.canSkip, await stoppedStepIsEmpty(kind) {
            var report = try await proceed(kind, "--skip")
            report.skippedEmptyStep = true
            return report
        }
        return try await proceed(kind, "--continue")
    }

    /// Leaves out the commit git stopped at and goes on with the next step.
    @discardableResult
    public func skipOperation(_ kind: OperationProgress.Kind) async throws -> OperationReport {
        try await proceed(kind, "--skip")
    }

    private func proceed(_ kind: OperationProgress.Kind, _ option: String) async throws -> OperationReport {
        let (options, environment) = kind == .rebase ? await rebaseContinuation() : ([], ["GIT_EDITOR": "true"])
        let result = try await runner.runWrite(options + [kind.command, option], environment: environment)
        return OperationReport(output: result.stderr + result.stdoutString)
    }

    /// True at a conflict stop whose conflicts are resolved to exactly what HEAD has. An `edit` stop or a failed `exec` is never empty: there, continuing is what the user asked for.
    func stoppedStepIsEmpty(_ kind: OperationProgress.Kind) async -> Bool {
        guard let progress = await operationInProgress(), progress.kind == kind else { return false }
        if kind == .rebase {
            guard case .conflict? = progress.stop else { return false }
        }
        guard let unmerged = try? await runner.run(["ls-files", "--unmerged"]), unmerged.stdout.isEmpty else { return false }
        return (try? await runner.run(["diff", "--cached", "--quiet", "HEAD"])) != nil
    }

    /// Ends the operation and puts the branch, the index and the working tree back where they were before it started.
    public func abortOperation(_ kind: OperationProgress.Kind) async throws {
        _ = try await runner.runWrite([kind.command, "--abort"])
        if kind == .rebase, let session = try? await rebaseSession() { session.remove() }
    }

    /// The operation git is in the middle of in this worktree, or nil. Git keeps that state in the worktree's own git directory, which `--git-path` locates.
    public func operationInProgress() async -> OperationProgress? {
        let names = ["rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "MERGE_HEAD"]
        guard let result = try? await runner.run(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] }) else { return nil }
        let paths = result.stdoutString.split(separator: "\n").map(String.init)
        guard paths.count == names.count else { return nil }
        let location = Dictionary(uniqueKeysWithValues: zip(names, paths))
        return Self.readProgress(at: location)
    }

    static func readProgress(at location: [String: String]) -> OperationProgress? {
        func read(_ directory: String?, _ file: String) -> String? {
            guard let directory, let text = try? String(contentsOfFile: directory + "/" + file, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func exists(_ name: String) -> Bool { location[name].map { FileManager.default.fileExists(atPath: $0) } ?? false }
        // The merge backend counts in msgnum/end, the apply backend in next/last.
        for (name, stepFile, totalFile) in [("rebase-merge", "msgnum", "end"), ("rebase-apply", "next", "last")] where exists(name) {
            let directory = location[name]
            // rebase-apply also serves `git am`, which marks its runs with `applying`.
            if name == "rebase-apply", let directory, FileManager.default.fileExists(atPath: directory + "/applying") { continue }
            let head = read(directory, "head-name")
            let branch = head.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
            let stop = name == "rebase-merge" ? RebaseStop.read(done: read(directory, "done"), amendMarkerExists: directory.map { FileManager.default.fileExists(atPath: $0 + "/amend") } ?? false) : nil
            return OperationProgress(kind: .rebase, step: read(directory, stepFile).flatMap(Int.init), total: read(directory, totalFile).flatMap(Int.init), branch: branch, onto: read(directory, "onto"), commit: nil, stop: stop)
        }
        for (name, kind) in [("CHERRY_PICK_HEAD", OperationProgress.Kind.cherryPick), ("REVERT_HEAD", .revert), ("MERGE_HEAD", .merge)] where exists(name) {
            // MERGE_HEAD lists one commit per line, several for an octopus merge; the first names it.
            let commit = location[name].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
            return OperationProgress(kind: kind, step: nil, total: nil, branch: nil, onto: nil, commit: commit)
        }
        return nil
    }
}
