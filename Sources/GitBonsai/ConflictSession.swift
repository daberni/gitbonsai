import Foundation
import GitEngine

/// The decisions on one conflicted text file, shared by the unified view in the history pane and the merge window: a change in one shows in the other at once.
@MainActor
final class ConflictSession {
    let conflict: Conflict
    let sides: ConflictSides
    private(set) var resolution: MergeResolution
    /// The word merges git found for open conflicts, by change; a conflict without one cannot be merged word by word.
    private(set) var wordMerges: [Int: [String]] = [:]
    /// The change the navigation stands on, the same in both views.
    var current = 0 { didSet { notify() } }
    private var observers: [UUID: () -> Void] = [:]

    init(conflict: Conflict, document: MergeDocument, sides: ConflictSides, states: [MergeResolution.State]) {
        self.conflict = conflict
        self.sides = sides
        resolution = MergeResolution(document: document, states: states)
        current = resolution.states.indices.first { !resolution.isResolved($0) } ?? 0
    }

    var path: String { conflict.path }

    func update(_ change: (inout MergeResolution) -> Void) {
        change(&resolution)
        notify()
    }

    func take(_ side: ConflictSide, at index: Int) { update { $0.take(side, at: index) } }
    func ignore(_ side: ConflictSide, at index: Int) { update { $0.ignore(side, at: index) } }

    /// Takes the word merge of a conflict; false when git found none.
    @discardableResult
    func mergeWords(at index: Int) -> Bool {
        guard let lines = wordMerges[index] else { return false }
        update { $0.setMerged(lines, at: index) }
        return true
    }

    /// Takes every word merge of an open conflict; false when there was none.
    @discardableResult
    func mergeAllWords() -> Bool {
        let open = wordMerges.filter { !resolution.isResolved($0.key) }
        guard !open.isEmpty else { return false }
        update { resolution in open.forEach { resolution.setMerged($0.value, at: $0.key) } }
        return true
    }

    /// Opens a conflict again, as it was before any decision.
    func reopen(_ index: Int) {
        var states = resolution.states
        guard states.indices.contains(index) else { return }
        states[index] = MergeResolution.State(taken: [], decided: [])
        update { $0 = MergeResolution(document: $0.document, states: states) }
    }

    /// Asks git for the word merge of every conflict, once after loading.
    func findWordMerges(in repository: Repository) async {
        var found: [Int: [String]] = [:]
        for (index, change) in resolution.changes.enumerated() where change.kind == .conflict {
            if let lines = try? await repository.mergeWords(of: change) { found[index] = lines }
        }
        wordMerges = found
        notify()
    }

    func observe(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        observers.values.forEach { $0() }
    }
}
