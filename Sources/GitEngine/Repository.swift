import Foundation

/// How the history sorts commits that do not depend on each other; every order lists a commit before its parents.
public enum HistoryOrder: String, Sendable, Hashable, CaseIterable {
    /// Newest commit date first across branches (`--date-order`).
    case date
    /// Newest author date first across branches (`--author-date-order`); differs from `date` after rebases, amends and cherry-picks.
    case authorDate
    /// Each line of development kept together (`--topo-order`).
    case branchesTogether

    var argument: String {
        switch self {
        case .date: "--date-order"
        case .authorDate: "--author-date-order"
        case .branchesTogether: "--topo-order"
        }
    }
}

public struct LogOptions: Sendable, Hashable {
    /// The history is branches, remote branches, tags and this worktree's HEAD.
    /// Other namespaces stay out: tools keep snapshots and backups under their own refs (`refs/codex/…`), and other worktrees' HEADs are theirs.
    public var limit: Int? = nil
    public var order: HistoryOrder = .date
    /// Passed through verbatim after the options and before `--`. For `-S`, `-G`, `--since`, revision ranges.
    public var extraArguments: [String] = []

    public init() {}

    static let historyRefs = ["--branches", "--remotes", "--tags"]

    /// An unborn HEAD (no commit yet) would make git fail, so it is only named when it exists.
    func arguments(includingHead: Bool) -> [String] {
        ["log", LogFormat.formatArgument] + selection(includingHead: includingHead)
    }

    /// The same commits in the same order, as bare IDs from `git rev-list`.
    func revListArguments(includingHead: Bool) -> [String] {
        ["rev-list"] + selection(includingHead: includingHead)
    }

    private func selection(includingHead: Bool) -> [String] {
        var args = [order.argument] + Self.historyRefs + (includingHead ? ["HEAD"] : [])
        if let limit { args.append("-n\(limit)") }
        args.append(contentsOf: extraArguments)
        return args
    }
}

/// A working tree and the repository it belongs to, which linked worktrees share.
public struct RepositoryLocation: Sendable, Equatable {
    public let root: String
    /// The directory git keeps the repository in, shared by all its worktrees.
    public let commonDirectory: String

    public init(root: String, commonDirectory: String) {
        self.root = root
        self.commonDirectory = commonDirectory
    }

    /// The folder of the main worktree, whichever worktree `root` is. A submodule keeps its repository under the superproject's `.git/modules` and is named by that directory.
    public var name: String {
        let common = URL(fileURLWithPath: commonDirectory)
        return common.lastPathComponent == ".git" ? common.deletingLastPathComponent().lastPathComponent : common.lastPathComponent
    }
}

/// Facade over one repository (or one worktree of it). Every git call and parse of the engine goes through it.
public final class Repository: Sendable {
    public let path: String
    public let runner: GitRunner

    public init(path: String, gitPath: String = GitRunner.defaultGitPath()) {
        self.path = path
        self.runner = GitRunner(repositoryPath: path, gitPath: gitPath)
    }

    /// The working tree that contains `path`, which may be any folder inside it, and the repository it belongs to. Throws `GitError` when the folder is not inside a repository.
    public static func location(containing path: String, gitPath: String = GitRunner.defaultGitPath()) async throws -> RepositoryLocation {
        let arguments = ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]
        let result = try await GitRunner(repositoryPath: path, gitPath: gitPath).run(arguments)
        guard let location = parseLocation(result.stdout) else { throw GitError(arguments: arguments, exitCode: 0, stderr: "unexpected output: \(result.stdoutString)") }
        return location
    }

    static func parseLocation(_ data: Data) -> RepositoryLocation? {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        return RepositoryLocation(root: String(lines[0]), commonDirectory: String(lines[1]))
    }

    /// Streams commits in the order git emits them for `options.order`, always children before parents.
    /// A repository without any commits yields an empty stream instead of git's "does not have any commits" error.
    public func log(_ options: LogOptions = LogOptions()) -> AsyncThrowingStream<Commit, Error> {
        let runner = runner
        let repository = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = LogParser()
                do {
                    let headExists = await repository.revisionExists("HEAD")
                    let chunks = runner.stream(options.arguments(includingHead: headExists))
                    for try await chunk in chunks {
                        for commit in parser.feed(chunk) { continuation.yield(commit) }
                    }
                    for commit in parser.finish() { continuation.yield(commit) }
                    continuation.finish()
                } catch let error as GitError where error.stderr.contains("does not have any commits") {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Branches, remote branches, tags of commits and the stash. Tools keep snapshots under their own namespaces (`refs/codex/…`, `refs/jj/…`); those are no labels.
    public func refs() async throws -> [Ref] {
        let result = try await runner.run(["for-each-ref", RefsParser.formatArgument, "refs/heads", "refs/remotes", "refs/tags", "refs/stash"])
        return try RefsParser.parse(result.stdout)
    }

    public func status() async throws -> RepositoryStatus {
        let result = try await runner.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
        return try StatusParser.parse(result.stdout)
    }

    public func worktrees() async throws -> [Worktree] {
        let result = try await runner.run(["worktree", "list", "--porcelain", "-z"])
        return try WorktreeParser.parse(result.stdout)
    }

    /// Files a commit changed relative to its first parent (a root commit is compared with the empty tree).
    public func changedFiles(of commit: Commit) async throws -> [ChangedFile] {
        guard let parent = commit.parents.first else {
            return try await changedFiles(command: ["diff-tree", "-r", "--root", "--no-commit-id"], revisions: [commit.id])
        }
        return try await changedFiles(from: parent, to: commit.id)
    }

    /// Files that differ between two revisions, with their line counts.
    public func changedFiles(from base: String, to target: String) async throws -> [ChangedFile] {
        try await changedFiles(command: ["diff"], revisions: [base, target])
    }

    /// Names from `--name-status` with the line counts of `--numstat`, both from the same diff command; missing counts leave `stat` nil.
    private func changedFiles(command: [String], revisions: [String]) async throws -> [ChangedFile] {
        async let names = runner.run(command + ["--name-status", "-M", "-z"] + revisions)
        async let stats = runner.run(command + ["--numstat", "-M", "-z"] + revisions)
        let counted = (try? await DiffParser.parseNumstat(stats.stdout)) ?? [:]
        return Self.parseNameStatus(try await names.stdout).map { file in
            var file = file
            file.stat = counted[file.path]
            return file
        }
    }

    /// `--name-status -z`: `status NUL path NUL`, and for renames and copies `status NUL old NUL new NUL`.
    static func parseNameStatus(_ data: Data) -> [ChangedFile] {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
        var files: [ChangedFile] = []
        while let status = tokens.popFirst(), let first = tokens.popFirst() {
            let letter = status.first ?? "M"
            let state = FileState(rawValue: letter) ?? .modified
            if letter == "R" || letter == "C", let renamed = tokens.popFirst() {
                files.append(ChangedFile(path: renamed, originalPath: first, state: state))
            } else {
                files.append(ChangedFile(path: first, originalPath: nil, state: state))
            }
        }
        return files
    }

    /// The IDs of the history in the order the history's `git log` lists them, for the stash commits it adds. Cheaper than the log: no message is read.
    public func historyOrder(_ order: HistoryOrder, stashCommits: [String]) async throws -> [String] {
        var options = LogOptions()
        options.order = order
        options.extraArguments = stashCommits
        let result = try await runner.run(options.revListArguments(includingHead: await revisionExists("HEAD")))
        return result.stdoutString.split(separator: "\n").map(String.init)
    }
}
