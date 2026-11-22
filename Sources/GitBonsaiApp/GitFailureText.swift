import AppKit
import GitEngine

/// The app's words for a failed git command: one sentence of what happened, with git's own output kept as details.
enum GitFailureText {
    /// "Commit 11f8174 “Add an ETP tab” could not be applied.", the commit as a pill; the subject is prose and keeps its quotes.
    static func summary(of error: Error) -> RefString {
        guard let gitError = error as? GitError else { return RefString(verbatim: error.localizedDescription) }
        let resource: LocalizedStringResource
        switch GitFailure(output: gitError.stderr) {
        case let .couldNotApply(commit, subject) where subject.isEmpty: resource = "Commit \(RefName.commit(commit)) could not be applied."
        case let .couldNotApply(commit, subject): resource = "Commit \(RefName.commit(commit)) “\(subject)” could not be applied."
        case let .couldNotRevert(commit, subject) where subject.isEmpty: resource = "Commit \(RefName.commit(commit)) could not be reverted."
        case let .couldNotRevert(commit, subject): resource = "Commit \(RefName.commit(commit)) “\(subject)” could not be reverted."
        case let .conflicts(paths) where paths.count > shownPaths: resource = "Conflicts in \(listed(paths)) and \(paths.count - shownPaths) more."
        case let .conflicts(paths): resource = "Conflicts in \(listed(paths))."
        case let .localChangesInTheWay(paths) where paths.isEmpty: resource = "Local changes would be overwritten."
        case let .localChangesInTheWay(paths) where paths.count > shownPaths: resource = "Local changes would be overwritten: \(listed(paths)) and \(paths.count - shownPaths) more."
        case let .localChangesInTheWay(paths): resource = "Local changes would be overwritten: \(listed(paths))."
        case .uncommittedChanges: resource = "Uncommitted changes are in the way; commit or stash them first."
        case .emptyStep: resource = "The step is empty; there is nothing to commit."
        case .unreachable: resource = "The server cannot be reached. Check the network connection and the remote address."
        case .authenticationFailed: resource = "Signing in to the server failed. GitBonsai does not ask for passwords: store the credentials in the credential helper or load the SSH key into the SSH agent."
        case let .message(text) where text.isEmpty: resource = "git reports an error (exit code \(Int(gitError.exitCode)))."
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
        case (true, true): return RefString("Skipped \(skipped) already applied commits and an empty step")
        case (true, false): return RefString("Skipped \(skipped) already applied commits")
        case (false, true): return RefString("Skipped an empty step")
        case (false, false): return nil
        }
    }

    /// Longer lists name the first few paths and count the rest.
    private static let shownPaths = 3

    private static func listed(_ paths: [String]) -> String {
        RefName.paths(Array(paths.prefix(shownPaths)), separator: ", ")
    }
}
