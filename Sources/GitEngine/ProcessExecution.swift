import Foundation

struct ProcessOutcome: Sendable {
    let exitCode: Int32
    let stderr: String
    let duration: TimeInterval
}

/// One git process. Stdout and stderr are drained on dedicated threads so large output never deadlocks the pipes.
///
/// git runs as the leader of its own process group, so stopping it also stops what it started: ssh, credential and remote helpers, hooks.
final class ProcessExecution: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let directory: String
    private let stdin: Data?
    private let lock = NSLock()
    private var pid: pid_t?
    private var reaped = false
    /// stdout and stderr not yet at end of file; a helper of git that outlives it keeps them open.
    private var openPipes = 2
    private var terminated = false

    /// How long a stopped git gets to clean up its lock files before the group is killed.
    static let killDelay: TimeInterval = 2

    init(gitPath: String, arguments: [String], environment: [String: String], directory: String, stdin: Data?) {
        self.executable = gitPath
        self.arguments = arguments
        self.environment = Self.environment(inherited: ProcessInfo.processInfo.environment, overrides: environment)
        self.directory = directory
        self.stdin = stdin
    }

    /// Variables a user sets on purpose for git: how to reach remotes, credentials, which config files to read, tracing.
    static let keptVariables: Set<String> = [
        "GIT_SSH", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT", "GIT_ASKPASS", "GIT_PROXY_COMMAND",
        "GIT_SSL_CAINFO", "GIT_SSL_CAPATH", "GIT_SSL_NO_VERIFY", "GIT_SSL_CERT", "GIT_SSL_KEY",
        "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM",
    ]
    static let keptPrefixes = ["GIT_TRACE", "GIT_CURL_", "GIT_LFS_"]

    /// The app's environment without the `GIT_*` variables that would point git at another repository or change what it writes.
    /// A hook or a parent git exports `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE`, `GIT_CONFIG_PARAMETERS` or author dates; an app or test started from there would inherit them.
    static func environment(inherited: [String: String], overrides: [String: String]) -> [String: String] {
        let kept = inherited.filter { name, _ in
            guard name.hasPrefix("GIT_") else { return true }
            return keptVariables.contains(name) || keptPrefixes.contains { name.hasPrefix($0) }
        }
        return kept.merging(overrides) { $1 }
    }

    /// Stops git and everything it started: SIGTERM first, which lets git remove its lock files, and SIGKILL for a group still running after `killDelay`.
    /// The group counts as running while git is unreaped or a member still holds its pipes, such as a helper that ignores SIGTERM or was forked as the signal went out; that member also keeps the group ID from being reused.
    func terminate() {
        let group: pid_t? = lock.withLock {
            terminated = true
            return groupRunning ? pid : nil
        }
        guard let group else { return }
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killDelay) { [self] in
            if lock.withLock({ groupRunning }) { kill(-group, SIGKILL) }
        }
    }

    /// Call with `lock` held.
    private var groupRunning: Bool { !reaped || openPipes > 0 }

    private func pipeClosed() {
        lock.withLock { openPipes -= 1 }
    }

    /// `onStderr` sees stderr as it arrives, for progress; stderr is collected for the outcome either way.
    /// Throws `CancellationError` when the task was cancelled or `terminate` ran, whether or not git had started.
    func run(onStdout: @escaping @Sendable (Data) -> Void, onStderr: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessOutcome {
        let start = Date()
        let stderrCollector = DataCollector()
        let status = try await withTaskCancellationHandler {
            try await spawnAndWait(onStdout: onStdout, onStderr: { chunk in
                stderrCollector.append(chunk)
                onStderr?(chunk)
            })
        } onCancel: {
            terminate()
        }
        if lock.withLock({ terminated }) { throw CancellationError() }
        return ProcessOutcome(exitCode: status, stderr: String(decoding: stderrCollector.data, as: UTF8.self), duration: Date().timeIntervalSince(start))
    }

    private func spawnAndWait(onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        let output = try PipePair.make()
        let errors = try PipePair.make()
        let input = try PipePair.make()
        let spawned: pid_t
        do {
            spawned = try launch(stdin: input.read, stdout: output.write, stderr: errors.write)
        } catch {
            for fd in [output.read, output.write, errors.read, errors.write, input.read, input.write] { close(fd) }
            throw error
        }
        close(output.write)
        close(errors.write)
        close(input.read)

        let group = DispatchGroup()
        let exitStatus = ExitStatus()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(output.read, onStdout)
            self.pipeClosed()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(errors.read, onStderr)
            self.pipeClosed()
            group.leave()
        }
        let payload = stdin
        DispatchQueue.global(qos: .userInitiated).async {
            if let payload { Self.write(payload, to: input.write) }
            close(input.write)
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var status: Int32 = 0
            while waitpid(spawned, &status, 0) == -1, errno == EINTR {}
            lock.withLock { reaped = true }
            exitStatus.value = Self.exitCode(status)
            group.leave()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        return exitStatus.value
    }

    /// Starts git unless `terminate` already ran, which happens when the consumer cancels before the process starts.
    private func launch(stdin: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three standard descriptors reach git; signals start from their defaults, unblocked.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        lock.lock()
        defer { lock.unlock() }
        if terminated { throw CancellationError() }
        var spawned: pid_t = 0
        let result = posix_spawn(&spawned, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        pid = spawned
        return spawned
    }

    /// The exit code, or 128 plus the signal for a process a signal ended, as a shell reports it.
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func drain(_ fd: Int32, _ sink: (Data) -> Void) {
        let size = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer {
            buffer.deallocate()
            close(fd)
        }
        while true {
            let count = read(fd, buffer, size)
            if count > 0 {
                sink(Data(bytes: buffer, count: count))
            } else if count == 0 || errno != EINTR {
                break
            }
        }
    }

    /// A git that exits without reading its input closes the pipe; the write then fails with EPIPE instead of a signal.
    private static func write(_ data: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Foundation.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }
}

private final class ExitStatus: @unchecked Sendable {
    var value: Int32 = 0
}

private enum PipePair {
    /// Both ends close on exec, so a git started meanwhile on another thread cannot inherit them and hold the pipe open.
    static func make() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
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
