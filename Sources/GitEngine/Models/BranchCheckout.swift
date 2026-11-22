import Foundation

/// One branch that checking out a commit can land on, decided from the refs alone.
public struct BranchCheckout: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Switch to the existing local branch.
        case local
        /// The local branch follows `from` and is behind it only; check it out and fast-forward it there.
        case fastForward(from: String)
        /// The local branch and `from`, the remote branch it follows, both have commits of their own; `localCommits` are those only the local branch has.
        /// It is checked out as it is, or reset to `from`, which drops those commits.
        case diverged(from: String, localCommits: Int)
        /// No local branch follows the remote one yet; create one that tracks it.
        case createTracking(remote: String)
    }

    /// The local branch that ends up checked out.
    public let branch: String
    public let kind: Kind

    public init(branch: String, kind: Kind) {
        self.branch = branch
        self.kind = kind
    }

    public var target: CheckoutTarget {
        switch kind {
        case .local, .diverged: .localBranch(branch)
        case .fastForward(let upstream): .fastForward(branch: branch, to: upstream)
        case .createTracking(let remote): .remoteBranch(remote: remote, branch: branch)
        }
    }

    /// The branches a history row at `commit` offers, each local branch once: the local branches at the commit first, then for each remote branch at it the local branch that tracks it (or has its name), or a new tracking branch.
    /// `refs` are all refs of the repository, so that counterparts elsewhere in the history are found.
    public static func choices(at commit: String, refs: [Ref]) -> [BranchCheckout] {
        let locals = refs.filter { $0.kind == .localBranch }
        var choices: [BranchCheckout] = []
        func add(_ choice: BranchCheckout?) {
            guard let choice, !choices.contains(where: { $0.branch == choice.branch }) else { return }
            choices.append(choice)
        }
        for ref in locals where ref.target == commit && !ref.isHead {
            add(BranchCheckout(branch: ref.name, kind: .local))
        }
        let remotes = refs.filter { ref in
            guard case .remoteBranch = ref.kind else { return false }
            return ref.target == commit && !ref.name.hasSuffix("/HEAD")
        }
        // With the same branch on several remotes, a new tracking branch follows origin.
        let ordered = remotes.filter { $0.kind == .remoteBranch(remote: "origin") } + remotes.filter { $0.kind != .remoteBranch(remote: "origin") }
        for ref in ordered {
            guard case .remoteBranch(let remote) = ref.kind else { continue }
            let branch = String(ref.name.dropFirst(remote.count + 1))
            if let local = locals.first(where: { $0.upstream == ref.name }) ?? locals.first(where: { $0.name == branch }) {
                add(counterpartChoice(local, of: ref))
            } else {
                add(BranchCheckout(branch: branch, kind: .createTracking(remote: remote)))
            }
        }
        return choices
    }

    /// How `local` is checked out from the row of `remote`. The current branch gets only a fast-forward or a reset; there is nothing to switch to.
    /// The relation is known only when `local` tracks `remote`; a branch that merely shares the name is checked out as it is.
    private static func counterpartChoice(_ local: Ref, of remote: Ref) -> BranchCheckout? {
        let plain = local.isHead ? nil : BranchCheckout(branch: local.name, kind: .local)
        guard local.target != remote.target, local.upstream == remote.name, let ahead = local.ahead, let behind = local.behind, behind > 0 else { return plain }
        if ahead == 0 { return BranchCheckout(branch: local.name, kind: .fastForward(from: remote.name)) }
        return BranchCheckout(branch: local.name, kind: .diverged(from: remote.name, localCommits: ahead))
    }
}
