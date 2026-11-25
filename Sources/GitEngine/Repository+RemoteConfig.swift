import Foundation

/// Adding, renaming, re-pointing and removing remotes with `git remote`.
extension Repository {
    /// Whether git accepts `name` for a new remote: its branches must be valid under `refs/remotes/<name>/`, as `git remote add` checks it.
    public func isValidRemoteName(_ name: String) async -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return (try? await runner.run(["check-ref-format", "refs/remotes/\(name)/test"])) != nil
    }

    /// Adds remote `name` with `url`; nothing is fetched. Fails when the remote exists.
    public func addRemote(_ name: String, url: String) async throws {
        _ = try await runner.runWrite(["remote", "add", "--", name, url])
    }

    /// Renames remote `name`; its remote-tracking branches and the upstreams of local branches follow.
    public func renameRemote(_ name: String, to newName: String) async throws {
        _ = try await runner.runWrite(["remote", "rename", "--", name, newName])
    }

    /// Replaces the fetch and push URL of remote `name`.
    public func setRemoteURL(_ name: String, url: String) async throws {
        _ = try await runner.runWrite(["remote", "set-url", "--", name, url])
    }

    /// Removes remote `name` with its remote-tracking branches and its configuration; local branches that tracked it lose their upstream.
    public func removeRemote(_ name: String) async throws {
        _ = try await runner.runWrite(["remote", "remove", "--", name])
    }

    /// Removes remote `name` like `removeRemote` and returns what it removed, so that `restoreRemote` can bring it back.
    public func removeRemoteKeepingConfig(_ name: String) async throws -> RemovedRemote {
        let removed = RemovedRemote(name: name, entries: await configEntries(matching: "^remote\\.\(NSRegularExpression.escapedPattern(for: name))\\."), upstreams: await branchesTracking(name), refs: await trackingRefs(of: name))
        try await removeRemote(name)
        return removed
    }

    /// True while no remote of that name has been added since it was removed.
    public func canRestoreRemote(_ removed: RemovedRemote) async -> Bool {
        let names = (try? await remotes()) ?? []
        return !names.contains(removed.name)
    }

    /// Writes the remote's configuration, the upstreams of the branches that tracked it and its remote-tracking branches back, then fetches it to bring them up to date.
    /// A failed fetch, for example offline, leaves the remote as it was at removal; it is not reported.
    public func restoreRemote(_ removed: RemovedRemote) async throws {
        guard await canRestoreRemote(removed) else { throw GitError(arguments: ["remote"], exitCode: 1, stderr: "A remote named \(removed.name) exists again; there is nothing to undo.") }
        for entry in removed.entries + removed.upstreams {
            _ = try await runner.runWrite(["config", "--add", entry.key, entry.value])
        }
        let direct = removed.refs.filter { $0.symref == nil }.map { "create \($0.name) \($0.id)\n" }
        if !direct.isEmpty {
            _ = try await runner.runWrite(["update-ref", "--stdin"], stdin: Data(("start\n" + direct.joined() + "commit\n").utf8))
        }
        for ref in removed.refs {
            if let target = ref.symref { _ = try await runner.runWrite(["symbolic-ref", ref.name, target]) }
        }
        _ = try? await fetch(.remote(removed.name, prune: false))
    }

    private func trackingRefs(of remote: String) async -> [RemovedRemote.Ref] {
        guard let result = try? await runner.run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", "refs/remotes/\(remote)/"]) else { return [] }
        return result.stdoutString.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            return RemovedRemote.Ref(name: parts[0], id: parts[1], symref: parts[2].isEmpty ? nil : parts[2])
        }
    }

    /// The branches whose upstream is `remote`, as their `branch.<name>.remote` and `branch.<name>.merge` entries.
    private func branchesTracking(_ remote: String) async -> [RemovedRemote.Entry] {
        let remotes = await configEntries(matching: "^branch\\..*\\.remote$").filter { $0.value == remote }
        var entries: [RemovedRemote.Entry] = []
        for entry in remotes {
            let branch = String(entry.key.dropFirst("branch.".count).dropLast(".remote".count))
            entries.append(entry)
            entries += await configEntries(matching: "^branch\\.\(NSRegularExpression.escapedPattern(for: branch))\\.merge$")
        }
        return entries
    }

    /// Local configuration entries whose key matches `pattern`, in file order; multi-valued keys keep every value.
    private func configEntries(matching pattern: String) async -> [RemovedRemote.Entry] {
        guard let result = try? await runner.run(["config", "--local", "-z", "--get-regexp", pattern]) else { return [] }
        return result.stdoutString.split(separator: "\0").compactMap { record in
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { return nil }
            return RemovedRemote.Entry(key: String(key), value: parts.count > 1 ? String(parts[1]) : "")
        }
    }
}

/// A removed remote's configuration and the upstreams that pointed at it, enough to add it back as it was.
public struct RemovedRemote: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let value: String
    }

    /// A remote-tracking branch; `symref` is the target of a symbolic one such as `refs/remotes/origin/HEAD`.
    public struct Ref: Sendable, Equatable {
        public let name: String
        public let id: String
        public let symref: String?
    }

    public let name: String
    public let entries: [Entry]
    public let upstreams: [Entry]
    public let refs: [Ref]
}
