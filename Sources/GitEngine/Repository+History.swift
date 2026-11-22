import Foundation
import Synchronization

extension Repository {
    /// Applies `commit` on top of HEAD as a new commit. A merge commit is taken relative to its first parent.
    /// A conflict leaves git's cherry-pick in progress and is thrown.
    /// A commit whose changes are already there is dropped where git can (`--empty=drop`, git 2.45 and later) instead of stopping.
    public func cherryPick(_ commit: Commit) async throws {
        let empty = await gitVersion().map { $0 >= Self.cherryPickEmptyDrop } == true ? ["--empty=drop"] : []
        _ = try await runner.runWrite(["cherry-pick"] + empty + Self.mainlineArguments(for: commit) + [commit.id])
    }

    /// The first git whose cherry-pick knows `--empty=drop`.
    static let cherryPickEmptyDrop = GitVersion(major: 2, minor: 45, patch: 0)

    /// The version of this repository's git binary, read once per binary.
    func gitVersion() async -> GitVersion? {
        let path = runner.gitPath
        if let known = Self.versions.withLock({ $0[path] }) { return known }
        guard let version = try? await GitRunner.version(ofGitAt: path) else { return nil }
        Self.versions.withLock { $0[path] = version }
        return version
    }

    private static let versions = Mutex<[String: GitVersion]>([:])

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
