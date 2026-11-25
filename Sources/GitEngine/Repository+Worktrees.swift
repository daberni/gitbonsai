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
    /// `overridingLock` passes `-f` twice, which git needs to remove a locked worktree.
    public func removeWorktree(at path: String, force: Bool, overridingLock: Bool = false) async throws {
        let flags = overridingLock ? ["-f", "-f"] : force ? ["--force"] : []
        _ = try await runner.runWrite(["worktree", "remove"] + flags + [path])
    }

    /// Protects the worktree at `path` from being pruned, moved or removed.
    public func lockWorktree(at path: String, reason: String?) async throws {
        _ = try await runner.runWrite(["worktree", "lock"] + (reason.map { ["--reason", $0] } ?? []) + [path])
    }

    public func unlockWorktree(at path: String) async throws {
        _ = try await runner.runWrite(["worktree", "unlock", path])
    }
}

extension GitError {
    /// `git worktree remove` refused a worktree with modified or untracked files; `--force` removes it anyway.
    public var isDirtyWorktree: Bool { stderr.contains("contains modified or untracked files") }
}

extension Repository {
    /// The worktree to show instead of `path` once its folder is gone, for instance after `git worktree remove` in a terminal: the main worktree, or else the first linked one whose folder still exists. Nil while `path` exists or when no worktree is left.
    /// git still runs in `commonDirectory`, which every worktree of the repository shares.
    public static func replacementWorktree(for path: String, commonDirectory: String, gitPath: String = GitRunner.defaultGitPath()) async -> String? {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path) else { return nil }
        guard let worktrees = try? await Repository(path: commonDirectory, gitPath: gitPath).worktrees() else { return nil }
        return worktrees.first { !$0.isBare && !$0.isPrunable && fileManager.fileExists(atPath: $0.path) }?.path
    }
}
