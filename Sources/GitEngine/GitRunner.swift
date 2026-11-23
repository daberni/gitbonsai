import Foundation
import Synchronization

public struct GitError: Error, Sendable, CustomStringConvertible {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String

    public init(arguments: [String], exitCode: Int32, stderr: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stderr = stderr
    }

    public var description: String { "git \(arguments.joined(separator: " ")) failed (\(exitCode)): \(stderr)" }
}

public struct GitCommandResult: Sendable {
    public let arguments: [String]
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval

    public init(arguments: [String], stdout: Data, stderr: String, exitCode: Int32, duration: TimeInterval) {
        self.arguments = arguments
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }

    /// The same result with stdout and stderr cut to their first `limit` bytes.
    func truncated(to limit: Int) -> GitCommandResult {
        guard stdout.count > limit || stderr.utf8.count > limit else { return self }
        let error = stderr.utf8.count > limit ? String(decoding: stderr.utf8.prefix(limit), as: UTF8.self) : stderr
        return GitCommandResult(arguments: arguments, stdout: stdout.prefix(limit), stderr: error, exitCode: exitCode, duration: duration)
    }
}

/// One record of the command log: every git invocation the app makes is visible to the user.
public struct GitCommandLogEntry: Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let result: GitCommandResult

    public init(id: UUID = UUID(), startedAt: Date, result: GitCommandResult) {
        self.id = id
        self.startedAt = startedAt
        self.result = result
    }
}

