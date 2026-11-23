import Foundation

extension Repository {
    /// The tags `remote` has, from `git ls-remote --tags`, keyed by name.
    /// git cannot prompt (`GIT_TERMINAL_PROMPT=0`); a remote that does not answer within `timeout` fails with `GitError.isTimeout`, so a caller never waits on the network.
    public func remoteTags(on remote: String, timeout: Duration = .seconds(10)) async throws -> [String: TagTarget] {
        let arguments = ["ls-remote", "--tags", remote]
        let output = try await Self.withTimeout(timeout, arguments: arguments) { [runner] in try await runner.run(arguments).stdout }
        return Self.parseRemoteTags(output)
    }

    /// Fetches one tag from `remote` and nothing else: `--no-tags` keeps git from following other tags along. An existing local tag of that name is not overwritten.
    public func fetchTag(_ name: String, from remote: String) async throws {
        _ = try await runner.runWithoutIndex(["fetch", "--no-tags", remote, "refs/tags/\(name):refs/tags/\(name)"])
    }

    /// Every local tag, whatever it points at, so that a tag of a tree is not taken for one that exists only on the remote.
    public func localTagTargets() async throws -> [String: TagTarget] {
        let format = "--format=%(refname:strip=2)%1f%(objectname)%1f%(*objectname)%1e"
        let result = try await runner.run(["for-each-ref", format, "refs/tags"])
        var targets: [String: TagTarget] = [:]
        for fields in FieldRecords.parse(result.stdout) {
            guard fields.count == 3 else { continue }
            let name = fields[0]
            guard !name.isEmpty else { continue }
            targets[name] = TagTarget(objectID: fields[1], commitID: fields[2].isEmpty ? fields[1] : fields[2])
        }
        return targets
    }

    /// `<object>\trefs/tags/<name>` per tag, followed by `<commit>\trefs/tags/<name>^{}` for an annotated one.
    static func parseRemoteTags(_ data: Data) -> [String: TagTarget] {
        var objects: [String: String] = [:]
        var peeled: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[1].hasPrefix("refs/tags/") else { continue }
            let id = String(parts[0])
            let name = parts[1].dropFirst("refs/tags/".count)
            if name.hasSuffix("^{}") {
                peeled[String(name.dropLast(3))] = id
            } else {
                objects[String(name)] = id
            }
        }
        return objects.reduce(into: [:]) { targets, entry in
            targets[entry.key] = TagTarget(objectID: entry.value, commitID: peeled[entry.key] ?? entry.value)
        }
    }

    /// Tags are the same when their refs name the same object; for annotated tags that is the tag object, so a tag recreated on the same commit still differs.
    public static func compareTags(local: [String: TagTarget], remote: [String: TagTarget]) -> [String: TagSyncState] {
        var states: [String: TagSyncState] = [:]
        for (name, target) in local {
            if let remoteTarget = remote[name] {
                states[name] = remoteTarget.objectID == target.objectID ? .same : .differs(local: target, remote: remoteTarget)
            } else {
                states[name] = .localOnly
            }
        }
        for (name, target) in remote where local[name] == nil {
            states[name] = .remoteOnly(target)
        }
        return states
    }

    /// Returns as soon as the operation finishes or the time is up. A git that does not stop on cancellation, an ssh still holding its pipes for instance, is left to finish on its own.
    static func withTimeout<T: Sendable>(_ timeout: Duration, arguments: [String], _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let work = Task { try await operation() }
        let gate = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.set(continuation)
            let timer = Task {
                try await Task.sleep(for: timeout)
                work.cancel()
                gate.resume(with: .failure(GitError(arguments: arguments, exitCode: GitError.timeoutExitCode, stderr: "no answer within \(timeout)")))
            }
            Task {
                let result = await work.result
                timer.cancel()
                gate.resume(with: result)
            }
        }
    }
}

extension GitError {
    static let timeoutExitCode: Int32 = -2

    /// The command was stopped because it did not finish in time.
    public var isTimeout: Bool { exitCode == Self.timeoutExitCode }
}

/// Resumes a continuation once, whichever of several racing tasks gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with result: Result<T, Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}
