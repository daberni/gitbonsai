import Foundation

/// What a checkout switches to.
public enum CheckoutTarget: Sendable, Hashable {
    case localBranch(String)
    case remoteBranch(remote: String, branch: String)
    /// Switch to local `branch` and fast-forward it to `to`; fails rather than merging when it cannot fast-forward.
    case fastForward(branch: String, to: String)
    /// Switch to local `branch` and reset it to `to`, dropping the commits only `branch` has.
    case reset(branch: String, to: String)
    /// Detached HEAD at a commit.
    case commit(String)

    /// How the target reads in a stash message and the command log: the branch name or the short SHA.
    public var label: String {
        switch self {
        case .localBranch(let name), .fastForward(let name, _), .reset(let name, _): name
        case .remoteBranch(let remote, let branch): "\(remote)/\(branch)"
        case .commit(let sha): String(sha.prefix(7))
        }
    }
}

/// The checkout itself succeeded, but the uncommitted changes carried along conflict on the target.
/// git keeps them in the stash named `stashMessage`; the conflicted files are in the working tree.
public struct CarriedChangesConflict: Error, Sendable {
    public let stashMessage: String
    /// git reports the conflicts on stdout, which a thrown `GitError` does not carry; the paths are read back instead.
    public let conflictedPaths: [String]
}

extension Repository {
    /// Switches the working tree to `target`, the one way every branch switch of the app takes.
    /// Uncommitted changes, untracked files included, come along: they are stashed, the switch runs, and the stash is popped on the target.
    /// If the switch fails the stash is popped again right away and git's error is thrown; when that pop fails too, the error names the stash that keeps the changes.
    /// If the pop on the target conflicts, `CarriedChangesConflict` is thrown and the stash stays.
    /// `stashMessage` names that stash; the app passes it in the interface's language.
    public func checkout(_ target: CheckoutTarget, stashMessage: String) async throws {
        guard let stash = try await stashLocalChanges(message: stashMessage) else {
            try await switchTo(target)
            return
        }
        do {
            try await switchTo(target)
        } catch {
            throw await putBack(stash, after: error)
        }
        let conflicted: Bool
        do {
            conflicted = try await popBack(stash)
        } catch is GitError {
            conflicted = true
        }
        if conflicted { throw CarriedChangesConflict(stashMessage: stashMessage, conflictedPaths: await conflictedPaths()) }
    }

    private func switchTo(_ target: CheckoutTarget) async throws {
        switch target {
        case .localBranch(let name):
            _ = try await runner.runWrite(["switch", name])
        case .remoteBranch(let remote, let branch):
            let localExists = await revisionExists("refs/heads/\(branch)")
            _ = try await runner.runWrite(localExists ? ["switch", branch] : ["switch", "-c", branch, "--track", "\(remote)/\(branch)"])
        case .fastForward(let branch, let upstream):
            // The branch moves first, as a ref only, and the working tree switches once: a refused fast-forward leaves everything where it was, with no switch back that could fail.
            // A SHA as the fetch source: a short name like `origin/topic` matches no ref on `.`, and git then reads the refspec as a deletion of the branch.
            let target = try await runner.run(["rev-parse", "--verify", "\(upstream)^{commit}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if await isCurrentBranch(branch) {
                _ = try await runner.runWrite(["merge", "--ff-only", target])
            } else {
                _ = try await runner.runWrite(["fetch", "--no-write-fetch-head", ".", "\(target):refs/heads/\(branch)"])
                _ = try await runner.runWrite(["switch", branch])
            }
        case .reset(let branch, let upstream):
            _ = try await runner.runWrite(["switch", "-C", branch, upstream])
        case .commit(let sha):
            _ = try await runner.runWrite(["switch", "--detach", sha])
        }
    }

    /// git refuses to fetch into the checked-out branch; that one fast-forwards in place.
    private func isCurrentBranch(_ branch: String) async -> Bool {
        let ref = try? await runner.run(["symbolic-ref", "-q", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref == "refs/heads/\(branch)"
    }

    /// Stashes tracked and untracked changes under `message`; nil when there was nothing to stash.
    /// The status ignores submodules: git cannot stash a dirty submodule and would exit successfully without a stash.
    private func stashLocalChanges(message: String) async throws -> Stash? {
        let status = try await runner.run(["status", "--porcelain", "-z", "--untracked-files=normal", "--ignore-submodules=all"])
        guard !status.stdout.isEmpty else { return nil }
        return try await stash(message: message, scope: .includingUntracked)?.stash
    }
}

