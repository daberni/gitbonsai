import AppKit
import GitEngine

/// The app's words for a failed git command: one sentence of what happened, with git's own output kept as details.
enum GitFailureText {
    /// "Commit 11f8174 “Add an ETP tab” could not be applied.", the commit as a pill; the subject is prose and keeps its quotes.
    static func summary(of error: Error) -> RefString {
        guard let gitError = error as? GitError else { return RefString(verbatim: error.localizedDescription) }
        let resource: LocalizedStringResource
        switch GitFailure(output: gitError.stderr) {
        case let .couldNotApply(commit, subject) where subject.isEmpty: resource = LocalizedStringResource("failure.reason.couldNotApply", defaultValue: "Commit \(RefName.commit(commit)) could not be applied.", bundle: .module)
        case let .couldNotApply(commit, subject): resource = LocalizedStringResource("failure.reason.couldNotApplySubject", defaultValue: "Commit \(RefName.commit(commit)) “\(subject)” could not be applied.", bundle: .module)
        case let .couldNotRevert(commit, subject) where subject.isEmpty: resource = LocalizedStringResource("failure.reason.couldNotRevert", defaultValue: "Commit \(RefName.commit(commit)) could not be reverted.", bundle: .module)
        case let .couldNotRevert(commit, subject): resource = LocalizedStringResource("failure.reason.couldNotRevertSubject", defaultValue: "Commit \(RefName.commit(commit)) “\(subject)” could not be reverted.", bundle: .module)
        case let .conflicts(paths) where paths.count > shownPaths: resource = LocalizedStringResource("failure.reason.conflictsMore", defaultValue: "Conflicts in \(listed(paths)) and \(paths.count - shownPaths) more.", bundle: .module)
        case let .conflicts(paths): resource = LocalizedStringResource("failure.reason.conflicts", defaultValue: "Conflicts in \(listed(paths)).", bundle: .module)
        case let .localChangesInTheWay(paths) where paths.isEmpty: resource = LocalizedStringResource("failure.reason.localChanges", defaultValue: "Local changes would be overwritten.", bundle: .module)
        case let .localChangesInTheWay(paths) where paths.count > shownPaths: resource = LocalizedStringResource("failure.reason.localChangesPathsMore", defaultValue: "Local changes would be overwritten: \(listed(paths)) and \(paths.count - shownPaths) more.", bundle: .module)
        case let .localChangesInTheWay(paths): resource = LocalizedStringResource("failure.reason.localChangesPaths", defaultValue: "Local changes would be overwritten: \(listed(paths)).", bundle: .module)
        case .uncommittedChanges: resource = LocalizedStringResource("failure.reason.uncommittedChanges", defaultValue: "Uncommitted changes are in the way; commit or stash them first.", bundle: .module)
        case .emptyStep: resource = LocalizedStringResource("failure.reason.emptyStep", defaultValue: "The step is empty; there is nothing to commit.", bundle: .module)
        case .unreachable: resource = LocalizedStringResource("failure.reason.unreachable", defaultValue: "The server cannot be reached; check the network and the remote URL.", bundle: .module)
        case .authenticationFailed: resource = LocalizedStringResource("failure.reason.authenticationFailed", defaultValue: "Sign-in failed. Store the credentials in the credential helper or add the SSH key to the SSH agent.", bundle: .module)
        case let .message(text) where text.isEmpty: resource = LocalizedStringResource("failure.reason.exitCode", defaultValue: "git reports an error (exit code \(Int(gitError.exitCode))).", bundle: .module)
        case let .message(text): return RefString(verbatim: text.prefix(1).uppercased() + text.dropFirst())
        }
        return RefString(resource)
    }

    /// Local changes stopped the command before it changed anything, so stashing them and running it again gets it through.
    static func isBlockedByLocalChanges(_ error: Error) -> Bool {
        guard let gitError = error as? GitError else { return false }
        switch GitFailure(output: gitError.stderr) {
        case .localChangesInTheWay, .uncommittedChanges: return true
        default: return false
        }
    }

    /// A failure that changed nothing and asks for nothing: the server could not be reached, or a stash was already gone. A toast says so instead of a sheet.
    static func isPassing(_ error: Error) -> Bool {
        guard let gitError = error as? GitError else { return false }
        return GitFailure(output: gitError.stderr) == .unreachable || gitError.stderr.contains("is no longer in the stash list")
    }

    /// git's output as a terminal would show it, or nil when it says nothing beyond the summary.
    static func details(of error: Error) -> String? {
        guard let gitError = error as? GitError else { return nil }
        let text = GitFailure.visibleText(gitError.stderr)
        return text.isEmpty ? nil : text
    }

    /// The toast for what a rebase, cherry-pick or revert reported besides its result, or nil.
    static func toast(for report: OperationReport?) -> RefString? {
        guard let report else { return nil }
        let skipped = report.alreadyApplied
        switch (skipped > 0, report.skippedEmptyStep) {
        case (true, true): return RefString(LocalizedStringResource("rebase.skipped.commitsAndEmptyStep", defaultValue: "Skipped \(skipped) already applied commits and an empty step", bundle: .module))
        case (true, false): return RefString(LocalizedStringResource("rebase.skipped.commits", defaultValue: "Skipped \(skipped) already applied commits", bundle: .module))
        case (false, true): return RefString(LocalizedStringResource("rebase.skipped.emptyStep", defaultValue: "Skipped an empty step", bundle: .module))
        case (false, false): return nil
        }
    }

    /// Longer lists name the first few paths and count the rest.
    private static let shownPaths = 3

    private static func listed(_ paths: [String]) -> String {
        RefName.paths(Array(paths.prefix(shownPaths)), separator: ", ")
    }
}
