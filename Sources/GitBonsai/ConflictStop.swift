import Foundation
import GitEngine

/// What stopped on conflicts, for the toast that says so: "Rebase stopped on conflicts in 2 files".
enum ConflictStop: Equatable {
    case operation(OperationProgress.Kind)
    case pull
    case stashApply
    case stashPop

    func title(count: Int) -> LocalizedStringResource {
        switch self {
        case .operation(.rebase): LocalizedStringResource("failure.rebase.conflicts", defaultValue: "Rebase stopped on conflicts in \(count) files", bundle: .module)
        case .operation(.merge): LocalizedStringResource("failure.merge.conflicts", defaultValue: "Merge stopped on conflicts in \(count) files", bundle: .module)
        case .operation(.cherryPick): LocalizedStringResource("failure.cherryPick.conflicts", defaultValue: "Cherry-pick stopped on conflicts in \(count) files", bundle: .module)
        case .operation(.revert): LocalizedStringResource("failure.revert.conflicts", defaultValue: "Revert stopped on conflicts in \(count) files", bundle: .module)
        case .pull: LocalizedStringResource("failure.pull.conflicts", defaultValue: "Pull stopped on conflicts in \(count) files", bundle: .module)
        case .stashApply: LocalizedStringResource("failure.stash.appliedWithConflicts", defaultValue: "Stash applied with conflicts in \(count) files", bundle: .module)
        case .stashPop: LocalizedStringResource("failure.stash.poppedWithConflicts", defaultValue: "Stash applied with conflicts in \(count) files; it stays", bundle: .module)
        }
    }
}
