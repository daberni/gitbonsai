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

    /// Stashes tracked and staged changes, and with `includeUntracked` untracked files too. Without a message git writes its `WIP on …` subject.
    public func stash(message: String?, includeUntracked: Bool) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if let message, !message.isEmpty { arguments += ["-m", message] }
        _ = try await runner.runWrite(arguments)
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
