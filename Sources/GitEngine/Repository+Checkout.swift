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
    /// If the switch fails the stash is popped again right away and git's error is thrown. If the pop conflicts, `CarriedChangesConflict` is thrown and the stash stays.
    /// `stashMessage` names that stash; the app passes it in the interface's language.
    public func checkout(_ target: CheckoutTarget, stashMessage: String) async throws {
        guard try await stashLocalChanges(message: stashMessage) else {
            try await switchTo(target)
            return
        }
        do {
            try await switchTo(target)
        } catch {
            _ = try? await runner.runWrite(["stash", "pop", "--index"])
            throw error
        }
        do {
            try await popCarriedChanges()
        } catch is GitError {
            throw CarriedChangesConflict(stashMessage: stashMessage, conflictedPaths: await conflictedPaths())
        }
    }

    private func switchTo(_ target: CheckoutTarget) async throws {
        switch target {
        case .localBranch(let name):
            _ = try await runner.runWrite(["switch", name])
        case .remoteBranch(let remote, let branch):
            let localExists = await revisionExists("refs/heads/\(branch)")
            _ = try await runner.runWrite(localExists ? ["switch", branch] : ["switch", "-c", branch, "--track", "\(remote)/\(branch)"])
        case .fastForward(let branch, let upstream):
            _ = try await runner.runWrite(["switch", branch])
            _ = try await runner.runWrite(["merge", "--ff-only", upstream])
        case .reset(let branch, let upstream):
            _ = try await runner.runWrite(["switch", "-C", branch, upstream])
        case .commit(let sha):
            _ = try await runner.runWrite(["switch", "--detach", sha])
        }
    }

    /// Stashes tracked and untracked changes under `message`; false when there was nothing to stash.
    /// git exits successfully without a stash for changes it cannot stash (a dirty submodule), so the stash ref is compared before and after.
    private func stashLocalChanges(message: String) async throws -> Bool {
        let status = try await runner.run(["status", "--porcelain", "-z", "--untracked-files=normal", "--ignore-submodules=all"])
        guard !status.stdout.isEmpty else { return false }
        let before = try? await runner.run(["rev-parse", "--verify", "--quiet", "refs/stash"]).stdoutString
        _ = try await runner.runWrite(["stash", "push", "--include-untracked", "-m", message])
        let after = try? await runner.run(["rev-parse", "--verify", "--quiet", "refs/stash"]).stdoutString
        return after != nil && after != before
    }

    /// Pops the stash with its staged part where git can restore it, otherwise as plain working tree changes.
    private func popCarriedChanges() async throws {
        do {
            _ = try await runner.runWrite(["stash", "pop", "--index"])
        } catch let error as GitError where error.stderr.contains("Try without --index") {
            _ = try await runner.runWrite(["stash", "pop"])
        }
    }
}
