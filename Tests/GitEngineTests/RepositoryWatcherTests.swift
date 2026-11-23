import XCTest
@testable import GitEngine

final class WatchScopeTests: XCTestCase {
    let main = WatchScope(root: "/r", gitDirectory: "/r/.git", commonDirectory: "/r/.git")
    let linked = WatchScope(root: "/w", gitDirectory: "/r/.git/worktrees/w", commonDirectory: "/r/.git")

    func testWorkingTreeFilesCountButDependencyAndBuildFoldersDoNot() {
        XCTAssertTrue(main.isRelevant("/r/Sources/a.swift"))
        XCTAssertFalse(main.isRelevant("/r/node_modules/x/index.js"))
        XCTAssertFalse(main.isRelevant("/r/.build/debug/a.o"))
        XCTAssertFalse(main.isRelevant("/r/Sources/.DS_Store"))
        XCTAssertFalse(main.isRelevant("/r/vendor/sub/.git/HEAD"))
        XCTAssertFalse(main.isRelevant("/elsewhere/a"))
    }

    func testObjectsLocksAndReflogsAreNoise() {
        XCTAssertFalse(main.isRelevant("/r/.git/objects/ab/cdef"))
        XCTAssertFalse(main.isRelevant("/r/.git/index.lock"))
        XCTAssertFalse(main.isRelevant("/r/.git/refs/heads/main.lock"))
        XCTAssertFalse(main.isRelevant("/r/.git/logs/HEAD"))
        XCTAssertFalse(main.isRelevant("/r/.git/logs/refs/heads/main"))
        XCTAssertFalse(main.isRelevant("/r/.git/hooks/pre-commit"))
    }

    func testRefsStashAndOwnStateCount() {
        for path in ["/r/.git/HEAD", "/r/.git/index", "/r/.git/refs/heads/main", "/r/.git/packed-refs", "/r/.git/FETCH_HEAD", "/r/.git/logs/refs/stash", "/r/.git/rebase-merge/msgnum", "/r/.git/MERGE_HEAD", "/r/.git/config"] {
            XCTAssertTrue(main.isRelevant(path), path)
        }
    }

    /// The main worktree sees another worktree's HEAD, but not its index; a linked worktree sees its own index and the main worktree's HEAD, but not the main index.
    func testWorktreesSeeEachOthersHeadButOnlyTheirOwnIndex() {
        XCTAssertTrue(main.isRelevant("/r/.git/worktrees/w/HEAD"))
        XCTAssertFalse(main.isRelevant("/r/.git/worktrees/w/index"))
        XCTAssertTrue(linked.isRelevant("/r/.git/worktrees/w/index"))
        XCTAssertTrue(linked.isRelevant("/r/.git/worktrees/w/HEAD"))
        XCTAssertTrue(linked.isRelevant("/r/.git/worktrees/w/rebase-merge/done"))
        XCTAssertTrue(linked.isRelevant("/r/.git/HEAD"))
        XCTAssertFalse(linked.isRelevant("/r/.git/index"))
        XCTAssertTrue(linked.isRelevant("/r/.git/refs/heads/topic"))
        XCTAssertTrue(linked.isRelevant("/w/file.txt"))
        XCTAssertFalse(linked.isRelevant("/w/.git"))
        XCTAssertFalse(linked.isRelevant("/r/file.txt"))
    }

    func testALinkedWorktreeWatchesItsCommonDirectoryToo() {
        XCTAssertEqual(main.watchedPaths, ["/r"])
        XCTAssertEqual(linked.watchedPaths, ["/w", "/r/.git"])
    }
}

/// The watcher against real repositories and real FSEvents.
///
/// Tests wait for bursts, not for time. "Nothing else was reported" is shown with a sentinel: a file written afterwards whose burst must be the next one,
/// or a second watcher on the same repository whose report marks the moment the first one would have reported too.
final class RepositoryWatcherTests: XCTestCase {
    var fixture: FixtureRepo!

    override func setUpWithError() throws {
        fixture = try FixtureRepo(name: "watcher")
        try fixture.commit("first", file: "tracked.txt")
        try fixture.write(".gitignore", "node_modules/\n")
        try fixture.commit("ignore")
    }

    override func tearDown() {
        fixture.remove()
    }

    /// Collects bursts and lets a test await the next one.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bursts: [RepositoryWatcher.Burst] = []
        private var waiters: [(index: Int, continuation: CheckedContinuation<RepositoryWatcher.Burst?, Never>)] = []

