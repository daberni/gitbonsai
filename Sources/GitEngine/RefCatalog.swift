import Foundation

/// What a ref picker offers, in sections: the current position, local branches, remote branches per remote, tags, and a commit a typed SHA names.
/// Filtering keeps the order and drops sections without a match.
public struct RefCatalog: Sendable {
    public enum Section: Sendable, Hashable {
        case current
        case local
        case remote(String)
        case tags
        case commit
    }

    public struct Item: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            /// HEAD, on `branch` or detached when nil.
            case head(branch: String?)
            case commit
            case localBranch(isHead: Bool)
            case remoteBranch(remote: String)
            case tag
        }

        public let kind: Kind
        /// The name a row shows: a branch or tag name, or the short SHA of a commit.
        public let title: String
        /// What git is given for it.
        public let revision: String
        public let commit: CommitSummary
        /// Why a commit is offered, such as "Merge-Base"; shown and searched next to its subject.
        public let note: String?

        public var id: String { "\(kind)|\(revision)" }

        public init(kind: Kind, title: String, revision: String, commit: CommitSummary, note: String? = nil) {
            self.kind = kind
            self.title = title
            self.revision = revision
            self.commit = commit
            self.note = note
        }

        public static func head(branch: String?, commit: CommitSummary) -> Item {
            Item(kind: .head(branch: branch), title: branch ?? commit.shortID, revision: "HEAD", commit: commit)
        }

        public static func commit(_ commit: CommitSummary, note: String? = nil) -> Item {
            Item(kind: .commit, title: commit.shortID, revision: commit.sha, commit: commit, note: note)
        }
    }

    /// An item with the ranges of its title that the query matched.
    public struct Match: Sendable, Hashable {
        public let item: Item
        public let titleRanges: [NSRange]
    }

    public struct Group: Sendable, Hashable {
        public let section: Section
        public let matches: [Match]
    }

    private let current: [Item]
    private let locals: [Item]
    private let remotes: [(remote: String, items: [Item])]
    private let tags: [Item]

    /// `current` comes first as given: HEAD, then for example the commit selected in the history.
    public init(tips: [RefTip], current: [Item]) {
        self.current = current
        var locals: [Item] = []
        var remotes: [String: [Item]] = [:]
        var tags: [(Item, Date)] = []
        let headBranch = current.lazy.compactMap { if case .head(let branch) = $0.kind { branch } else { nil } }.first
        for tip in tips {
            switch tip.kind {
            case .localBranch:
                locals.append(Item(kind: .localBranch(isHead: tip.name == headBranch), title: tip.name, revision: tip.name, commit: tip.commit))
            case .remoteBranch(let remote):
                remotes[remote, default: []].append(Item(kind: .remoteBranch(remote: remote), title: tip.name, revision: tip.name, commit: tip.commit))
            case .tag:
                tags.append((Item(kind: .tag, title: tip.name, revision: tip.name, commit: tip.commit), tip.commit.date))
            case .stash, .other:
                break
            }
        }
        let byName: (Item, Item) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        self.locals = locals.sorted(by: byName)
        self.remotes = remotes.keys.sorted { lhs, rhs in lhs == "origin" || (rhs != "origin" && lhs < rhs) }.map { ($0, remotes[$0]!.sorted(by: byName)) }
        self.tags = tags.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The groups whose items match `query`; `resolved` is the commit the query names as a revision, offered in its own group.
    public func groups(matching query: String, resolved: CommitSummary? = nil) -> [Group] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var groups: [Group] = []
        func add(_ section: Section, _ items: [Item]) {
            let matches = items.compactMap { Self.match($0, text) }
            if !matches.isEmpty { groups.append(Group(section: section, matches: matches)) }
        }
        add(.current, current)
        add(.local, locals)
        for (remote, items) in remotes { add(.remote(remote), items) }
        add(.tags, tags)
        if let resolved, !text.isEmpty { groups.append(Group(section: .commit, matches: [Match(item: .commit(resolved), titleRanges: [])])) }
        return groups
    }

    /// The item whose title is exactly `query`, ignoring surrounding whitespace.
    public func item(titled query: String) -> Item? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (current + locals + remotes.flatMap(\.items) + tags).first { $0.title == text }
    }

    /// Whether `query` could name a commit by its SHA, so it is worth asking git.
    public static func looksLikeSHA(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (CommitSearch.minimumSHAPrefix...40).contains(text.utf8.count) && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// A title match highlights every occurrence; HEAD also matches "head", and every item matches a prefix of its SHA, both without highlight.
    private static func match(_ item: Item, _ text: String) -> Match? {
        guard !text.isEmpty else { return Match(item: item, titleRanges: []) }
        let ranges = occurrences(of: text, in: item.title)
        if !ranges.isEmpty { return Match(item: item, titleRanges: ranges) }
        if case .head = item.kind, "HEAD".range(of: text, options: .caseInsensitive) != nil { return Match(item: item, titleRanges: []) }
        if looksLikeSHA(text), item.commit.sha.hasPrefix(text.lowercased()) { return Match(item: item, titleRanges: []) }
        if case .commit = item.kind, ([item.commit.subject] + [item.note].compactMap { $0 }).contains(where: { $0.range(of: text, options: .caseInsensitive) != nil }) { return Match(item: item, titleRanges: []) }
        return nil
    }

    private static func occurrences(of text: String, in string: String) -> [NSRange] {
        let haystack = string as NSString
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: haystack.length)
        while searchRange.length > 0 {
            let found = haystack.range(of: text, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: haystack.length - next)
        }
        return result
    }
}
