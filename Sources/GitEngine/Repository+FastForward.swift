import Foundation

public enum FastForwardError: Error, Sendable, Equatable {
    /// The branch has commits the target does not have; nothing was changed.
    case notFastForward(branch: String)
    /// The branch already contains the target.
    case upToDate(branch: String)
    /// HEAD is detached; only a checked-out branch is fast-forwarded.
    case detachedHead
}

public struct FastForwardResult: Sendable, Equatable {
    public let branch: String
    public let commits: Int
    /// The command as the user would type it, for the status line.
    public let commandLine: String
}

extension Repository {
    /// Moves the checked-out branch forward to `revision` (a branch, tag, remote branch or full SHA) with `git merge --ff-only`.
    /// A target the branch already contains, or one it has diverged from, is refused before anything runs.
    public func fastForwardCurrentBranch(to revision: String) async throws -> FastForwardResult {
        guard let fullName = await currentBranchRef() else { throw FastForwardError.detachedHead }
        let branch = String(fullName.dropFirst("refs/heads/".count))
        let before = try await branchHead(branch)
        let target = try await runner.run(["rev-parse", "--verify", "\(revision)^{commit}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard before != target, (try? await runner.run(["merge-base", "--is-ancestor", target, before])) == nil else { throw FastForwardError.upToDate(branch: branch) }
        guard (try? await runner.run(["merge-base", "--is-ancestor", before, target])) != nil else { throw FastForwardError.notFastForward(branch: branch) }
        let arguments = ["merge", "--ff-only", revision]
        _ = try await runner.runWrite(arguments)
        let after = try await branchHead(branch)
        let count = try await runner.run(["rev-list", "--count", "\(before)..\(after)"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return FastForwardResult(branch: branch, commits: Int(count) ?? 0, commandLine: "git " + arguments.joined(separator: " "))
    }
}
