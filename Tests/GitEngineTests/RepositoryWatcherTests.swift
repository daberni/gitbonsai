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

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bursts: [RepositoryWatcher.Burst] = []
        func add(_ burst: RepositoryWatcher.Burst) { lock.withLock { bursts.append(burst) } }
        var count: Int { lock.withLock { bursts.count } }
        var events: Int { lock.withLock { bursts.map(\.events).reduce(0, +) } }
    }

    private func watch(_ fixture: FixtureRepo) async throws -> (RepositoryWatcher, Counter) {
        let common = try fixture.git("rev-parse", "--path-format=absolute", "--git-common-dir")
        let scope = try await WatchScope.of(root: fixture.path, commonDirectory: common)
        let counter = Counter()
        let watcher = RepositoryWatcher(scope: scope) { counter.add($0) }
        watcher.start()
        // FSEvents reports from the moment the stream runs; a short pause keeps the setup's own writes out.
        try await Task.sleep(for: .milliseconds(300))
        return (watcher, counter)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(1500))
    }

    func testOutsideCommitIsOneChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.commit("outside", file: "tracked.txt")
        try await settle()
        XCTAssertEqual(counter.count, 1)
    }

    func testEditOfATrackedFileIsAChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.write("tracked.txt", "edited\n")
        try await settle()
        XCTAssertEqual(counter.count, 1)
    }

    func testABurstOfAThousandWritesIsOneChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        for index in 0..<1000 { try fixture.write("burst/\(index).txt", "\(index)\n") }
        try await settle()
        XCTAssertEqual(counter.count, 1)
        XCTAssertGreaterThan(counter.events, 1)
    }

    func testIgnoredFoldersAndObjectsAreNoChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.write("node_modules/pkg/index.js", "x\n")
        // Writes a loose object into .git/objects without touching any ref.
        _ = try fixture.git("hash-object", "-w", "node_modules/pkg/index.js")
        try await settle()
        XCTAssertEqual(counter.count, 0)
    }

    func testTheAppsOwnWriteIsNoChange() async throws {
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try fixture.write("tracked.txt", "staged\n")
        try await settle()
        let before = counter.count
        _ = try await fixture.repository.runner.runWrite(["add", "tracked.txt"])
        try await settle()
        XCTAssertEqual(counter.count, before)
    }

    func testACommitInALinkedWorktreeReachesTheMainWorktreesWatcher() async throws {
        let other = fixture.url.deletingLastPathComponent().appendingPathComponent("gitbonsai-watcher-linked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        try fixture.git("worktree", "add", "-q", "-b", "topic", other.path)
        let (watcher, counter) = try await watch(fixture)
        defer { watcher.stop() }
        try FixtureRepo(existing: other).git("commit", "-q", "--allow-empty", "-m", "elsewhere")
        try await settle()
        XCTAssertEqual(counter.count, 1)
    }

    func testNothingIsReportedAfterStop() async throws {
        let (watcher, counter) = try await watch(fixture)
        watcher.stop()
        try fixture.commit("after stop", file: "tracked.txt")
        try await settle()
        XCTAssertEqual(counter.count, 0)
    }
}
