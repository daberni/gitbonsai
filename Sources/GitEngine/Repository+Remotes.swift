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

extension Repository {
    /// The configured remotes in git's order, including those that have no fetched branch yet.
    public func remotes() async throws -> [String] {
        try await runner.run(["remote"]).stdoutString.split(separator: "\n").map(String.init)
    }

    public func fetch(_ variant: FetchVariant) async throws {
        _ = try await runner.runWrite(variant.arguments)
    }
}
