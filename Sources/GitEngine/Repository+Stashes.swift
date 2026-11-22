import Foundation

extension Repository {
    /// All stashes, newest first. Stash commits are not reachable from any branch, so callers that
    /// want them in the graph pass their ids as extra revisions to `log`.
    public func stashes() async throws -> [Stash] {
        let result = try await runner.run(["stash", "list", "--format=%gd%x1f%H%x1f%gs%x1f%ct%x1e"])
        return Self.parseStashes(result.stdout)
    }

    static func parseStashes(_ data: Data) -> [Stash] {
        data.split(separator: 0x1E).compactMap { record in
            let fields = record.split(separator: 0x1F, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 4 else { return nil }
            let selector = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = TimeInterval(fields[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return Stash(selector: selector, commitID: fields[1], message: fields[2].trimmingCharacters(in: .newlines), date: Date(timeIntervalSince1970: seconds))
        }
    }

    /// Stashes the changes `scope` names and returns the new stash with the working tree it left, or nil when there was nothing to stash. Without a message git writes its `WIP on …` subject.
    @discardableResult
    public func stash(message: String?, scope: StashScope) async throws -> NewStash? {
        let before = try await stashes().first?.commitID
        var arguments = ["stash", "push"] + scope.arguments
        if let message, !message.isEmpty { arguments += ["-m", message] }
        _ = try await runner.runWrite(arguments)
        guard let newest = try await stashes().first, newest.commitID != before else { return nil }
        return NewStash(stash: newest, remaining: try await workingTreeState())
    }

    /// Every change and untracked file, as `git status --porcelain` lists them.
    private func workingTreeState() async throws -> String {
        try await runner.run(["status", "--porcelain", "--untracked-files=all"]).stdoutString
    }

    /// What the toolbar's one-click stash names in its message, git's own default in the app's words: the branch, nil on a detached HEAD, and the subject of HEAD, empty without a commit.
    /// The app words the message, since it follows the interface language.
    public func defaultStashMessageParts() async -> (branch: String?, subject: String) {
        let branch = (try? await runner.run(["symbolic-ref", "-q", "--short", "HEAD"]))?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = (try? await runner.run(["log", "-1", "--format=%s", "HEAD"]))?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (branch.flatMap { $0.isEmpty ? nil : $0 }, subject)
    }

    /// Takes back a stash just made: pops it with its index, but only while it is still the newest stash, HEAD is still the commit it was made on and the working tree is as the stash left it.
    /// Anything else could mix the stash into newer work, so it throws `StashUndoError` and leaves everything as it is.
    public func undoStash(_ created: NewStash) async throws {
        let stash = created.stash
        guard try await stashes().first?.commitID == stash.commitID else { throw StashUndoError.notNewest }
        let base = try await runner.run(["rev-parse", "--verify", "\(stash.commitID)^1"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try await runner.run(["rev-parse", "--verify", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base == head else { throw StashUndoError.headMoved }
        guard try await workingTreeState() == created.remaining else { throw StashUndoError.workingTreeChanged }
        _ = try await runner.runWrite(["stash", "pop", "--index", "stash@{0}"])
    }

    /// Runs `body` with the working tree's changes, untracked files included, set aside in a stash, and puts them back afterwards. Returns whether putting them back conflicted; the stash then stays.
    /// When `body` fails without leaving an operation in progress, the changes are put back before the error is thrown. When it stopped on conflicts, they stay in the stash, named by `message`, for after the operation.
    public func withLocalChangesStashed(message: String, _ body: () async throws -> Void) async throws -> Bool {
        guard let created = try await stash(message: message, scope: .includingUntracked) else {
            try await body()
            return false
        }
        do {
            try await body()
        } catch {
            if await operationInProgress() == nil { _ = try? await popBack(created.stash) }
            throw error
        }
        return try await popBack(created.stash)
    }

    /// Pops a stash, with its index unless `index` is false; true when that conflicted, which git answers by keeping the stash.
    private func popBack(_ stash: Stash, index: Bool = true) async throws -> Bool {
        do {
            _ = try await runner.runWrite(["stash", "pop"] + (index ? ["--index"] : []) + [try await currentSelector(of: stash)])
            return false
        } catch let error as GitError {
            // `--index` gives up when the staged part no longer applies; the plain pop still brings the changes back, unstaged.
            if index, error.stderr.contains("Conflicts in index") { return try await popBack(stash, index: false) }
            // A conflicting pop names the conflicts on stdout only ("Index was not unstashed." on stderr), so the working tree tells.
            let unmerged = try? await runner.runRefreshingIndex(["diff", "--name-only", "-z", "--diff-filter=U"])
            guard error.stoppedOnConflict || !(unmerged?.stdout.isEmpty ?? true) else { throw error }
            return true
        }
    }

    /// Applies a stash and keeps it. On a conflict git leaves the conflicted files in the working tree and the error says so.
    public func applyStash(_ stash: Stash) async throws {
        _ = try await runner.runWrite(["stash", "apply", try await currentSelector(of: stash)])
    }

    /// Applies a stash and drops it. On a conflict git keeps the stash and leaves the conflicted files in the working tree.
    public func popStash(_ stash: Stash) async throws {
        _ = try await runner.runWrite(["stash", "pop", try await currentSelector(of: stash)])
    }

    public func dropStash(_ stash: Stash) async throws {
        _ = try await runner.runWrite(["stash", "drop", try await currentSelector(of: stash)])
    }

    /// Creates `name` at the commit the stash was made on, checks it out, applies the stash there and drops it.
    public func createBranch(_ name: String, from stash: Stash) async throws {
        _ = try await runner.runWrite(["stash", "branch", name, try await currentSelector(of: stash)])
    }

    /// The selector that names this stash now. Every worktree of a repository shares one stash list, and a stash pushed or dropped elsewhere shifts the numbers;
    /// the commit id stays, so the list is read again and the stash found by it.
    private func currentSelector(of stash: Stash) async throws -> String {
        let current = try await stashes()
        guard let match = current.first(where: { $0.commitID == stash.commitID }) else {
            throw GitError(arguments: ["stash", "list"], exitCode: 1, stderr: "\(stash.selector) (\(stash.commitID.prefix(7))) is no longer in the stash list.")
        }
        return match.selector
    }
}

/// A stash just made, with what it left in the working tree: nothing for a full stash, the unstaged rest for `--staged`.
public struct NewStash: Sendable, Equatable {
    public let stash: Stash
    public let remaining: String
}

/// Which changes a new stash takes.
public enum StashScope: Sendable, Hashable {
    /// Tracked and staged changes and untracked files.
    case includingUntracked
    /// Tracked and staged changes only.
    case tracked
    /// Only what is staged; the rest stays in the working tree (`--staged`, git 2.35 and later).
    case staged

    var arguments: [String] {
        switch self {
        case .includingUntracked: ["--include-untracked"]
        case .tracked: []
        case .staged: ["--staged"]
        }
    }

    /// The command as the user would type it, for the status line.
    public var commandLine: String { (["git", "stash", "push"] + arguments).joined(separator: " ") }
}

/// Why a stash just made could not be taken back.
public enum StashUndoError: Error, Sendable, Equatable {
    case notNewest
    case headMoved
    case workingTreeChanged
}
