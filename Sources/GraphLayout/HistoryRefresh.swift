import GitEngine

/// What an in-place refresh does with the commits already loaded once a write moved refs, HEAD or stashes.
///
/// The history is everything reachable from its tips: branches, remote branches, tags, HEAD and the stash commits, as `git log` is asked for it.
public enum HistoryRefresh: Equatable, Sendable {
    /// A tip is a commit that was never loaded, such as a new commit: only the log can supply it.
    case reload
    /// Every tip is loaded. The listed commits are reached by no tip anymore and leave the history.
    case keep(dropping: Set<String>)

    /// The commits the history starts from: the refs `git log --branches --remotes --tags` names, HEAD and the stash commits.
    public static func tips(refs: [Ref], head: String?, stashCommits: some Sequence<String>) -> Set<String> {
        var tips = Set(stashCommits)
        if let head { tips.insert(head) }
        for ref in refs {
            switch ref.kind {
            case .localBranch, .remoteBranch, .tag: tips.insert(ref.target)
            case .stash, .other: break
            }
        }
        return tips
    }

    /// Where each of `ids` goes in git's `order`, as a permutation: the commit that comes `n`-th is `ids[result[n]]`. IDs git does not list keep their relative order at the end.
    /// Git's topological order depends on the whole set of commits, so commits that leave the history can move the ones that stay; the loaded order is then put in line with a fresh `rev-list`.
    public static func positions(of ids: [String], as order: [String]) -> [Int] {
        var rank: [String: Int] = [:]
        rank.reserveCapacity(order.count)
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        return ids.indices.sorted { (rank[ids[$0]] ?? Int.max, $0) < (rank[ids[$1]] ?? Int.max, $1) }
    }

    /// Walks parents over the loaded commits only, so nothing is read from git. Linear in the history size.
    public static func plan(loaded commits: [Commit], tips: Set<String>) -> HistoryRefresh {
        var parentsByID: [String: [String]] = [:]
        parentsByID.reserveCapacity(commits.count)
        for commit in commits { parentsByID[commit.id] = commit.parents }
        guard tips.allSatisfy({ parentsByID[$0] != nil }) else { return .reload }
        var reached = tips
        var stack = Array(tips)
        while let id = stack.popLast() {
            for parent in parentsByID[id] ?? [] where reached.insert(parent).inserted { stack.append(parent) }
        }
        return .keep(dropping: Set(parentsByID.keys).subtracting(reached))
    }
}
