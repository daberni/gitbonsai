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
