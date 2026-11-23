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
}
