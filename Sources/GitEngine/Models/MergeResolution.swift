import Foundation

/// The result of a three-way merge as the user builds it, change by change: which sides are taken and in which order, or lines the word merge produced.
/// Changes of one side start as taken; conflicts start open. Taking a side appends it after what is taken already; ignoring one takes it out. A change with nothing taken keeps the base.
public struct MergeResolution: Sendable, Equatable {
    public struct State: Sendable, Equatable {
        /// The sides in the result, in the order they were taken.
        public var taken: [ConflictSide]
        /// Sides the user took or ignored; a conflict is resolved once one side is.
        public var decided: Set<ConflictSide>
        /// Lines that replace the sides, from the word merge.
        public var merged: [String]?

        public init(taken: [ConflictSide], decided: Set<ConflictSide>, merged: [String]? = nil) {
            self.taken = taken
            self.decided = decided
            self.merged = merged
        }
    }

    public let document: MergeDocument
    public private(set) var states: [State]

    public init(document: MergeDocument) {
        self.document = document
        states = document.changes.map { change in
            switch change.kind {
            case .ours, .both: State(taken: [.ours], decided: [.ours, .theirs])
            case .theirs: State(taken: [.theirs], decided: [.ours, .theirs])
            case .conflict: State(taken: [], decided: [])
            }
        }
    }

    /// Continues with states kept from an earlier visit of the same document.
    public init(document: MergeDocument, states: [State]) {
        self.init(document: document)
        if states.count == self.states.count { self.states = states }
    }

    public var changes: [MergeChange] { document.changes }

    public mutating func take(_ side: ConflictSide, at index: Int) {
        guard states.indices.contains(index) else { return }
        if !states[index].taken.contains(side) { states[index].taken.append(side) }
        states[index].decided.insert(side)
        states[index].merged = nil
    }

    public mutating func ignore(_ side: ConflictSide, at index: Int) {
        guard states.indices.contains(index) else { return }
        states[index].taken.removeAll { $0 == side }
        states[index].decided.insert(side)
        states[index].merged = nil
    }

    public mutating func setMerged(_ lines: [String], at index: Int) {
        guard states.indices.contains(index) else { return }
        states[index].merged = lines
        states[index].decided = [.ours, .theirs]
    }

    /// Resolves every open conflict with the sides in `order`.
    public mutating func takeInOpenConflicts(_ order: [ConflictSide]) {
        for index in states.indices where !isResolved(index) {
            order.forEach { take($0, at: index) }
        }
    }

    public func isResolved(_ index: Int) -> Bool {
        guard states.indices.contains(index) else { return false }
        return !states[index].decided.isEmpty || states[index].merged != nil
    }

    /// The lines of a change in the result, nil while it is an open conflict.
    public func result(at index: Int) -> [String]? {
        guard isResolved(index) else { return nil }
        let state = states[index]
        if let merged = state.merged { return merged }
        let change = changes[index]
        return state.taken.isEmpty ? change.base : state.taken.flatMap { change.lines(of: $0) }
    }

    public var openConflicts: Int { states.indices.filter { !isResolved($0) }.count }

    /// The whole file, nil while a conflict is open.
    public var text: String? { document.text(with: states.indices.map(result(at:))) }
}
