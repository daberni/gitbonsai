import Foundation

/// Where the history selection goes when a query takes effect: to the topmost match. When an active query is changed, a selected commit that still matches stays selected, so refining a query keeps your place.
/// A new search always jumps, since a broad first character such as "c" matches almost any row and would otherwise never move the selection.
///
/// The choice is made once per query. Matches arrive chunk by chunk in history order, so the first one found is the topmost; matches found after the choice never move the selection.
public struct CommitSearchJump: Sendable, Equatable {
    /// Whether the selection still waits for a first match.
    public private(set) var isPending: Bool

    /// `selected` is the commit selected when the query takes effect; nil for no selection or the uncommitted changes. `refines` tells whether another query was active before.
    public init(search: CommitSearch, refines: Bool, selected: Commit?, refNames: [String] = []) {
        let keepsSelection = refines && (selected.map { search.matches($0, refNames: refNames) } ?? false)
        isPending = !keepsSelection
    }

    /// The commit to select for the next chunk of matches in history order. Nil once the choice is made or while nothing matched yet.
    public mutating func target(among matches: [String]) -> String? {
        guard isPending, let first = matches.first else { return nil }
        isPending = false
        return first
    }

    /// A row the user chose wins over a match that is still to come.
    public mutating func cancel() {
        isPending = false
    }
}
