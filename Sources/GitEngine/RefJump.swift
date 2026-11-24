import Foundation

/// The refs "Go to Ref…" offers and how it orders them for a query. Pure, so the ranking and the checkout rules are testable without the command bar.
public enum RefJump {
    public enum Kind: Sendable, Hashable {
        case localBranch(isHead: Bool)
        case remoteBranch(remote: String)
        case tag
        case worktree(path: String, isCurrent: Bool)
        case stash

        /// Order of the kinds in the empty list and among equally good matches: what one jumps to most often first.
        var order: Int {
            switch self {
            case .localBranch: 0
            case .worktree: 1
            case .remoteBranch: 2
            case .tag: 3
            case .stash: 4
            }
        }

        /// Order of the refs after the best match inside a merged row.
        var groupOrder: Int {
            switch self {
            case .localBranch: 0
            case .remoteBranch: 1
            case .tag: 2
            case .worktree: 3
            case .stash: 4
            }
        }
    }

    public struct Target: Sendable, Hashable, Identifiable {
        public let kind: Kind
        /// What the row shows and the query is matched against: branch or tag name, worktree folder, `stash@{n}`.
        public let name: String
        /// The commit the ref points at; nil for a worktree without a commit.
        public let commit: String?
        /// Also searched, never highlighted: the worktree's branch, the stash's message.
        public let detail: String?

        public var id: String {
            switch kind {
            case .localBranch: "refs/heads/" + name
            case .remoteBranch: "refs/remotes/" + name
            case .tag: "refs/tags/" + name
            case .worktree(let path, _): "worktree:" + path
            case .stash: "stash:" + name
            }
        }

        public init(kind: Kind, name: String, commit: String?, detail: String? = nil) {
            self.kind = kind
            self.name = name
            self.commit = commit
            self.detail = detail
        }
    }

    public struct Match: Sendable, Equatable {
        public let target: Target
        /// What to highlight in the name; empty when only the detail matched.
        public let nameRanges: [NSRange]
    }