        func add(_ burst: RepositoryWatcher.Burst) {
            let ready: [(RepositoryWatcher.Burst, CheckedContinuation<RepositoryWatcher.Burst?, Never>)] = lock.withLock {
                bursts.append(burst)
                let ready = waiters.filter { $0.index < bursts.count }
                waiters.removeAll { $0.index < bursts.count }
                return ready.map { (bursts[$0.index], $0.continuation) }
            }
            ready.forEach { $1.resume(returning: $0) }
        }

        var count: Int { lock.withLock { bursts.count } }
        var events: Int { lock.withLock { bursts.map(\.events).reduce(0, +) } }
        func burst(_ index: Int) -> RepositoryWatcher.Burst? { lock.withLock { bursts.indices.contains(index) ? bursts[index] : nil } }

        /// The burst with this index, once it arrived; nil when it did not within `timeout`.
        func wait(for index: Int, timeout: TimeInterval = 10) async -> RepositoryWatcher.Burst? {
            await withCheckedContinuation { (continuation: CheckedContinuation<RepositoryWatcher.Burst?, Never>) in
                let existing: RepositoryWatcher.Burst? = lock.withLock {
                    if bursts.indices.contains(index) { return bursts[index] }
                    waiters.append((index, continuation))
                    return nil
                }
                if let existing {
                    continuation.resume(returning: existing)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    let expired: CheckedContinuation<RepositoryWatcher.Burst?, Never>? = lock.withLock {
                        guard let position = waiters.firstIndex(where: { $0.index == index }) else { return nil }
                        return waiters.remove(at: position).continuation
                    }
                    expired?.resume(returning: nil)
                }
            }
        }