/// Runs the native `git` binary for one repository.
///
/// Reads may run concurrently. Writes, and reads that git may turn into an index write, are serialized per working tree through `IndexLockQueue`. Every invocation gets
/// `GIT_TERMINAL_PROMPT=0` and neutralizing `-c` options so user configuration cannot change the
/// machine-readable output formats the parsers rely on.
public actor GitRunner {
    public nonisolated let gitPath: String
    public nonisolated let repositoryPath: String

    /// Commands that are not allowed to prompt and must not take optional locks.
    public static let readEnvironment: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    ]
    public static let writeEnvironment: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
    ]
    /// Prepended to every argument list.
    public static let baseArguments: [String] = [
        "-c", "core.quotepath=off",
        "-c", "color.ui=never",
        "-c", "log.showSignature=false",
    ]

    public static let commandLogCapacity = 500

    private var log: [GitCommandLogEntry] = []
    /// Shared with every other runner of the same working tree, so that a second tab or a view model that just moved to another worktree cannot write next to this one.
    private nonisolated let indexQueue: IndexLockQueue

    public init(repositoryPath: String, gitPath: String = GitRunner.defaultGitPath()) {
        self.repositoryPath = repositoryPath
        self.gitPath = gitPath
        self.indexQueue = IndexLockQueue.shared(for: repositoryPath)
    }

    private static let preferredPath = Mutex<String?>(nil)

    /// A git binary chosen by the app's user. Runners created afterwards use it unless `GIT_BONSAI_GIT` names another; nil or empty finds one automatically.
    public static var preferredGitPath: String? {
        get { preferredPath.withLock { $0 } }
        set { preferredPath.withLock { $0 = newValue?.isEmpty == true ? nil : newValue } }
    }

    /// Resolves `git` from `GIT_BONSAI_GIT`, then `preferredGitPath`, then `automaticGitPath()`.
    public static func defaultGitPath() -> String {
        if let override = ProcessInfo.processInfo.environment["GIT_BONSAI_GIT"], !override.isEmpty {
            return override
        }
        if let preferred = preferredGitPath {
            return preferred
        }
        return automaticGitPath()
    }

    /// The first git in the common Homebrew and Xcode locations, which is what an empty preference means.
    public static func automaticGitPath() -> String {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }

    /// The version of the git binary at `gitPath`, from `git --version`.
    public static func version(ofGitAt gitPath: String) async throws -> GitVersion {
        let result = try await GitRunner(repositoryPath: NSTemporaryDirectory(), gitPath: gitPath).run(["--version"])
        guard let version = GitVersion(versionOutput: result.stdoutString) else {
            throw GitError(arguments: result.arguments, exitCode: result.exitCode, stderr: result.stderr.isEmpty ? result.stdoutString : result.stderr)
        }
        return version
    }

    /// Runs a read-only command to completion. Throws `GitError` on an exit code outside `accepting`;
    /// `git diff --no-index` for instance exits with 1 when the files differ. `stdin` feeds filters such as `git patch-id`.
    public func run(_ arguments: [String], environment: [String: String] = [:], accepting exitCodes: Set<Int32> = [0], stdin: Data? = nil) async throws -> GitCommandResult {
        let startedAt = Date()
        let result = try await execute(arguments, environment: Self.readEnvironment.merging(environment) { $1 }, stdin: stdin)
        record(result, startedAt: startedAt)
        guard exitCodes.contains(result.exitCode) else {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// Runs a read-only command that compares the working tree with the index, such as `git diff` without `--cached`.
    /// git rewrites the index under `index.lock` when it finds stale stat information and ignores `GIT_OPTIONAL_LOCKS` there, so these reads wait for writes and writes wait for them.
    public func runRefreshingIndex(_ arguments: [String], accepting exitCodes: Set<Int32> = [0]) async throws -> GitCommandResult {
        let environment = Self.readEnvironment
        let startedAt = Date()
        let path = repositoryPath
        let result = try await indexQueue.enqueue {
            // Refreshing stale stat information rewrites the index, which the file watcher must not take for an outside change; other files changing meanwhile still count.
            WriteActivity.began(path, .indexRefresh)
            defer { WriteActivity.ended(path, .indexRefresh) }
            return try await self.execute(arguments, environment: environment, stdin: nil)
        }
        record(result, startedAt: startedAt)
        guard exitCodes.contains(result.exitCode) else {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// Runs a mutating command. Write commands on one working tree never overlap each other, whichever runner starts them.
    public func runWrite(_ arguments: [String], environment: [String: String] = [:], stdin: Data? = nil) async throws -> GitCommandResult {
        let mergedEnvironment = Self.writeEnvironment.merging(environment) { $1 }
        let startedAt = Date()
        let path = repositoryPath
        let result = try await indexQueue.enqueue {
            WriteActivity.began(path)
            defer { WriteActivity.ended(path) }
            return try await self.execute(arguments, environment: mergedEnvironment, stdin: stdin)
        }
        record(result, startedAt: startedAt)
        guard result.exitCode == 0 else {
            // Some commands, `git stash pop` with a conflict among them, explain the failure only on stdout.
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.stdoutString : result.stderr
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: message)
        }
        return result
    }

    /// Runs a mutating command that changes refs or the remote but never the index or the working tree, such as `git fetch`, `git push` or `git tag`.
    /// It does not wait in the working tree's write queue, so a slow remote cannot hold up staging; the file watcher still takes its ref changes for the app's own.
    public func runWithoutIndex(_ arguments: [String], environment: [String: String] = [:]) async throws -> GitCommandResult {
        let startedAt = Date()
        let path = repositoryPath
        WriteActivity.began(path)
        defer { WriteActivity.ended(path) }
        let result = try await execute(arguments, environment: Self.writeEnvironment.merging(environment) { $1 }, stdin: nil)
        record(result, startedAt: startedAt)
        guard result.exitCode == 0 else { throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr) }
        return result
    }

    /// Runs a command that creates its own repository, such as `git clone`, outside of any write queue; `onStderr` sees git's progress as it arrives.
    public func runCreating(_ arguments: [String], onStderr: @escaping @Sendable (Data) -> Void) async throws -> GitCommandResult {
        let startedAt = Date()
        let result = try await execute(arguments, environment: Self.writeEnvironment, stdin: nil, onStderr: onStderr)
        record(result, startedAt: startedAt)
        guard result.exitCode == 0 else { throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr) }
        return result
    }

    /// Streams stdout chunks of a read-only command as they arrive. The stream finishes with
    /// `GitError` when git exits non-zero, and cancelling the consuming task terminates git.
    public nonisolated func stream(_ arguments: [String], environment: [String: String] = [:]) -> AsyncThrowingStream<Data, Error> {
        let execution = ProcessExecution(
            gitPath: gitPath,
            arguments: Self.baseArguments + arguments,
            environment: Self.readEnvironment.merging(environment) { $1 },
            directory: repositoryPath,
            stdin: nil
        )
        let startedAt = Date()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in execution.terminate() }
            Task {
                do {
                    let outcome = try await execution.run { chunk in continuation.yield(chunk) }
                    let result = GitCommandResult(arguments: arguments, stdout: Data(), stderr: outcome.stderr, exitCode: outcome.exitCode, duration: outcome.duration)
                    await self.record(result, startedAt: startedAt)
                    if outcome.exitCode == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: GitError(arguments: arguments, exitCode: outcome.exitCode, stderr: outcome.stderr))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Most recent invocations, newest last. Capped to a few hundred entries, each keeping at most `commandLogOutputLimit` bytes of stdout and of stderr.
    public var commandLog: [GitCommandLogEntry] { log }

    /// A `cat-file blob` or a full-file diff can be many megabytes; the log keeps only their start.
    public static let commandLogOutputLimit = 16 * 1024

    private func record(_ result: GitCommandResult, startedAt: Date) {
        log.append(GitCommandLogEntry(startedAt: startedAt, result: result.truncated(to: Self.commandLogOutputLimit)))
        if log.count > Self.commandLogCapacity {
            log.removeFirst(log.count - Self.commandLogCapacity)
        }
    }

    private func execute(_ arguments: [String], environment: [String: String], stdin: Data?, onStderr: (@Sendable (Data) -> Void)? = nil) async throws -> GitCommandResult {
        let execution = ProcessExecution(
            gitPath: gitPath,
            arguments: Self.baseArguments + arguments,
            environment: environment,
            directory: repositoryPath,
            stdin: stdin
        )
        let collector = DataCollector()
        let outcome = try await execution.run(onStdout: { chunk in collector.append(chunk) }, onStderr: onStderr)
        return GitCommandResult(arguments: arguments, stdout: collector.data, stderr: outcome.stderr, exitCode: outcome.exitCode, duration: outcome.duration)
    }
}

/// Runs the commands that take one working tree's index lock one after another.
/// There is one queue per working tree path for the whole process; linked worktrees have their own index and their own queue.
actor IndexLockQueue {
    private static let queues = Mutex<[String: IndexLockQueue]>([:])

    static func shared(for path: String) -> IndexLockQueue {
        let key = RealPath.of(path)
        return queues.withLock { queues in
            if let queue = queues[key] { return queue }
            let queue = IndexLockQueue()
            queues[key] = queue
            return queue
        }
    }

    private var busy = false
    /// Callers waiting for the lock, first come first served.
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Runs `operation` once every earlier one has finished. A caller cancelled while it waits leaves the queue at once with `CancellationError`; its operation never starts.
    func enqueue<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.leave(id) }
        }
    }

    private func leave(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the lock straight to the next caller, so `busy` stays set.
    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }
}
