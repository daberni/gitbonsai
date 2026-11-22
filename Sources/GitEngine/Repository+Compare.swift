import Foundation

/// What a selection of several commits compares, decided from the commits alone except for the merge base of a pair.
public enum CommitComparison: Sendable, Hashable {
    /// Two commits: `git diff <older> <newer>`. `mergeBase` is set when the older one is not an ancestor of the newer one, that is when they sit on different branches; `git diff <older>...<newer>` then compares from there.
    case pair(older: Commit, newer: Commit, mergeBase: String?)
    /// More than two commits that follow one another on one first-parent line, oldest last: one combined diff `git diff <oldest>^ <newest>`, like a squash.
    case run([Commit])
    /// More than two commits with others between them: each one on its own, newest first, as `git show` lists them.
    case separate([Commit])
}

extension Repository {
    /// Decides what `commits` compare. They come newest first, as the history lists them; `older` and `newer` of a pair follow that order.
    public func comparison(of commits: [Commit]) async -> CommitComparison {
        precondition(commits.count >= 2, "A comparison needs at least two commits")
        if commits.count == 2 {
            let newer = commits[0]
            let older = commits[1]
            let base = await mergeBase(older.id, newer.id)
            return .pair(older: older, newer: newer, mergeBase: base == older.id ? nil : base)
        }
        if let run = Self.firstParentRun(commits) { return .run(run) }
        return .separate(commits)
    }

    /// The commits ordered newest to oldest when each one's first parent is the next one, so that nothing else lies between them; nil otherwise.
    /// The order they come in does not matter: the history may list a run interleaved with other branches.
    public static func firstParentRun(_ commits: [Commit]) -> [Commit]? {
        guard !commits.isEmpty else { return nil }
        let byID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let firstParents = Set(commits.compactMap(\.parents.first))
        // The newest commit is the only one that is no other's first parent.
        let tips = commits.filter { !firstParents.contains($0.id) }
        guard tips.count == 1, var current = tips.first else { return nil }
        var run = [current]
        while let parent = current.parents.first, let next = byID[parent] {
            run.append(next)
            current = next
        }
        return run.count == byID.count ? run : nil
    }

    /// Where the combined diff of a run starts: the oldest commit's first parent, or the empty tree for a root commit.
    public func base(before commit: Commit) async throws -> String {
        if let parent = commit.parents.first { return parent }
        return try await emptyTree()
    }
}
