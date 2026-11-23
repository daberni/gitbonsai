import Foundation

/// What a branch is fast-forwarded to: a ref or commit of this repository, or a branch of a remote, which is fetched on the way for a branch checked out nowhere.
public enum FastForwardSource: Sendable, Equatable {
    /// A branch, tag or full SHA of this repository.
    case local(String)
    case remote(remote: String, branch: String)

    /// The name `git merge` and `git rev-parse` take.
    var revision: String {
        switch self {
        case .local(let name): name
        case .remote(let remote, let branch): "refs/remotes/\(remote)/\(branch)"
        }
    }
}

public enum FastForwardError: Error, Sendable, Equatable {
    /// The branch has commits the target does not have; nothing was changed.
    case notFastForward(branch: String)
    /// The branch already contains the target.
    case upToDate(branch: String)
}

public struct FastForwardResult: Sendable, Equatable {
    public let place: BranchPullPlace
    public let commits: Int
    /// The command as the user would type it, for the status line.
    public let commandLine: String
}

extension Repository {
    /// Moves local `branch` forward to `source` without a merge commit, wherever the branch is checked out.
    /// The checked-out branch runs `git merge --ff-only`; a branch checked out nowhere only moves its ref with `git fetch . <src>:refs/heads/<branch>` (a remote branch with `git fetch <remote>`), which refuses anything but a fast-forward;
    /// a branch checked out in another worktree is merged there with `--ff-only`. A branch the target does not contain is refused before anything runs.
    public func fastForward(_ branch: String, to source: FastForwardSource) async throws -> FastForwardResult {
        let before = try await branchHead(branch)
        let target = try await runner.run(["rev-parse", "--verify", "\(source.revision)^{commit}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard before != target, (try? await runner.run(["merge-base", "--is-ancestor", target, before])) == nil else { throw FastForwardError.upToDate(branch: branch) }
        guard (try? await runner.run(["merge-base", "--is-ancestor", before, target])) != nil else { throw FastForwardError.notFastForward(branch: branch) }
        let place = try await pullPlace(of: branch)
        let commandLine: String
        do {
            switch place {
            case .current:
                let arguments = ["merge", "--ff-only", source.revision]
                _ = try await runner.runWrite(arguments)
                commandLine = "git " + arguments.joined(separator: " ")
            case .ref:
                let arguments: [String] = switch source {
                case .local(let name): ["fetch", "--no-write-fetch-head", ".", "\(name):refs/heads/\(branch)"]
                case .remote(let remote, let remoteBranch): ["fetch", "--no-write-fetch-head", remote, "refs/heads/\(remoteBranch):refs/heads/\(branch)"]
                }
                _ = try await runner.runWrite(arguments)
                commandLine = "git " + arguments.joined(separator: " ")
            case .worktree(let path):
                let arguments = ["merge", "--ff-only", target]
                _ = try await Repository(path: path, gitPath: runner.gitPath).runner.runWrite(arguments)
                commandLine = "git -C \(path) " + arguments.joined(separator: " ")
            }
        } catch let error as GitError where error.isRejectedNonFastForward {
            // A remote branch fetched on the way may have been rewritten meanwhile.
            throw FastForwardError.notFastForward(branch: branch)
        }
        let after = try await branchHead(branch)
        let count = try await runner.run(["rev-list", "--count", "\(before)..\(after)"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return FastForwardResult(place: place, commits: Int(count) ?? 0, commandLine: commandLine)
    }
}
