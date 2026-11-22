import Foundation

/// Where the avatars of a repository's authors come from, chosen from the host of one of its remotes.
public enum AvatarService: Sendable, Hashable {
    /// github.com. A noreply address names the account; other addresses are looked up through the commit API of `repository` (`owner/name`), when known.
    case gitHub(repository: String?)
    /// gitlab.com or a self-hosted GitLab at `base`, which looks addresses up at `/api/v4/avatar`.
    case gitLab(base: URL)
    /// A host without a public lookup by address, such as Bitbucket, or no remote at all.
    case none

    private static let gitHubHosts: Set<String> = ["github.com", "www.github.com", "ssh.github.com"]

    /// The service behind a remote URL in any form git accepts: `https://host/owner/name.git`, `ssh://git@host:22/owner/name` or `git@host:owner/name.git`.
    public init(remoteURL: String) {
        guard let (host, path) = Self.hostAndPath(of: remoteURL) else {
            self = .none
            return
        }
        if Self.gitHubHosts.contains(host) {
            let parts = path.split(separator: "/")
            self = .gitHub(repository: parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil)
        } else if host == "gitlab.com" || host.split(separator: ".").first?.hasPrefix("gitlab") == true, let base = URL(string: "https://\(host)") {
            self = .gitLab(base: base)
        } else {
            self = .none
        }
    }

    /// The lower-cased host and the path without leading slash, trailing slash or `.git`; nil for local paths.
    static func hostAndPath(of remoteURL: String) -> (host: String, path: String)? {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        if text.contains("://") {
            guard let components = URLComponents(string: text), let parsedHost = components.host, !parsedHost.isEmpty else { return nil }
            host = parsedHost
            path = components.path
        } else {
            // scp-like `[user@]host:path`; a slash before the colon makes it a local path.
            guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") else { return nil }
            host = String(text[..<colon])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            path = String(text[text.index(after: colon)...])
            guard !host.isEmpty else { return nil }
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        return (host.lowercased(), path)
    }

    /// The remote whose host serves the avatars: the current branch's upstream remote, else `origin`, else the first one in configuration order.
    public static func remoteURL(in remotes: [(name: String, url: String)], upstreamRemote: String?) -> String? {
        if let upstreamRemote, let match = remotes.first(where: { $0.name == upstreamRemote }) { return match.url }
        return (remotes.first(where: { $0.name == "origin" }) ?? remotes.first)?.url
    }

    /// The host the remote-host lookups talk to; nil without one.
    public var host: String? {
        switch self {
        case .gitHub: "github.com"
        case .gitLab(let base): base.host
        case .none: nil
        }
    }
}
