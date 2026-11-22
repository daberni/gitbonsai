import Foundation

/// How far `git reset` takes the current branch back: only the branch, also the index, or also the working tree.
public enum ResetMode: String, Sendable, CaseIterable {
    case soft
    case mixed
    case hard
}

extension Repository {
    /// Creates branch `name` at `commit`, and switches to it with `checkout`. Fails when the branch exists.
    public func createBranch(_ name: String, at commit: String, checkout: Bool) async throws {
        _ = try await runner.runWrite(checkout ? ["switch", "-c", name, commit] : ["branch", name, commit])
    }

    /// Moves the current branch to `commit`. `hard` discards uncommitted changes to tracked files.
    public func resetCurrentBranch(to commit: String, mode: ResetMode) async throws {
        _ = try await runner.runWrite(["reset", "--\(mode.rawValue)", commit])
    }

    /// Replays the current branch's own commits onto `commit`. A conflict stops git mid-rebase and is thrown; the rebase stays in progress.
    public func rebaseCurrentBranch(onto commit: String) async throws {
        _ = try await runner.runWrite(["rebase", commit])
    }

    /// How many of the commits that a reset to or a rebase onto `commit` rewrites or drops are already in the current branch's upstream.
    /// Those are `commit..HEAD` reachable from `@{upstream}`; without an upstream nothing is published.
    public func publishedCommitCount(rewrittenBy commit: String) async -> Int {
        guard let base = try? await runner.run(["merge-base", "HEAD", "@{upstream}"]) else { return 0 }
        let mergeBase = base.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = try? await runner.run(["rev-list", "--count", mergeBase, "^\(commit)"]) else { return 0 }
        return Int(count.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

extension Repository {
    /// Deletes local branch `name`. Without `force` git refuses a branch whose commits are not merged into its upstream or HEAD; that refusal is thrown with `isUnmergedBranch`.
    /// git also refuses a branch checked out in any worktree, with or without `force`.
    public func deleteBranch(_ name: String, force: Bool) async throws {
        _ = try await runner.runWrite(["branch", force ? "-D" : "-d", name])
    }

    /// Renames local branch `name` to `newName`; its reflog, upstream and any worktree that has it checked out follow. Fails when `newName` exists.
    public func renameBranch(_ name: String, to newName: String) async throws {
        _ = try await runner.runWrite(["branch", "-m", name, newName])
    }

    /// Makes `upstream` (a remote branch such as `origin/main`) the branch that `branch` pulls from and compares with; nil removes the upstream.
    public func setUpstream(of branch: String, to upstream: String?) async throws {
        let arguments = upstream.map { ["branch", "--set-upstream-to=\($0)", branch] } ?? ["branch", "--unset-upstream", branch]
        _ = try await runner.runWrite(arguments)
    }

    /// Merges `ref` into the current branch, fast-forwarding when possible.
    /// git reports a conflict on stdout, which the thrown error does not carry; a stopped merge is therefore thrown with the conflicted paths so that `stoppedOnConflict` holds.
    public func merge(_ ref: String) async throws {
        do {
            _ = try await runner.runWrite(["merge", "--no-edit", ref])
        } catch let error as GitError {
            guard (try? await runner.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"])) != nil else { throw error }
            let conflicted = (try? await runner.runRefreshingIndex(["diff", "--name-only", "-z", "--diff-filter=U"]))?.stdoutString.split(separator: "\0").map(String.init) ?? []
            let lines = conflicted.map { "CONFLICT: Merge conflict in \($0)" } + [error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
            throw GitError(arguments: error.arguments, exitCode: error.exitCode, stderr: lines.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    /// Deletes `branch` on `remote` and the matching remote-tracking ref.
    public func deleteRemoteBranch(_ branch: String, on remote: String) async throws {
        _ = try await runner.runWrite(["push", remote, "--delete", branch])
    }
}

extension GitError {
    /// `git branch -d` refused a branch whose commits would be lost; `-D` deletes it anyway.
    public var isUnmergedBranch: Bool { stderr.contains("is not fully merged") }
}
