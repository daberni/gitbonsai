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

    /// A checkout that git refused because tracked edits or untracked files in the working tree would be overwritten.
    public var isBlockedByLocalChanges: Bool { stderr.contains("would be overwritten by checkout") }
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
/// Reads may run concurrently; writes are serialized through `runWrite`. Every invocation gets
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
    /// Tail of the write chain; each write waits for the previous one before launching git.
    private var writeTail: Task<Void, Never>?

    public init(repositoryPath: String, gitPath: String = GitRunner.defaultGitPath()) {
        self.repositoryPath = repositoryPath
        self.gitPath = gitPath
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
        let arguments = ["--version"]
        let execution = ProcessExecution(gitPath: gitPath, arguments: arguments, environment: readEnvironment, directory: NSTemporaryDirectory(), stdin: nil)
        let collector = DataCollector()
        let outcome = try await execution.run { chunk in collector.append(chunk) }
        let output = String(decoding: collector.data, as: UTF8.self)
        guard outcome.exitCode == 0, let version = GitVersion(versionOutput: output) else {
            throw GitError(arguments: arguments, exitCode: outcome.exitCode, stderr: outcome.stderr.isEmpty ? output : outcome.stderr)
        }
        return version
    }

    /// Runs a read-only command to completion. Throws `GitError` on an exit code outside `accepting`;
    /// `git diff --no-index` for instance exits with 1 when the files differ.
    public func run(_ arguments: [String], environment: [String: String] = [:], accepting exitCodes: Set<Int32> = [0]) async throws -> GitCommandResult {
        let startedAt = Date()
        let result = try await execute(arguments, environment: Self.readEnvironment.merging(environment) { $1 }, stdin: nil)
        record(result, startedAt: startedAt)
        guard exitCodes.contains(result.exitCode) else {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// Runs a mutating command. Write commands never overlap each other.
    public func runWrite(_ arguments: [String], environment: [String: String] = [:], stdin: Data? = nil) async throws -> GitCommandResult {
        let previous = writeTail
        let mergedEnvironment = Self.writeEnvironment.merging(environment) { $1 }
        let task = Task { () throws -> GitCommandResult in
            await previous?.value
            return try await self.execute(arguments, environment: mergedEnvironment, stdin: stdin)
        }
        writeTail = Task { _ = try? await task.value }
        let startedAt = Date()
        let result = try await task.value
        record(result, startedAt: startedAt)
        guard result.exitCode == 0 else {
            // Some commands, `git stash pop` with a conflict among them, explain the failure only on stdout.
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.stdoutString : result.stderr
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: message)
        }
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

    /// Most recent invocations, newest last. Capped to a few hundred entries.
    public var commandLog: [GitCommandLogEntry] { log }

    private func record(_ result: GitCommandResult, startedAt: Date) {
        log.append(GitCommandLogEntry(startedAt: startedAt, result: result))
        if log.count > Self.commandLogCapacity {
            log.removeFirst(log.count - Self.commandLogCapacity)
        }
    }

    private func execute(_ arguments: [String], environment: [String: String], stdin: Data?) async throws -> GitCommandResult {
        let execution = ProcessExecution(
            gitPath: gitPath,
            arguments: Self.baseArguments + arguments,
            environment: environment,
            directory: repositoryPath,
            stdin: stdin
        )
        let collector = DataCollector()
        let outcome = try await execution.run { chunk in collector.append(chunk) }
        return GitCommandResult(arguments: arguments, stdout: collector.data, stderr: outcome.stderr, exitCode: outcome.exitCode, duration: outcome.duration)
    }
}

/// Thread-safe accumulator for pipe output arriving on reader threads.
final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

struct ProcessOutcome: Sendable {
    let exitCode: Int32
    let stderr: String
    let duration: TimeInterval
}

/// One git process. Stdout and stderr are drained on dedicated threads so large output never deadlocks the pipes.
final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let stdin: Data?
    private let lock = NSLock()
    private var started = false
    private var terminated = false

    init(gitPath: String, arguments: [String], environment: [String: String], directory: String, stdin: Data?) {
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        self.stdin = stdin
    }

    func terminate() {
        lock.lock()
        terminated = true
        let running = started && process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    func run(onStdout: @escaping @Sendable (Data) -> Void) async throws -> ProcessOutcome {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = stdinPipe ?? Pipe()
        if stdinPipe == nil { (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile() }

        let stderrCollector = DataCollector()
        let group = DispatchGroup()
        let start = Date()

        group.enter()
        process.terminationHandler = { _ in group.leave() }

        try launch()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(stdoutPipe.fileHandleForReading, onStdout)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(stderrPipe.fileHandleForReading) { stderrCollector.append($0) }
            group.leave()
        }
        if let stdin, let stdinPipe {
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) { continuation.resume() }
            }
        } onCancel: {
            terminate()
        }

        return ProcessOutcome(
            exitCode: process.terminationStatus,
            stderr: String(decoding: stderrCollector.data, as: UTF8.self),
            duration: Date().timeIntervalSince(start)
        )
    }

    /// Starts git unless `terminate` already ran, which happens when the consumer cancels before the stream starts.
    private func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if terminated { throw CancellationError() }
        try process.run()
        started = true
    }

    private static func drain(_ handle: FileHandle, _ sink: (Data) -> Void) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            sink(chunk)
        }
        try? handle.close()
    }
}
