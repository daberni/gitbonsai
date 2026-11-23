import Foundation

/// What a fetch reaches and whether it removes remote branches that are gone on the remote.
public enum FetchVariant: Sendable, Hashable {
    /// Every remote, pruning gone branches.
    case allRemotes
    case remote(String, prune: Bool)
    /// Every remote's tags in addition to its branches.
    case tags

    public var arguments: [String] {
        switch self {
        case .allRemotes: ["fetch", "--all", "--prune"]
        // Explicit both ways: `fetch.prune` in the user's configuration would otherwise decide.
        case .remote(let name, let prune): ["fetch", prune ? "--prune" : "--no-prune", name]
        case .tags: ["fetch", "--all", "--tags"]
        }
    }

    /// The command as the user would type it, for the status line and tooltips.
    public var commandLine: String { "git " + arguments.joined(separator: " ") }
}

/// How a pull joins the upstream's commits with the local ones.
public enum PullMode: Sendable, Hashable, CaseIterable {
    /// Only moves the branch forward; refuses when both sides have new commits.
    case fastForwardOnly
    /// Fast-forwards when possible, otherwise records a merge commit.
    case merge
    /// Replays the local commits on top of the upstream.
    case rebase
}

/// One way to pull the current branch from its upstream.
public struct PullVariant: Sendable, Hashable {
    public let mode: PullMode

    public init(mode: PullMode) {
        self.mode = mode
    }

    /// Every flag is explicit, so `pull.rebase` and `pull.ff` in the user's configuration cannot turn one variant into another.
    /// Local changes always come along with `--autostash`: git stashes them before the pull and applies them afterwards, also after a merge or rebase that stopped on conflicts and was finished later.
    public var arguments: [String] {
        let mode = switch self.mode {
        case .fastForwardOnly: ["--no-rebase", "--ff-only"]
        case .merge: ["--no-rebase", "--ff", "--no-edit"]
        case .rebase: ["--rebase"]
        }
        return ["pull"] + mode + ["--autostash"]
    }

    public var commandLine: String { "git " + arguments.joined(separator: " ") }
}

/// What a pull that succeeded did with the local changes it carried.
public struct PullResult: Sendable, Equatable {
    /// Applying the stashed local changes after the pull conflicted. The conflicts are in the working tree, and the stash stays in the list as `autostash`.
    public let localChangesConflicted: Bool

    public init(localChangesConflicted: Bool) {
        self.localChangesConflicted = localChangesConflicted
    }

    /// git reports a conflicting autostash with exit code 0, so only its message tells: "Applying autostash resulted in conflicts" or "…however applying them resulted in conflicts", wrapped over lines.
    static func parse(_ result: GitCommandResult) -> PullResult {
        let output = (result.stdoutString + "\n" + result.stderr).replacingOccurrences(of: "\n", with: " ")
        return PullResult(localChangesConflicted: output.contains("resulted in conflicts"))
    }
}

/// Where the current branch pulls from and pushes to, and how far the two have moved apart.
public struct Upstream: Sendable, Equatable {
    public let remote: String
    /// The branch on the remote, without `refs/heads/`.
    public let branch: String
    /// Commits only on the local branch and only on the upstream; nil when the remote-tracking branch does not exist (never fetched, or gone).
    public let ahead: Int?
    public let behind: Int?

    public init(remote: String, branch: String, ahead: Int?, behind: Int?) {
        self.remote = remote
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
    }

    public var name: String { "\(remote)/\(branch)" }
}

/// One push of the push menu or the first-push sheet.
public enum PushVariant: Sendable, Hashable {
    /// Local branch `branch` to `remoteBranch` on `remote`; `setUpstream` records that as its upstream, `forceWithLease` overwrites the remote branch only if it still is where the remote-tracking branch says.
    case branch(String, remote: String, remoteBranch: String, setUpstream: Bool, forceWithLease: Bool)
    /// Every local tag that the remote lacks.
    case tags(remote: String)

    public var arguments: [String] {
        switch self {
        case .branch(let branch, let remote, let remoteBranch, let setUpstream, let forceWithLease):
            ["push"] + (setUpstream ? ["-u"] : []) + (forceWithLease ? ["--force-with-lease"] : []) + [remote, "refs/heads/\(branch):refs/heads/\(remoteBranch)"]
        case .tags(let remote):
            ["push", remote, "--tags"]
        }
    }

    public var commandLine: String { "git " + arguments.joined(separator: " ") }
}

extension Repository {
    /// The configured remotes in git's order, including those that have no fetched branch yet.
    public func remotes() async throws -> [String] {
        try await runner.run(["remote"]).stdoutString.split(separator: "\n").map(String.init)
    }

    public func fetch(_ variant: FetchVariant) async throws {
        _ = try await runner.runWithoutIndex(variant.arguments)
    }

    /// The upstream that `branch.<name>.remote` and `branch.<name>.merge` configure for a local branch, or nil.
    public func upstream(of branch: String) async -> Upstream? {
        guard let remote = await configValue("branch.\(branch).remote"), let merge = await configValue("branch.\(branch).merge") else { return nil }
        let remoteBranch = merge.hasPrefix("refs/heads/") ? String(merge.dropFirst("refs/heads/".count)) : merge
        let counts = try? await runner.run(["rev-list", "--left-right", "--count", "refs/heads/\(branch)...\(branch)@{upstream}"])
        let numbers = counts?.stdoutString.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } ?? []
        return Upstream(remote: remote, branch: remoteBranch, ahead: numbers.count == 2 ? numbers[0] : nil, behind: numbers.count == 2 ? numbers[1] : nil)
    }

    /// The pull mode that `git pull` without flags would use: `pull.rebase` first, then `pull.ff`. Without either it is fast-forward only.
    public func defaultPullMode() async -> PullMode {
        if let rebase = await configValue("pull.rebase", type: "bool-or-str") {
            if rebase != "false" { return .rebase }
            return await configValue("pull.ff", type: "bool-or-str") == "only" ? .fastForwardOnly : .merge
        }
        switch await configValue("pull.ff", type: "bool-or-str") {
        case "only", nil: return .fastForwardOnly
        default: return .merge
        }
    }

    /// Pulls the current branch from its upstream. A conflict leaves git's merge or rebase in progress and is thrown so that `stoppedOnConflict` holds.
    @discardableResult
    public func pull(_ variant: PullVariant) async throws -> PullResult {
        do {
            return PullResult.parse(try await runner.runWrite(variant.arguments, environment: ["GIT_EDITOR": "true"]))
        } catch let error as GitError {
            throw await mergeConflictError(from: error) ?? error
        }
    }

    public func push(_ variant: PushVariant) async throws {
        _ = try await runner.runWithoutIndex(variant.arguments)
    }

    private func configValue(_ key: String, type: String? = nil) async -> String? {
        let arguments = ["config"] + (type.map { ["--type=\($0)"] } ?? []) + ["--get", key]
        guard let result = try? await runner.run(arguments) else { return nil }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension GitError {
    /// The remote refused a push because the remote branch has commits the pushed one does not contain.
    public var isRejectedNonFastForward: Bool {
        stderr.contains("[rejected]") && (stderr.contains("non-fast-forward") || stderr.contains("fetch first"))
    }

    /// A `--force-with-lease` push refused because the remote branch moved since it was last fetched.
    public var isStaleLease: Bool { stderr.contains("stale info") }

    /// A fast-forward-only pull refused because both sides have new commits.
    public var isDivergedPull: Bool { stderr.contains("Not possible to fast-forward") || stderr.contains("Diverging branches can't be fast-forwarded") }
}
