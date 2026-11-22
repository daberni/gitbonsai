import Foundation

/// Where pulling a local branch has to happen.
public enum BranchPullPlace: Sendable, Equatable {
    /// The branch is checked out in this working tree: the normal pull with its variants.
    case current
    /// The branch is checked out in another worktree, which git refuses to update from here; the pull runs inside it.
    case worktree(path: String)
    /// Checked out nowhere: only the ref moves.
    case ref
}

/// What pulling a branch that may not be checked out did.
public enum BranchPullOutcome: Sendable, Equatable {
    case fastForwarded(commits: Int)
    /// Nothing to take; `ahead` local commits are not on the upstream yet.
    case upToDate(ahead: Int)
    /// Both sides have new commits. Nothing was changed.
    case diverged(ahead: Int, behind: Int)
}

public struct BranchPullResult: Sendable, Equatable {
    public let place: BranchPullPlace
    public let outcome: BranchPullOutcome
    /// The command as the user would type it, for the status line.
    public let commandLine: String
    /// The pull in another worktree carried its local changes, and applying them again conflicted there; the stash stays.
    public var localChangesConflicted = false
}

public enum BranchPullError: Error, Sendable, Equatable {
    case noUpstream(branch: String)
    /// The checked-out branch takes the normal pull, which knows the user's chosen variant.
    case isCurrentBranch(branch: String)
}

extension Repository {
    /// Where `branch` would be pulled, from the worktrees that have it checked out.
    public func pullPlace(of branch: String) async throws -> BranchPullPlace {
        let fullName = "refs/heads/\(branch)"
        let worktrees = try await worktrees()
        guard let owner = worktrees.first(where: { $0.branch == fullName }) else { return .ref }
        let here = try await Repository.location(containing: path, gitPath: runner.gitPath).root
        return Self.samePath(owner.path, here) ? .current : .worktree(path: owner.path)
    }

    /// Fast-forwards a local branch that is not checked out in this working tree to its upstream, fetching first.
    /// A branch checked out nowhere is updated with `git fetch <remote> refs/heads/<upstream>:refs/heads/<branch>`: one command that fetches, refuses anything but a fast-forward and moves the ref atomically.
    /// A branch checked out in another worktree is pulled there with `--ff-only`, through that working tree's own write queue.
    /// Diverged branches are left alone; the result carries the counts so the caller can offer a way out.
    public func fastForwardBranch(_ branch: String) async throws -> BranchPullResult {
        guard let upstream = await upstream(of: branch) else { throw BranchPullError.noUpstream(branch: branch) }
        let place = try await pullPlace(of: branch)
        switch place {
        case .current:
            throw BranchPullError.isCurrentBranch(branch: branch)
        case .ref:
            let arguments = ["fetch", "--no-write-fetch-head", upstream.remote, "refs/heads/\(upstream.branch):refs/heads/\(branch)"]
            return try await pull(branch, place: place, commandLine: "git " + arguments.joined(separator: " ")) {
                _ = try await self.runner.runWrite(arguments)
            }
        case .worktree(let path):
            let arguments = PullVariant(mode: .fastForwardOnly).arguments
            let worktree = Repository(path: path, gitPath: runner.gitPath)
            var conflicted = false
            var result = try await pull(branch, place: place, commandLine: "git -C \(path) " + arguments.joined(separator: " ")) {
                conflicted = PullResult.parse(try await worktree.runner.runWrite(arguments, environment: ["GIT_EDITOR": "true"])).localChangesConflicted
            }
            result.localChangesConflicted = conflicted
            return result
        }
    }

    /// Moves a local branch that is checked out nowhere onto its upstream, dropping the commits only it has.
    /// The update is guarded by the branch's current position, so a branch that moved meanwhile is left alone.
    public func resetBranchToUpstream(_ branch: String, expecting oldSHA: String) async throws {
        let target = try await runner.run(["rev-parse", "--verify", "\(branch)@{upstream}^{commit}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.runWrite(["update-ref", "-m", "reset: moving to \(branch)@{upstream}", "refs/heads/\(branch)", target, oldSHA])
    }

    /// The commit a local branch points at.
    public func branchHead(_ branch: String) async throws -> String {
        try await runner.run(["rev-parse", "--verify", "refs/heads/\(branch)^{commit}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs one fast-forward attempt and tells moved, up to date and diverged apart from the branch's positions before and after.
    private func pull(_ branch: String, place: BranchPullPlace, commandLine: String, _ operation: () async throws -> Void) async throws -> BranchPullResult {
        let before = try await branchHead(branch)
        do {
            try await operation()
        } catch let error as GitError where error.isRejectedNonFastForward || error.isDivergedPull {
            // The attempt fetched, so the counts come from the updated remote-tracking branch.
            let counts = await upstream(of: branch)
            let ahead = counts?.ahead ?? 0
            let behind = counts?.behind ?? 0
            let outcome: BranchPullOutcome = behind == 0 ? .upToDate(ahead: ahead) : .diverged(ahead: ahead, behind: behind)
            return BranchPullResult(place: place, outcome: outcome, commandLine: commandLine)
        }
        let after = try await branchHead(branch)
        guard after != before else {
            let ahead = await upstream(of: branch)?.ahead ?? 0
            return BranchPullResult(place: place, outcome: .upToDate(ahead: ahead), commandLine: commandLine)
        }
        let count = try await runner.run(["rev-list", "--count", "\(before)..\(after)"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return BranchPullResult(place: place, outcome: .fastForwarded(commits: Int(count) ?? 0), commandLine: commandLine)
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
