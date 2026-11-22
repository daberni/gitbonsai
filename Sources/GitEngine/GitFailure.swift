import Foundation

/// What a failed git command says, read from its output so the app can name it in one sentence. git's own text stays available as the details.
/// Reads the `LC_ALL=C` messages of git ≥ 2.38; `hint:` lines and the repeated "Could not apply" line are ignored.
public enum GitFailure: Sendable, Equatable {
    /// A rebase or cherry-pick step did not apply; `subject` is empty when git did not name it.
    case couldNotApply(commit: String, subject: String)
    case couldNotRevert(commit: String, subject: String)
    /// A merge stopped with conflicts in these paths.
    case conflicts([String])
    /// Checkout, merge or reset would overwrite local changes or untracked files in these paths.
    case localChangesInTheWay([String])
    /// A rebase refused to start over uncommitted changes.
    case uncommittedChanges
    /// The step became empty, so there is nothing to commit.
    case emptyStep
    /// The remote wanted credentials that neither a credential helper nor the SSH agent supplied; git may not ask for them.
    case authenticationFailed
    /// The remote's host could not be reached: no network, an unknown host, a refused or timed-out connection.
    case unreachable
    /// Anything else: git's first `fatal:` or `error:` line, or its first line.
    case message(String)

    public init(output: String) {
        let lines = Self.visibleLines(output).filter { !$0.hasPrefix("hint:") }
        if let failure = Self.step(in: lines, marker: "could not apply ", make: GitFailure.couldNotApply) ?? Self.step(in: lines, marker: "could not revert ", make: GitFailure.couldNotRevert) {
            self = failure
        } else if let index = lines.firstIndex(where: { $0.contains("would be overwritten by") }) {
            self = .localChangesInTheWay(lines[(index + 1)...].prefix { $0.hasPrefix("\t") || $0.hasPrefix("    ") }.map { $0.trimmingCharacters(in: .whitespaces) })
        } else if lines.contains(where: { $0.contains("You have unstaged changes") || $0.contains("Your index contains uncommitted changes") }) {
            self = .uncommittedChanges
        } else if lines.contains(where: { $0.contains("is now empty") || $0.hasPrefix("nothing to commit") || $0.hasPrefix("No changes - did you forget") }) {
            self = .emptyStep
        } else if lines.contains(where: Self.isAuthenticationFailure) {
            self = .authenticationFailed
        } else if lines.contains(where: Self.isUnreachable) {
            self = .unreachable
        } else if case let conflicted = lines.compactMap(Self.conflictPath), !conflicted.isEmpty {
            self = .conflicts(conflicted)
        } else if let line = lines.first(where: { $0.hasPrefix("fatal: ") || $0.hasPrefix("error: ") }) {
            self = .message(String(line.drop { $0 != " " }.dropFirst()))
        } else {
            self = .message(lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "")
        }
    }

    /// HTTPS without stored credentials ends in "terminal prompts disabled" or "Authentication failed"; SSH without a usable key in "Permission denied (publickey)".
    private static func isAuthenticationFailure(_ line: String) -> Bool {
        let markers = ["terminal prompts disabled", "Authentication failed for", "could not read Username", "could not read Password", "Permission denied (publickey", "Host key verification failed"]
        return markers.contains { line.contains($0) }
    }

    /// curl's, ssh's and the resolver's words for a host that does not answer, as opposed to a refused login or a remote path that is not a repository.
    public static func isUnreachable(_ text: String) -> Bool {
        let markers = ["could not resolve host", "temporary failure in name resolution", "connection refused", "network is unreachable", "no route to host", "timed out", "failed to connect", "connection reset by peer"]
        let lowercased = text.lowercased()
        return markers.contains { lowercased.contains($0) }
    }

    /// Lines as a terminal leaves them: progress overwrites itself with carriage returns, so only the last part of each line stays.
    public static func visibleLines(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.split(separator: "\r").last.map(String.init) ?? "" }
    }

    /// git's output with carriage-return progress collapsed and surrounding blank lines removed.
    public static func visibleText(_ output: String) -> String {
        visibleLines(output).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "error: could not apply 1a2b3c4... Subject" names the commit and its subject.
    private static func step(in lines: [String], marker: String, make: (String, String) -> GitFailure) -> GitFailure? {
        guard let line = lines.first(where: { $0.hasPrefix("error: \(marker)") }) else { return nil }
        let rest = line.dropFirst("error: \(marker)".count)
        let sha = rest.prefix { $0 != "." && $0 != " " }
        let subject = rest.dropFirst(sha.count).drop { $0 == "." || $0 == " " }
        return make(String(sha), String(subject))
    }

    /// "CONFLICT (content): Merge conflict in <path>" and its kin name the path after " in " or at the end.
    private static func conflictPath(_ line: String) -> String? {
        guard line.hasPrefix("CONFLICT") else { return nil }
        if let range = line.range(of: "Merge conflict in ") { return String(line[range.upperBound...]) }
        return line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// What a rebase, cherry-pick or revert reported besides succeeding or stopping, for a quiet line in the status bar.
public struct OperationReport: Sendable, Equatable {
    /// Commits a rebase left out because their changes are already on the new base.
    public var alreadyApplied: Int
    /// Continuing found the step empty after the conflict resolution and skipped it.
    public var skippedEmptyStep: Bool

    public init(alreadyApplied: Int = 0, skippedEmptyStep: Bool = false) {
        self.alreadyApplied = alreadyApplied
        self.skippedEmptyStep = skippedEmptyStep
    }

    /// Counts git's "skipped previously applied commit" warnings and the "-- patch contents already upstream" lines of `--empty=drop`.
    public init(output: String) {
        let lines = GitFailure.visibleLines(output)
        let skipped = Set(lines.compactMap { line -> String? in
            if line.hasPrefix("warning: skipped previously applied commit ") { return String(line.dropFirst("warning: skipped previously applied commit ".count)) }
            if line.hasPrefix("dropping "), line.hasSuffix("-- patch contents already upstream") { return line.split(separator: " ").dropFirst().first.map(String.init) }
            return nil
        })
        self.init(alreadyApplied: skipped.count)
    }
}
