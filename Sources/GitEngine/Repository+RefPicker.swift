import Foundation

extension Repository {
    /// Local branches, remote branches and tags with the commit each points to.
    public func refTips() async throws -> [RefTip] {
        let result = try await runner.run(["for-each-ref", RefTipsParser.formatArgument, "refs/heads", "refs/remotes", "refs/tags"])
        return RefTipsParser.parse(result.stdout)
    }

    /// The commit `revision` names, such as a pasted SHA, or nil when it names none.
    public func commitSummary(_ revision: String) async -> CommitSummary? {
        guard !revision.isEmpty, !revision.hasPrefix("-") else { return nil }
        guard let result = try? await runner.run(["log", "-1", "--format=%H%x1f%ct%x1f%s", "--end-of-options", "\(revision)^{commit}", "--"]) else { return nil }
        let fields = result.stdoutString.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, let seconds = TimeInterval(fields[1]) else { return nil }
        return CommitSummary(sha: fields[0], date: Date(timeIntervalSince1970: seconds), subject: fields[2])
    }

    /// Whether git accepts `name` as the name of a new branch. `check-ref-format --branch` also expands shorthands such as `@{-1}`; only a name it returns unchanged counts.
    public func isValidBranchName(_ name: String) async -> Bool {
        guard !name.isEmpty, let result = try? await runner.run(["check-ref-format", "--branch", name]) else { return false }
        return result.stdoutString.trimmingCharacters(in: .newlines) == name
    }
}
