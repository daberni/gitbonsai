import Foundation

extension Repository {
    /// Adds a worktree at `path` with `commit` checked out: on a new branch when `newBranch` is given, detached otherwise.
    public func addWorktree(at path: String, commit: String, newBranch: String?) async throws {
        let branchArguments = newBranch.map { ["-b", $0] } ?? ["--detach"]
        _ = try await runner.runWrite(["worktree", "add"] + branchArguments + [path, commit])
    }
}

extension Repository {
    /// Adds a worktree at `path` with the existing local `branch` checked out. Fails when the branch is checked out in another worktree.
    public func addWorktree(at path: String, branch: String) async throws {
        _ = try await runner.runWrite(["worktree", "add", path, branch])
    }

    /// Removes the worktree at `path` and its folder. Without `force` git refuses a worktree with modified or untracked files (`isDirtyWorktree`); a locked worktree is refused either way.
    public func removeWorktree(at path: String, force: Bool) async throws {
        _ = try await runner.runWrite(["worktree", "remove"] + (force ? ["--force"] : []) + [path])
    }

    /// Protects the worktree at `path` from being pruned, moved or removed.
    public func lockWorktree(at path: String, reason: String?) async throws {
        _ = try await runner.runWrite(["worktree", "lock"] + (reason.map { ["--reason", $0] } ?? []) + [path])
    }

    public func unlockWorktree(at path: String) async throws {
        _ = try await runner.runWrite(["worktree", "unlock", path])
    }

    /// Forgets worktrees whose folders are gone. Locked ones are kept.
    public func pruneWorktrees() async throws {
        _ = try await runner.runWrite(["worktree", "prune"])
    }
}

extension GitError {
    /// `git worktree remove` refused a worktree with modified or untracked files; `--force` removes it anyway.
    public var isDirtyWorktree: Bool { stderr.contains("contains modified or untracked files") }
}
