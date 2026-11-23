import Foundation

/// The parents and children of a commit among the loaded history, for moving along the graph.
public enum CommitRelatives {
    public struct Relative: Sendable, Equatable {
        public let id: String
        /// Only for parents: the one the commit was made on, as opposed to the branches a merge brought in.
        public let isFirstParent: Bool
    }

    public static func parents(of commit: Commit) -> [Relative] {
        commit.parents.enumerated().map { Relative(id: $1, isFirstParent: $0 == 0) }
    }

    /// Children in the order of `commits`, the history's order; each child once, also when it names the commit twice.
    public static func children(of id: String, in commits: [Commit]) -> [Relative] {
        commits.filter { $0.parents.contains(id) }.map { Relative(id: $0.id, isFirstParent: $0.parents.first == id) }
    }
}