    /// Branches, worktrees, remote branches without their `HEAD` alias, tags and stashes; the checked-out branch first among the local ones.
    public static func targets(refs: [Ref], worktrees: [(worktree: Worktree, isCurrent: Bool)], stashes: [Stash]) -> [Target] {
        var result: [Target] = []
        for ref in refs {
            switch ref.kind {
            case .localBranch: result.append(Target(kind: .localBranch(isHead: ref.isHead), name: ref.name, commit: ref.target))
            case .remoteBranch(let remote) where !ref.name.hasSuffix("/HEAD"): result.append(Target(kind: .remoteBranch(remote: remote), name: ref.name, commit: ref.target))
            case .tag: result.append(Target(kind: .tag, name: ref.name, commit: ref.target))
            default: break
            }
        }
        for (worktree, isCurrent) in worktrees where !worktree.isBare && !worktree.isPrunable {
            result.append(Target(kind: .worktree(path: worktree.path, isCurrent: isCurrent), name: (worktree.path as NSString).lastPathComponent, commit: worktree.headSHA, detail: worktree.branch.map(Self.shortBranch)))
        }
        for stash in stashes {
            result.append(Target(kind: .stash, name: stash.selector, commit: stash.commitID, detail: stash.message))
        }
        return result.enumerated().sorted { a, b in
            let (ka, kb) = (a.element.kind.order, b.element.kind.order)
            if ka != kb { return ka < kb }
            let (ha, hb) = (a.element.kind == .localBranch(isHead: true), b.element.kind == .localBranch(isHead: true))
            if ha != hb { return ha }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `git worktree list` names the branch in full.
    private static func shortBranch(_ name: String) -> String {
        name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }

    /// A name typed out in full, or its last path segment ("login" for `feature/login`), beats any fuzzy hit.
    private static let exactBonus = 100
    /// See `CommandRanking.keywordDiscount`: a detail word always starts its text, so it must not beat a word inside a name.
    private static let detailDiscount = FuzzyMatch.prefixBonus + 2

    /// Every word of the query has to match the name or the detail. Better matches first; equal ones keep the kinds' order and then the order of `targets`.
    public static func rank(_ targets: [Target], query: String) -> [Match] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let whole = fold(query.trimmingCharacters(in: .whitespaces))
        var scored: [(index: Int, match: Match, score: Int)] = []
        for (index, target) in targets.enumerated() {
            guard let (score, ranges) = match(words, target) else { continue }
            let name = fold(target.name)
            let exact = !whole.isEmpty && (name == whole || name.split(separator: "/").last.map(String.init) == whole)
            scored.append((index, Match(target: target, nameRanges: ranges), score + (exact ? exactBonus : 0)))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let (ka, kb) = (a.match.target.kind.order, b.match.target.kind.order)
            if ka != kb { return ka < kb }
            return a.index < b.index
        }
        return scored.map(\.match)
    }

    /// Matches that point at the same commit, shown as one row: the best-matching ref first, then local branches, remote branches, tags and worktrees.
    public struct Group: Sendable, Equatable {
        public let matches: [Match]

        public var best: Match { matches[0] }

        /// What ⌥⏎ checks out: the best match, unless it is a tag and the group has a branch to check out instead, so the checkout does not detach HEAD needlessly.
        public var checkoutTarget: Target {
            guard best.target.kind == .tag else { return best.target }
            let local = matches.first { if case .localBranch = $0.target.kind { true } else { false } }
            let remote = matches.first { if case .remoteBranch = $0.target.kind { true } else { false } }
            return (local ?? remote ?? best).target
        }
    }

    /// Groups ranked matches by commit, keeping the ranking: a group stands where its best match stood. Stashes and worktrees without a commit stay alone.
    public static func group(_ matches: [Match]) -> [Group] {
        var order: [String] = []
        var members: [String: [Match]] = [:]
        for match in matches {
            let key = match.target.kind == .stash ? nil : match.target.commit
            let id = key.map { "commit:" + $0 } ?? "target:" + match.target.id
            if members[id] == nil { order.append(id) }
            members[id, default: []].append(match)
        }
        return order.map { id in
            let group = members[id]!
            let rest = group.dropFirst().enumerated().sorted { a, b in
                let (ka, kb) = (a.element.target.kind.groupOrder, b.element.target.kind.groupOrder)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
            return Group(matches: [group[0]] + rest)
        }
    }

    private static func match(_ words: [String], _ target: Target) -> (Int, [NSRange])? {
        var total = 0
        var ranges: [NSRange] = []
        for word in words {
            let inName = FuzzyMatch.match(word, in: target.name)
            let inDetail = target.detail.flatMap { FuzzyMatch.match(word, in: $0) }.map { $0.score - detailDiscount }
            switch (inName, inDetail) {
            case (nil, nil): return nil
            case (let name?, let detail?) where detail > name.score: total += detail
            case (let name?, _):
                total += name.score
                ranges += name.ranges
            case (nil, let detail?): total += detail
            }
        }
        return (total, ranges.sorted { $0.location < $1.location })
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension CommandRules {
    /// ⌥⏎ in "Go to Ref…": checks out a branch or tag, or switches to a worktree. Stashes cannot be checked out, and the checked-out branch and the shown worktree are already there.
    public static func checkout(_ target: RefJump.Target, _ state: RepositoryCommandState) -> CommandBlocker? {
        switch target.kind {
        case .stash: return .notCheckoutable
        case .localBranch(isHead: true), .worktree(_, isCurrent: true): return .checkedOut
        case .worktree: return nil
        case .localBranch, .remoteBranch, .tag: return checkout(state)
        }
    }

    /// "Go to Ref…" lists the refs of a repository with at least one commit.
    public static func goToRef(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.headSHA == nil ? .noCommits : nil
    }
}
