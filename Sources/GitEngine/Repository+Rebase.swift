import Foundation

/// A rebase, cherry-pick, revert or merge that git has stopped in the middle of, waiting for the user.
public struct OperationProgress: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case rebase
        case cherryPick
        case revert
        case merge

        /// The git subcommand that runs and continues the operation.
        public var command: String {
            switch self {
            case .rebase: "rebase"
            case .cherryPick: "cherry-pick"
            case .revert: "revert"
            case .merge: "merge"
            }
        }

        /// A merge has no single commit to leave out, so git offers no `--skip` for it.
        public var canSkip: Bool { self != .merge }
    }

    public let kind: Kind
    /// The step git stopped at and the number of steps, counted from 1; nil where git does not record them (a single cherry-pick or revert).
    public let step: Int?
    public let total: Int?
    /// The branch being rebased, without `refs/heads/`; nil for a detached rebase and for cherry-pick and revert.
    public let branch: String?
    /// The commit a rebase replays onto.
    public let onto: String?
    /// The commit a cherry-pick or revert stopped at, or the commit a merge brings in.
    public let commit: String?

    public init(kind: Kind, step: Int?, total: Int?, branch: String?, onto: String?, commit: String?) {
        self.kind = kind
        self.step = step
        self.total = total
        self.branch = branch
        self.onto = onto
        self.commit = commit
    }
}

extension Repository {
    /// Replays the commits of `branch` after `oldBase` onto `newBase`: `git rebase --onto <newBase> <oldBase> <branch>`.
    /// A conflict stops git mid-rebase and is thrown; the rebase stays in progress.
    public func rebase(onto newBase: String, from oldBase: String, branch: String) async throws {
        _ = try await runner.runWrite(["rebase", "--onto", newBase, oldBase, branch])
    }

    /// The number of commits in `base..tip`, which a rebase from `base` moves.
    public func commitCount(from base: String, to tip: String) async throws -> Int {
        let result = try await runner.run(["rev-list", "--count", "\(base)..\(tip)"])
        return Int(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The full SHA of the commit `revision` names, or nil when it names none.
    public func resolveCommit(_ revision: String) async -> String? {
        guard !revision.isEmpty, !revision.hasPrefix("-"), let result = try? await runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(revision)^{commit}"]) else { return nil }
        let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Commits the resolved state and goes on with the next step. The commit message is taken as git prepared it.
    public func continueOperation(_ kind: OperationProgress.Kind) async throws {
        _ = try await runner.runWrite([kind.command, "--continue"], environment: ["GIT_EDITOR": "true"])
    }

    /// Leaves out the commit git stopped at and goes on with the next step.
    public func skipOperation(_ kind: OperationProgress.Kind) async throws {
        _ = try await runner.runWrite([kind.command, "--skip"], environment: ["GIT_EDITOR": "true"])
    }

    /// Ends the operation and puts the branch, the index and the working tree back where they were before it started.
    public func abortOperation(_ kind: OperationProgress.Kind) async throws {
        _ = try await runner.runWrite([kind.command, "--abort"])
    }

    /// The operation git is in the middle of in this worktree, or nil. Git keeps that state in the worktree's own git directory, which `--git-path` locates.
    public func operationInProgress() async -> OperationProgress? {
        let names = ["rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "MERGE_HEAD"]
        guard let result = try? await runner.run(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] }) else { return nil }
        let paths = result.stdoutString.split(separator: "\n").map(String.init)
        guard paths.count == names.count else { return nil }
        let location = Dictionary(uniqueKeysWithValues: zip(names, paths))
        return Self.readProgress(at: location)
    }

    static func readProgress(at location: [String: String]) -> OperationProgress? {
        func read(_ directory: String?, _ file: String) -> String? {
            guard let directory, let text = try? String(contentsOfFile: directory + "/" + file, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func exists(_ name: String) -> Bool { location[name].map { FileManager.default.fileExists(atPath: $0) } ?? false }
        // The merge backend counts in msgnum/end, the apply backend in next/last.
        for (name, stepFile, totalFile) in [("rebase-merge", "msgnum", "end"), ("rebase-apply", "next", "last")] where exists(name) {
            let directory = location[name]
            // rebase-apply also serves `git am`, which marks its runs with `applying`.
            if name == "rebase-apply", let directory, FileManager.default.fileExists(atPath: directory + "/applying") { continue }
            let head = read(directory, "head-name")
            let branch = head.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
            return OperationProgress(kind: .rebase, step: read(directory, stepFile).flatMap(Int.init), total: read(directory, totalFile).flatMap(Int.init), branch: branch, onto: read(directory, "onto"), commit: nil)
        }
        for (name, kind) in [("CHERRY_PICK_HEAD", OperationProgress.Kind.cherryPick), ("REVERT_HEAD", .revert), ("MERGE_HEAD", .merge)] where exists(name) {
            // MERGE_HEAD lists one commit per line, several for an octopus merge; the first names it.
            let commit = location[name].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
            return OperationProgress(kind: kind, step: nil, total: nil, branch: nil, onto: nil, commit: commit)
        }
        return nil
    }
}
