import Foundation

public struct LogOptions: Sendable, Hashable {
    /// Branches, remote branches, tags and this worktree's HEAD, versus only HEAD.
    /// Other namespaces stay out: tools keep snapshots and backups under their own refs (`refs/codex/…`), and other worktrees' HEADs are theirs.
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

    static let historyRefs = ["--branches", "--remotes", "--tags"]

    var arguments: [String] { arguments(includingHead: true) }

    /// An unborn HEAD (no commit yet) would make git fail, so it is only named when it exists.
    func arguments(includingHead: Bool) -> [String] {
        var args = ["log", LogFormat.formatArgument]
        if topoOrder { args.append("--topo-order") }
        if allRefs { args.append(contentsOf: Self.historyRefs + (includingHead ? ["HEAD"] : [])) }
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

/// Facade over one repository (or one worktree of it). All methods map to one git command.
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

    /// Streams commits in the order git emits them (topological by default, children before parents).
    /// A repository without any commits yields an empty stream instead of git's "does not have any commits" error.
    public func log(_ options: LogOptions = LogOptions()) -> AsyncThrowingStream<Commit, Error> {
        let runner = runner
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = LogParser()
                do {
                    let headExists = await Self.headExists(runner)
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

    private static func headExists(_ runner: GitRunner) async -> Bool {
        (try? await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"])) != nil
    }

    public func refs() async throws -> [Ref] {
        let result = try await runner.run(["for-each-ref", RefsParser.formatArgument])
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
        let arguments: [String]
        if let parent = commit.parents.first {
            arguments = ["diff", "--name-status", "-M", "-z", parent, commit.id]
        } else {
            arguments = ["diff-tree", "-r", "--root", "--no-commit-id", "--name-status", "-M", "-z", commit.id]
        }
        async let names = runner.run(arguments)
        async let stats = commitStats(of: commit)
        let counted = (try? await stats) ?? [:]
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

    /// Total number of commits in the history: reachable from branches, remote branches, tags and this worktree's HEAD.
    public func commitCount() async throws -> Int {
        let result = try await runner.run(["rev-list"] + LogOptions.historyRefs + (await Self.headExists(runner) ? ["HEAD"] : []) + ["--count"])
        return Int(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Writes or refreshes the commit-graph file, which speeds up every log walk.
    public func writeCommitGraph() async throws {
        _ = try await runner.runWrite(["commit-graph", "write", "--reachable"])
    }
}
