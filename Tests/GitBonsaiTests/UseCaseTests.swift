import GitEngine
import XCTest
@testable import GitBonsai

/// Actions run from their menu entries with a fake prompter: which ones ask first, what runs after yes and no, and that local operations leave an undo point.
@MainActor
final class UseCaseTests: XCTestCase {
    private var fixture: MenuFixtureRepo!
    private var tab: TabFixture!

    override func setUp() async throws {
        fixture = try MenuFixtureRepo()
        tab = TabFixture(fixture.repo)
        try await tab.load()
    }

    override func tearDown() async throws {
        tab.context.lifecycle.close()
        fixture.remove()
    }

    private func branchExists(_ name: String) -> Bool {
        (try? fixture.repo.git("rev-parse", "--verify", "-q", "refs/heads/\(name)")) != nil
    }

    private func headSHA() throws -> String { try fixture.repo.git("rev-parse", "HEAD") }

    /// Lets an answered action run what it started; nothing it runs may happen after this.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }

    /// A branch checked out in another worktree only goes together with that worktree, after asking.
    func testDeletingABranchOfAnotherWorktreeAsksAndKeepsBothOnNo() async throws {
        let menu = tab.menus.menu(for: .branch(try tab.ref("other")), in: .sidebar)
        try XCTUnwrap(menu.entry("Delete other")).run()
        try await waitUntil { !self.tab.prompter.asked.isEmpty }
        try await settle()
        XCTAssertEqual(tab.prompter.asked, ["Delete Branch and Worktree?"])
        XCTAssertTrue(branchExists("other"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.worktreePath))
    }

    func testDeletingABranchOfAnotherWorktreeRemovesBothOnYesAndCanBeUndone() async throws {
        tab.prompter.confirmations = [true]
        let menu = tab.menus.menu(for: .branch(try tab.ref("other")), in: .sidebar)
        try XCTUnwrap(menu.entry("Delete other")).run()
        try await waitUntil { !self.branchExists("other") && self.tab.model.undoOffer != nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktreePath))
        XCTAssertEqual(tab.model.undoOffer?.operation, "git branch -d")
        XCTAssertEqual(tab.prompter.reports, [])
    }

    /// Only a hard reset over uncommitted changes asks: those changes cannot come back.
    func testHardResetOverChangesAsksAndDoesNothingOnNo() async throws {
        try fixture.repo.write("three.txt", "uncommitted\n")
        await tab.model.refresh(note: nil)
        let menu = tab.menus.rowMenu(forRow: try tab.row(of: fixture.root))
        try XCTUnwrap(menu.entry("Hard – discard changes…")).run()
        try await waitUntil { !self.tab.prompter.asked.isEmpty }
        try await settle()
        XCTAssertEqual(tab.prompter.asked, ["Reset Branch and discard Changes?"])
        XCTAssertEqual(try headSHA(), fixture.head)
        XCTAssertNil(tab.model.undoOffer)
    }

    func testHardResetOverChangesRunsOnYesWithAnUndoPoint() async throws {
        try fixture.repo.write("three.txt", "uncommitted\n")
        await tab.model.refresh(note: nil)
        tab.prompter.confirmations = [true]
        let menu = tab.menus.rowMenu(forRow: try tab.row(of: fixture.root))
        try XCTUnwrap(menu.entry("Hard – discard changes…")).run()
        try await waitUntil { (try? self.headSHA()) == self.fixture.root && self.tab.model.undoOffer != nil }
        XCTAssertEqual(tab.model.undoOffer?.operation, "git reset --hard · 2 commits are already on origin/main; push afterwards only with --force-with-lease")
    }

    /// A soft reset loses nothing, so it runs at once; the status line offers to undo it and names the published commits it rewrites.
    func testSoftResetRunsWithoutAskingAndCanBeUndone() async throws {
        let menu = tab.menus.rowMenu(forRow: try tab.row(of: fixture.tagged))
        try XCTUnwrap(menu.entry("Soft – keep changes staged")).run()
        try await waitUntil { (try? self.headSHA()) == self.fixture.tagged && self.tab.model.undoOffer != nil }
        XCTAssertEqual(tab.prompter.asked, [])
        XCTAssertEqual(tab.model.undoOffer?.operation, "git reset --soft · 1 commit is already on origin/main; push afterwards only with --force-with-lease")
    }

    /// Removing a worktree asks first; without an answer nothing is removed.
    func testRemovingAWorktreeAsksFirst() async throws {
        let other = try XCTUnwrap(tab.model.worktrees.first { !$0.worktree.isMain })
        try XCTUnwrap(tab.menus.menu(for: .worktree(other, isCurrent: false), in: .sidebar).entry("Remove…")).run()
        try await waitUntil { !self.tab.prompter.asked.isEmpty }
        try await settle()
        XCTAssertEqual(tab.prompter.asked, ["Remove Worktree?"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.worktreePath))
    }
}