        func reset() { lock.withLock { bursts = [] } }
    }

    private func scope(of fixture: FixtureRepo) async throws -> WatchScope {
        let common = try fixture.git("rev-parse", "--path-format=absolute", "--git-common-dir")
        return try await WatchScope.of(root: fixture.path, commonDirectory: common)
    }

    /// Starts a watcher and returns once it reported a probe file, so the setup's own writes are behind it.
    private func watch(_ fixture: FixtureRepo, ownWriteSettle: TimeInterval = 0.5) async throws -> (RepositoryWatcher, Counter) {
        let counter = Counter()
        let watcher = RepositoryWatcher(scope: try await scope(of: fixture), ownWriteSettle: ownWriteSettle) { counter.add($0) }
        watcher.start()
        try await probe(fixture, counter)
        counter.reset()
        return (watcher, counter)
    }

    /// Writes a sentinel file until a burst names it first; FSEvents may need a moment after the stream starts, and an own write's settle time hides bursts.
    @discardableResult
    private func probe(_ fixture: FixtureRepo, _ counter: Counter) async throws -> RepositoryWatcher.Burst {
        var next = counter.count
        for attempt in 0..<10 {
            let name = "probe-\(UUID().uuidString).txt"
            // Written in place: an atomic write would report its temporary file first.
            try Data("\(attempt)\n".utf8).write(to: fixture.url.appendingPathComponent(name))
            while let burst = await counter.wait(for: next, timeout: 1) {
                next += 1
                if burst.firstPath.hasSuffix(name) { return burst }
            }
        }
        throw XCTSkip("the watcher never reported a probe file")
    }

    /// Asserts that the next burst after the ones counted is the sentinel's, so the action caused nothing more.
    private func assertNothingElse(_ counter: Counter, file: StaticString = #filePath, line: UInt = #line) async throws {
        let expected = counter.count
        let burst = try await probe(fixture, counter)
        XCTAssertEqual(counter.count, expected + 1, "a burst arrived before the sentinel: \(burst.firstPath)", file: file, line: line)
    }

    func testOutsideCommitIsOneChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.commit("outside", file: "tracked.txt")
        let reported = await counter.wait(for: 0)
        XCTAssertNotNil(reported)
        try await assertNothingElse(counter)
    }

    func testEditOfATrackedFileIsAChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.write("tracked.txt", "edited\n")
        let burst = await counter.wait(for: 0)
        // The atomic write reports its temporary file next to it first.
        XCTAssertTrue(burst?.firstPath.contains("/tracked.txt") == true, burst?.firstPath ?? "no burst")
        try await assertNothingElse(counter)
    }

    func testABurstOfAThousandWritesIsOneChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        for index in 0..<1000 { try fixture.write("burst/\(index).txt", "\(index)\n") }
        let burst = await counter.wait(for: 0)
        XCTAssertGreaterThan(burst?.events ?? 0, 1)
        try await assertNothingElse(counter)
    }

    func testIgnoredFoldersAndObjectsAreNoChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.write("node_modules/pkg/index.js", "x\n")
        // Writes a loose object into .git/objects without touching any ref.
        _ = try fixture.git("hash-object", "-w", "node_modules/pkg/index.js")
        try await assertNothingElse(counter)
    }

    func testTheAppsOwnWriteIsNoChange() async throws {
        try fixture.write("tracked.txt", "staged\n")
        let settle: TimeInterval = 0.3
        let (watcher, counter) = try await watch(fixture, ownWriteSettle: settle)
        defer { watcher.stop() }
        _ = try await fixture.repository.runner.runWrite(["add", "tracked.txt"])
        // The settle time is the contract under test: the sentinel goes in once it passed, so its burst is not taken for part of the write.
        try await Task.sleep(for: .seconds(settle))
        try await assertNothingElse(counter)
    }

    /// The app's working-tree diffs may rewrite the index; that write is the app's own, but an edit made meanwhile in an editor is not.
    func testAnOutsideEditDuringAnIndexRefreshingReadIsAChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        let runner = fixture.repository.runner
        // The fsmonitor hook only stalls git, so the read lasts long enough to edit a file meanwhile.
        let read = Task { try await runner.runRefreshingIndex(["-c", "core.fsmonitor=sleep 1; false", "diff"]) }
        try await Task.sleep(for: .milliseconds(300))
        try fixture.write("tracked.txt", "edited in an editor\n")
        _ = try await read.value
        let reported = await counter.wait(for: 0)
        XCTAssertNotNil(reported)
    }

    /// `git remote add` only rewrites `.git/config`, through `config.lock` and a rename.
    func testAddingARemoteInATerminalIsAChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.git("remote", "add", "upstream", "https://example.com/repo.git")
        let burst = await counter.wait(for: 0)
        XCTAssertTrue(burst?.firstPath.contains("config") == true, burst?.firstPath ?? "no burst")
    }

    func testACommitInALinkedWorktreeReachesTheMainWorktreesWatcher() async throws {
        let other = fixture.url.deletingLastPathComponent().appendingPathComponent("gitbonsai-watcher-linked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        try fixture.git("worktree", "add", "-q", "-b", "topic", other.path)
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try FixtureRepo(existing: other).git("commit", "-q", "--allow-empty", "-m", "elsewhere")
        let reported = await counter.wait(for: 0)
        XCTAssertNotNil(reported)
        try await assertNothingElse(counter)
    }

    final class Holder: @unchecked Sendable {
        var watcher: RepositoryWatcher?
    }

    /// A tab that closes on a change stops its watcher from the change callback, which runs on the watcher's queue.
    func testStoppingFromTheChangeCallbackReturns() async throws {
        let holder = Holder()
        let counter = Counter()
        holder.watcher = RepositoryWatcher(scope: try await scope(of: fixture)) { burst in
            holder.watcher?.stop()
            counter.add(burst)
        }
        holder.watcher?.start()
        let (witness, seen) = try await watch(fixture)
        defer { witness.stop() }
        try fixture.write("tracked.txt", "edited\n")
        let reported = await counter.wait(for: 0)
        XCTAssertNotNil(reported)
        try fixture.write("tracked.txt", "edited again\n")
        try await probe(fixture, seen)
        XCTAssertEqual(counter.count, 1)
    }

    /// A watcher released while its stream still delivers events, without `stop`, must neither crash nor report.
    func testReleasingARunningWatcherIsSafe() async throws {
        let scope = try await scope(of: fixture)
        let counter = Counter()
        for round in 0..<20 {
            var watcher: RepositoryWatcher? = RepositoryWatcher(scope: scope, quiet: 0.01) { counter.add($0) }
            watcher?.start()
            for index in 0..<50 { try fixture.write("released/\(round)-\(index).txt", "x\n") }
            watcher = nil
            XCTAssertNil(watcher)
        }
        // Whatever the released streams still had in flight is delivered before a new watcher's probe; a released watcher reached from it would crash here.
        let (witness, _) = try await watch(fixture)
        witness.stop()
    }

    func testNothingIsReportedAfterStop() async throws {
        let (watcher, counter) = try await watch(fixture)
        watcher.stop()
        let (witness, seen) = try await watch(fixture)
        defer { witness.stop() }
        try fixture.commit("after stop", file: "tracked.txt")
        let reported = await seen.wait(for: 0)
        XCTAssertNotNil(reported)
        try await probe(fixture, seen)
        XCTAssertEqual(counter.count, 0)
    }
}
