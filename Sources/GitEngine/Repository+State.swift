import Foundation

extension Repository {
    /// Whether `revision` names an object. `HEAD` names none in a repository without commits.
    func revisionExists(_ revision: String) async -> Bool {
        (try? await runner.run(["rev-parse", "--verify", "--quiet", revision])) != nil
    }

    /// The full name of the checked-out branch (`refs/heads/…`), nil on a detached HEAD.
    func currentBranchRef() async -> String? {
        let name = (try? await runner.run(["symbolic-ref", "-q", "HEAD"]))?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// Paths with unresolved conflicts in the working tree; empty when there are none or git cannot tell.
    func conflictedPaths() async -> [String] {
        let result = try? await runner.runRefreshingIndex(["diff", "--name-only", "-z", "--diff-filter=U"])
        return result?.stdoutString.split(separator: "\0").map(String.init) ?? []
    }

    /// A merge or pull that stopped on a conflict reports it on stdout, which `error` does not carry. While the merge is in progress this returns `error` with the conflicted paths in git's wording, so that `stoppedOnConflict` holds; otherwise nil.
    func mergeConflictError(from error: GitError) async -> GitError? {
        guard await revisionExists("MERGE_HEAD") else { return nil }
        let lines = await conflictedPaths().map { "CONFLICT: Merge conflict in \($0)" } + [error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
        return GitError(arguments: error.arguments, exitCode: error.exitCode, stderr: lines.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
