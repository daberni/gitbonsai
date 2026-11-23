import XCTest
@testable import GitEngine

/// A working-tree diff rewrites the index under `index.lock` when stat information is stale, whatever `GIT_OPTIONAL_LOCKS` says.
/// Running next to a checkout of the same working tree, from the same or another `Repository`, it must not make the checkout fail.
final class IndexLockTests: XCTestCase {
    func testWorkingTreeReadsDoNotBreakConcurrentCheckouts() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        for index in 0..<200 { try fixture.write("files/\(index).txt", "line \(index)\n") }
        try fixture.commit("base", file: "shared.txt", contents: "main\n")
        try fixture.git("switch", "-q", "-c", "other")
        try fixture.commit("other", file: "shared.txt", contents: "other\n")
        try fixture.git("switch", "-q", "main")

        let reader = Repository(path: fixture.path)
        let writer = Repository(path: fixture.path)
        var failures: [String] = []
        for round in 0..<30 {
            try touchTrackedFiles(in: fixture)
            let target = round.isMultiple(of: 2) ? "other" : "main"
            async let unstaged = reader.workingStats(staged: false)
            async let fileDiff = reader.diff(of: "files/0.txt", in: .unstaged)
            do {
                try await writer.checkout(.localBranch(target), stashMessage: "carried by the test")
            } catch {
                failures.append("round \(round): \(error)")
            }
            _ = try await (unstaged, fileDiff)
        }
        XCTAssertEqual(failures, [])
    }

    /// New modification times without content changes leave every index entry stat-dirty.
    private func touchTrackedFiles(in fixture: FixtureRepo) throws {
        let now = Date()
        for path in try fixture.git("ls-files").split(separator: "\n") {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.url.appendingPathComponent(String(path)).path)
        }
    }
}

/// Cancelling an action stops its git, with everything git started, and frees the working tree's write queue.
final class CancellationTests: XCTestCase {
    var fixture: FixtureRepo!

    override func setUpWithError() throws {
        fixture = try FixtureRepo(name: "cancel")
        try fixture.commit("one")
    }

    override func tearDown() {
        fixture.remove()
    }

    /// A pre-commit hook that records its shell's PID and then waits; the commit hangs until it is stopped.
    /// The PID file appears complete through a rename, so a reader never sees it empty. `waits` is the shell code that holds the hook.
    private func installHangingHook(waits: String = "sleep 30") throws -> URL {
        let pidFile = fixture.url.appendingPathComponent(".git/hook.pid")
        let hook = fixture.url.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho $$ > \"\(pidFile.path).tmp\" && mv \"\(pidFile.path).tmp\" \"\(pidFile.path)\"\n\(waits)\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        return pidFile
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else { throw XCTSkip("hook did not start") }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCancellingARunningWriteStopsGitAndItsHookAndThrowsCancellation() async throws {
        let pidFile = try installHangingHook()
        let runner = fixture.repository.runner
        let commit = Task { try await runner.runWrite(["commit", "--allow-empty", "-q", "-m", "hangs"]) }
        try await waitForFile(pidFile)
        let hookPID = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let started = Date()
        commit.cancel()
        let result = await commit.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // The hook's shell was in git's process group; a stopped git must not leave it running.
        try await assertEnded(hookPID)
    }

    /// A helper that ignores SIGTERM keeps git's stderr open after git itself exited; it must be killed rather than waited for.
    func testCancellingStopsAHelperThatIgnoresTermination() async throws {
        let pidFile = try installHangingHook(waits: "trap '' TERM\nsleep 30")
        let runner = fixture.repository.runner
        let commit = Task { try await runner.runWrite(["commit", "--allow-empty", "-q", "-m", "hangs"]) }
        try await waitForFile(pidFile)
        let hookPID = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let started = Date()
        commit.cancel()
        let result = await commit.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        try await assertEnded(hookPID)
    }

    /// A stopped process stays visible to `kill(pid, 0)` until launchd reaps the orphan, which can lag behind on a busy machine.
    private func assertEnded(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(kill(pid, 0), -1, "process \(pid) is still running", file: file, line: line)
    }

    func testACallerCancelledWhileQueuedLeavesAtOnceAndItsCommandNeverRuns() async throws {
        let pidFile = try installHangingHook()
        let runner = fixture.repository.runner
        let blocking = Task { try await runner.runWrite(["commit", "--allow-empty", "-q", "-m", "hangs"]) }
        defer { blocking.cancel() }
        try await waitForFile(pidFile)
        let queued = Task { try await runner.runWrite(["tag", "queued"]) }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        queued.cancel()
        let result = await queued.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        blocking.cancel()
        _ = await blocking.result
        XCTAssertEqual(try fixture.git("tag", "--list", "queued"), "")
        // The queue is free again.
        _ = try await runner.runWrite(["tag", "after"])
    }
}
