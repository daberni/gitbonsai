import Foundation

extension Repository {
    /// Applies `commit` on top of HEAD as a new commit. A merge commit is taken relative to its first parent.
    /// A conflict leaves git's cherry-pick in progress and is thrown.
    public func cherryPick(_ commit: Commit) async throws {
        _ = try await runner.runWrite(["cherry-pick"] + Self.mainlineArguments(for: commit) + [commit.id])
    }

    /// Records a new commit that undoes `commit`. A merge commit is undone relative to its first parent.
    /// A conflict leaves git's revert in progress and is thrown.
    public func revert(_ commit: Commit) async throws {
        _ = try await runner.runWrite(["revert", "--no-edit"] + Self.mainlineArguments(for: commit) + [commit.id])
    }

    /// The commit as a mail-formatted patch that `git am` applies. Merge commits have no patch of their own and yield empty data.
    public func patch(of commit: String) async throws -> Data {
        try await runner.run(["format-patch", "-1", "--stdout", commit]).stdout
    }

    private static func mainlineArguments(for commit: Commit) -> [String] {
        commit.parents.count > 1 ? ["-m", "1"] : []
    }
}

extension GitError {
    /// Cherry-pick, revert or rebase stopped on a conflict and left the operation in progress for the user to resolve.
    public var stoppedOnConflict: Bool {
        stderr.contains("could not apply") || stderr.contains("could not revert") || stderr.contains("CONFLICT")
    }
}
