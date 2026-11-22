import Foundation

extension Repository {
    /// Adds a worktree at `path` with `commit` checked out: on a new branch when `newBranch` is given, detached otherwise.
    public func addWorktree(at path: String, commit: String, newBranch: String?) async throws {
        let branchArguments = newBranch.map { ["-b", $0] } ?? ["--detach"]
        _ = try await runner.runWrite(["worktree", "add"] + branchArguments + [path, commit])
    }
}
