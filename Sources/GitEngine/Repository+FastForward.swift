import Foundation

public enum FastForwardError: Error, Sendable, Equatable {
    /// The branch has commits the target does not have; nothing was changed.
    case notFastForward(branch: String)
    /// The branch already contains the target.
    case upToDate(branch: String)
    /// HEAD is detached; only a checked-out branch is fast-forwarded.
    case detachedHead
    /// The branch is the one checked out here; it moves with `fastForwardCurrentBranch(to:)`.
    case isCurrentBranch(branch: String)
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

    /// Moves another local branch forward to the commit HEAD points at, without a checkout.
    /// A branch checked out nowhere is updated with `git fetch . HEAD:refs/heads/<branch>`, which refuses anything but a fast-forward; one checked out in another worktree is merged there with `--ff-only`, so its files move with it.
    public func fastForwardBranchToHead(_ branch: String) async throws -> (result: FastForwardResult, place: BranchPullPlace) {
        let place = try await pullPlace(of: branch)
        if case .current = place { throw FastForwardError.isCurrentBranch(branch: branch) }
        let head = try await runner.run(["rev-parse", "--verify", "HEAD^{commit}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = try await branchHead(branch)
        guard before != head, (try? await runner.run(["merge-base", "--is-ancestor", head, before])) == nil else { throw FastForwardError.upToDate(branch: branch) }
        guard (try? await runner.run(["merge-base", "--is-ancestor", before, head])) != nil else { throw FastForwardError.notFastForward(branch: branch) }
        let commandLine: String
        switch place {
        case .current, .ref:
            let arguments = ["fetch", "--no-write-fetch-head", ".", "HEAD:refs/heads/\(branch)"]
            _ = try await runner.runWrite(arguments)
            commandLine = "git " + arguments.joined(separator: " ")
        case .worktree(let path):
            let arguments = ["merge", "--ff-only", head]
            _ = try await Repository(path: path, gitPath: runner.gitPath).runner.runWrite(arguments)
            commandLine = "git -C \(path) " + arguments.joined(separator: " ")
        }
        let after = try await branchHead(branch)
        let count = try await runner.run(["rev-list", "--count", "\(before)..\(after)"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return (FastForwardResult(branch: branch, commits: Int(count) ?? 0, commandLine: commandLine), place)
    }
}
