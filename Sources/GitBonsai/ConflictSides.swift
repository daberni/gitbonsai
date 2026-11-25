import Foundation
import GitEngine

/// The names of the two sides of a conflict as marked text: the branch or commit each side comes from, depending on the operation that stopped.
struct ConflictSides {
    let ours: String
    let theirs: String

    /// A merge or cherry-pick brings `theirs` into the checked-out branch; a rebase replays `theirs` onto what HEAD has become; without an operation the conflicts come from a stash.
    static func of(_ progress: OperationProgress?, branch: String?, head: String?, name: (String) -> String) -> ConflictSides {
        let current = branch.map(RefName.branch) ?? head.map(name) ?? "HEAD"
        guard let progress else { return ConflictSides(ours: current, theirs: RefName.stash("stash")) }
        switch progress.kind {
        case .merge:
            return ConflictSides(ours: current, theirs: progress.commit.map(name) ?? "MERGE_HEAD")
        case .cherryPick, .revert:
            return ConflictSides(ours: current, theirs: progress.commit.map(RefName.commit) ?? progress.kind.command)
        case .rebase:
            let replayed: String? = if case .conflict(let commit, _)? = progress.stop { commit } else { progress.commit }
            return ConflictSides(ours: head.map(name) ?? current, theirs: replayed.map(RefName.commit) ?? "REBASE_HEAD")
        }
    }

    /// The badge of the header: what happened on each side.
    static func word(for kind: ConflictKind) -> String {
        switch kind {
        case .bothModified: String(localized: "conflict.kind.bothModified", defaultValue: "both modified", bundle: .module, comment: "Badge on a conflict: both sides changed the file")
        case .bothAdded: String(localized: "conflict.kind.bothAdded", defaultValue: "both added", bundle: .module, comment: "Badge on a conflict: both sides added a file at this path")
        case .bothDeleted: String(localized: "conflict.kind.bothDeleted", defaultValue: "both deleted", bundle: .module, comment: "Badge on a conflict: both sides deleted or renamed the file")
        case .addedByUs: String(localized: "conflict.kind.addedByUs", defaultValue: "added by us", bundle: .module, comment: "Badge on a conflict: only our side has the file at this path")
        case .addedByThem: String(localized: "conflict.kind.addedByThem", defaultValue: "added by them", bundle: .module, comment: "Badge on a conflict: only their side has the file at this path")
        case .deletedByUs: String(localized: "conflict.kind.deletedByUs", defaultValue: "deleted by us", bundle: .module, comment: "Badge on a conflict: our side deleted the file, theirs changed it")
        case .deletedByThem: String(localized: "conflict.kind.deletedByThem", defaultValue: "deleted by them", bundle: .module, comment: "Badge on a conflict: their side deleted the file, ours changed it")
        }
    }

    /// The sentence above the choice of a conflict that cannot be merged line by line.
    func explanation(of conflict: Conflict) -> RefString {
        // Text on both sides only gets here when it is too large to merge, which is offered like a binary.
        let resource: LocalizedStringResource = switch conflict.kind {
        case .deletedByThem: LocalizedStringResource("conflict.explain.deletedByThem", defaultValue: "\(ours) changed the file, \(theirs) deleted it.", bundle: .module)
        case .deletedByUs: LocalizedStringResource("conflict.explain.deletedByUs", defaultValue: "\(ours) deleted the file, \(theirs) changed it.", bundle: .module)
        case .addedByUs: Self.onlyOneSide(kept: ours, other: theirs)
        case .addedByThem: Self.onlyOneSide(kept: theirs, other: ours)
        case .bothDeleted: LocalizedStringResource("conflict.explain.bothDeleted", defaultValue: "\(ours) and \(theirs) both deleted the file or renamed it to different paths.", bundle: .module)
        case .bothModified, .bothAdded: LocalizedStringResource("conflict.explain.binary", defaultValue: "\(ours) and \(theirs) both changed this file, and it can’t be merged line by line: it is binary or too large. Take one of them as a whole.", bundle: .module)
        }
        return RefString(resource)
    }

    private static func onlyOneSide(kept: String, other: String) -> LocalizedStringResource {
        LocalizedStringResource("conflict.explain.addedByOneSide", defaultValue: "Only \(kept) has the file at this path; \(other) deleted it or renamed it differently.", bundle: .module)
    }
}
