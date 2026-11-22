import Foundation

public struct LogOptions: Sendable, Hashable {
    /// `--all` (every ref) versus only HEAD.
    public var allRefs: Bool = true
    public var topoOrder: Bool = true
    public var limit: Int? = nil
    public var skip: Int? = nil
    public var grep: String? = nil
    public var author: String? = nil
    public var paths: [String] = []
    /// Passed through verbatim after the options and before `--`. For `-S`, `-G`, `--since`, revision ranges.
    public var extraArguments: [String] = []

    public init() {}

    var arguments: [String] {
        var args = ["log", LogFormat.formatArgument]
        if topoOrder { args.append("--topo-order") }
        if allRefs { args.append("--all") }
        if let limit { args.append("-n\(limit)") }
        if let skip { args.append("--skip=\(skip)") }
        if let grep { args.append("--grep=\(grep)") }
        if let author { args.append("--author=\(author)") }
        args.append(contentsOf: extraArguments)
        if !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: paths)
        }
        return args
    }
}

/// Facade over one repository (or one worktree of it). All methods map to one git command.
public final class Repository: Sendable {
    public let path: String
    public let runner: GitRunner

    public init(path: String, gitPath: String = GitRunner.defaultGitPath()) {
        self.path = path
        self.runner = GitRunner(repositoryPath: path, gitPath: gitPath)
    }

    /// Root of the working tree that contains `path`, which may be any folder inside it. Throws `GitError` when the folder is not inside a repository.
    public static func root(containing path: String, gitPath: String = GitRunner.defaultGitPath()) async throws -> String {
        let result = try await GitRunner(repositoryPath: path, gitPath: gitPath).run(["rev-parse", "--show-toplevel"])
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Streams commits in the order git emits them (topological by default, children before parents).
    /// A repository without any commits yields an empty stream instead of git's "does not have any commits" error.
    public func log(_ options: LogOptions = LogOptions()) -> AsyncThrowingStream<Commit, Error> {
        let chunks = runner.stream(options.arguments)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = LogParser()
                do {
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

    public func refs() async throws -> [Ref] {
        let result = try await runner.run(["for-each-ref", RefsParser.formatArgument])
        return try RefsParser.parse(result.stdout)
    }

    public func status() async throws -> RepositoryStatus {
        let result = try await runner.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
        return try StatusParser.parse(result.stdout)
    }

    /// All stashes, newest first. Stash commits are not reachable from any branch, so callers that
    /// want them in the graph pass their ids as extra revisions to `log`.
    public func stashes() async throws -> [Stash] {
        let result = try await runner.run(["stash", "list", "--format=%gd%x1f%H%x1f%gs%x1e"])
        return result.stdout.split(separator: 0x1E).compactMap { record in
            let fields = record.split(separator: 0x1F, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 3 else { return nil }
            let selector = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            return Stash(selector: selector, commitID: fields[1], message: fields[2].trimmingCharacters(in: .newlines))
        }
    }

    public func worktrees() async throws -> [Worktree] {
        let result = try await runner.run(["worktree", "list", "--porcelain", "-z"])
        return try WorktreeParser.parse(result.stdout)
    }

    /// Files a commit changed relative to its first parent (a root commit is compared with the empty tree).
    public func changedFiles(of commit: Commit) async throws -> [ChangedFile] {
        let arguments: [String]
        if let parent = commit.parents.first {
            arguments = ["diff", "--name-status", "-M", "-z", parent, commit.id]
        } else {
            arguments = ["diff-tree", "-r", "--root", "--no-commit-id", "--name-status", "-M", "-z", commit.id]
        }
        let result = try await runner.run(arguments)
        return Self.parseNameStatus(result.stdout)
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

    /// Total number of commits reachable from all refs (`rev-list --all --count`).
    public func commitCount() async throws -> Int {
        let result = try await runner.run(["rev-list", "--all", "--count"])
        return Int(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Writes or refreshes the commit-graph file, which speeds up every log walk.
    public func writeCommitGraph() async throws {
        _ = try await runner.runWrite(["commit-graph", "write", "--reachable"])
    }
}
