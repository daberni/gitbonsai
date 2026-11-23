import Foundation

/// A local branch and its counterparts on every remote, as "Delete everywhere" removes them.
public struct BranchDeletion: Sendable, Equatable {
    public enum Place: Sendable, Hashable {
        case local(String)
        /// `branch` is the name on the remote, which differs from the local name for a tracked upstream of another name.
        case remote(String, branch: String)
    }

    public struct Target: Sendable, Equatable, Hashable {
        public let place: Place
        public let commit: String
        /// The ref has commits that no ref outside this deletion contains; afterwards only the reflog reaches them.
        public let isUnmerged: Bool

        /// The local name, or `remote/branch` as the remote-tracking ref is named.
        public var name: String {
            switch place {
            case .local(let name): name
            case .remote(let remote, let branch): "\(remote)/\(branch)"
            }
        }

        public var isRemote: Bool { if case .remote = place { true } else { false } }

        /// The command that deletes it: `-d` for a local branch whose commits stay reachable, `-D` otherwise.
        public var commandLine: String {
            switch place {
            case .local(let name): "git branch \(isUnmerged ? "-D" : "-d") \(name)"
            case .remote(let remote, let branch): "git push \(remote) --delete refs/heads/\(branch)"
            }
        }
    }

    public let branch: String
    public let targets: [Target]
}

extension Repository {
    /// Local branch `name` with every remote branch of the same name and its upstream, each with whether it holds commits that only the deleted refs contain.
    public func branchDeletion(of name: String) async throws -> BranchDeletion {
        let local = try await runner.run(["for-each-ref", "--format=%(objectname)%00%(upstream:remotename)%00%(upstream:remoteref)", "refs/heads/\(name)"]).stdoutString.trimmingCharacters(in: .newlines)
        let remoteNames = try await runner.run(["remote"]).stdoutString.split(separator: "\n").map(String.init)
        var places: [(BranchDeletion.Place, String)] = []
        if !local.isEmpty {
            let fields = local.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            places.append((.local(name), fields[0]))
            if fields.count == 3, !fields[1].isEmpty, fields[2].hasPrefix("refs/heads/") {
                let upstream = String(fields[2].dropFirst("refs/heads/".count))
                if let sha = await resolveCommit("refs/remotes/\(fields[1])/\(upstream)") { places.append((.remote(fields[1], branch: upstream), sha)) }
            }
        }
        for remote in remoteNames where !places.contains(where: { $0.0 == .remote(remote, branch: name) }) {
            if let sha = await resolveCommit("refs/remotes/\(remote)/\(name)") { places.append((.remote(remote, branch: name), sha)) }
        }
        // Commits count as merged when a ref outside this deletion reaches them.
        var exclusion: [String] = []
        for case (.local(let branch), _) in places { exclusion.append("--exclude=\(branch)") }
        exclusion.append("--branches")
        for case (.remote(let remote, let branch), _) in places { exclusion.append("--exclude=\(remote)/\(branch)") }
        exclusion += ["--remotes", "--tags", "HEAD"]
        var targets: [BranchDeletion.Target] = []
        for (place, sha) in places {
            let count = try await runner.run(["rev-list", "--count", sha, "--not"] + exclusion).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            targets.append(BranchDeletion.Target(place: place, commit: sha, isUnmerged: (Int(count) ?? 0) > 0))
        }
        return BranchDeletion(branch: name, targets: targets)
    }

    /// Deletes `targets`: the local branch first, then each remote branch with its own push. A remote that fails does not stop the others; the first failure is thrown at the end.
    public func delete(_ targets: [BranchDeletion.Target]) async throws {
        var failure: Error?
        for target in targets {
            do {
                switch target.place {
                case .local(let name):
                    do {
                        try await deleteBranch(name, force: target.isUnmerged)
                    } catch let error as GitError where error.isUnmergedBranch {
                        // `-d` only looks at HEAD and the upstream; the commits are in another ref, so nothing is lost.
                        try await deleteBranch(name, force: true)
                    }
                case .remote(let remote, let branch):
                    try await deleteRemoteBranch(branch, on: remote)
                }
            } catch {
                if case .local = target.place { throw error }
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }
}
