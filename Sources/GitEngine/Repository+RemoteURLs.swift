import Foundation

/// The repository's remotes in configuration order and the remote the current branch tracks.
public struct RemoteURLs: Sendable, Equatable {
    public struct Remote: Sendable, Equatable {
        public let name: String
        public let url: String

        public init(name: String, url: String) {
            self.name = name
            self.url = url
        }
    }

    public let remotes: [Remote]
    /// Nil on a detached HEAD or a branch without upstream.
    public let upstreamRemote: String?

    public init(remotes: [Remote], upstreamRemote: String?) {
        self.remotes = remotes
        self.upstreamRemote = upstreamRemote
    }
}

extension Repository {
    public func remoteURLs() async throws -> RemoteURLs {
        // Exit code 1 means no remote is configured.
        let config = try await runner.run(["config", "-z", "--get-regexp", #"^remote\..*\.url$"#], accepting: [0, 1])
        let branches = try await runner.run(["for-each-ref", "--format=%(HEAD)%00%(upstream:remotename)", "refs/heads"])
        return RemoteURLs(remotes: Self.parseRemoteURLs(config.stdout), upstreamRemote: Self.parseUpstreamRemote(branches.stdout))
    }

    /// `remote.<name>.url\n<url>\0` per entry; a name may contain dots. A remote with several URLs keeps its first.
    static func parseRemoteURLs(_ data: Data) -> [RemoteURLs.Remote] {
        var remotes: [RemoteURLs.Remote] = []
        for record in data.split(separator: 0) {
            let text = String(decoding: record, as: UTF8.self)
            guard let newline = text.firstIndex(of: "\n") else { continue }
            let key = text[..<newline]
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".url".count))
            guard !name.isEmpty, !remotes.contains(where: { $0.name == name }) else { continue }
            remotes.append(RemoteURLs.Remote(name: name, url: String(text[text.index(after: newline)...])))
        }
        return remotes
    }

    /// `*\0<remote>` marks the checked-out branch.
    static func parseUpstreamRemote(_ data: Data) -> String? {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == Data("*".utf8)[...] else { continue }
            let remote = String(decoding: fields[1], as: UTF8.self)
            return remote.isEmpty ? nil : remote
        }
        return nil
    }
}
