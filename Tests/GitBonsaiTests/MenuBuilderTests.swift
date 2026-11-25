import GitEngine
import XCTest
@testable import GitBonsai

/// The context menus as data: which entries each subject offers where, in the approved group order (go there | sync | integrate | remove | create | change | copy), and why an entry is disabled.
@MainActor
final class MenuBuilderTests: XCTestCase {
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

    private func short(_ sha: String) -> String { String(sha.prefix(7)) }

    func testSidebarBranchMenuFollowsTheGroupOrder() throws {
        let menu = tab.menus.menu(for: .branch(try tab.ref("feature")), in: .sidebar)
        XCTAssertEqual(menu.outline, [
            ["Checkout feature"],
            ["Pull feature", "Push feature"],
            ["Merge feature into main", "Rebase main onto feature"],
            ["Delete feature", "Delete Branches…"],
            ["Create Worktree…"],
            ["Rename…", "Change Upstream…"],
            ["Copy feature [feature, origin/feature]", "Copy \(short(fixture.feature))"],
        ])
    }

    /// Checking out, merging, rebasing onto or deleting the branch HEAD is on would act on itself.
    func testCheckedOutBranchOffersOnlyWhatDoesNotActOnItself() throws {
        let menu = tab.menus.menu(for: .branch(try tab.ref("main")), in: .sidebar)
        XCTAssertEqual(menu.outline, [
            ["Pull main", "Push main"],
            ["Rename…", "Change Upstream…"],
            ["Copy main [main, origin/main]", "Copy \(short(fixture.head))"],
        ])
    }

    /// A branch checked out in another worktree is reached by switching the tab there, and only goes together with that worktree.
    func testBranchOfAnotherWorktreeSwitchesThereInsteadOfCheckingOut() throws {
        let menu = tab.menus.menu(for: .branch(try tab.ref("other")), in: .sidebar)
        XCTAssertEqual(menu.outline.first, ["Switch to Worktree wt"])
        XCTAssertNil(menu.entry("Create Worktree…"), "a branch with a worktree gets no second one")
        XCTAssertNil(menu.entry("Pull other"), "no upstream, nothing to pull")
    }

    /// On a pill the commit section offers Copy SHA and Create Worktree…, so the branch's section leaves them out, and its plain rebase joins the commit's rebase entries.
    func testPillMenuZipsTheBranchWithItsCommitWithoutDuplicates() throws {
        let row = try tab.row(of: fixture.feature)
        let menu = tab.menus.pillMenu(forRow: row, ref: .branch("feature"))
        let titles = menu.joined().map(\.plainTitle)
        XCTAssertEqual(titles.filter { $0 == "Copy \(short(fixture.feature))" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Create Worktree…" }.count, 1)
        XCTAssertEqual(menu.outline.first, ["Checkout feature", "Checkout Commit \(short(fixture.feature)) (Detached HEAD)"])
        XCTAssertEqual(menu.outline.last, ["Copy feature [feature, origin/feature]", "Copy \(short(fixture.feature))", "Save Patch…"])
        XCTAssertFalse(menu.joined().contains { $0.plainTitle == "origin/feature" }, "the remote branch beside its local branch adds no submenu of its own")
        XCTAssertNotNil(menu.entry("Rebase main onto feature"))
    }

    /// The row menu of a commit with one branch pill equals that pill's menu; with several branch pills each leads as a submenu.
    func testRowMenuLeadsWithASubmenuPerBranchWhenSeveralSitOnTheCommit() throws {
        let single = try tab.row(of: fixture.feature)
        XCTAssertEqual(tab.menus.rowMenu(forRow: single).outline, tab.menus.pillMenu(forRow: single, ref: .branch("feature")).outline)
        let shared = try tab.row(of: fixture.head)
        let leading = try XCTUnwrap(tab.menus.rowMenu(forRow: shared).first)
        XCTAssertEqual(leading.map(\.plainTitle), ["main", "other"])
        XCTAssertNotNil(leading[1].submenu?.entry("Switch to Worktree wt"))
    }

    /// Stash menus follow the shared group order; the history's stash row adds Copy SHA at the end, the Stashes list does not.
    func testStashMenusFollowTheGroupOrder() throws {
        let stash = try XCTUnwrap(tab.model.stashes.first).commitID
        let row = try XCTUnwrap(tab.model.kinds.firstIndex(of: .stash))
        let expected = [["Show Diff"], ["Apply Stash", "Pop"], ["Drop…"], ["Create Branch from Stash…"]]
        XCTAssertEqual(tab.menus.menu(for: .stash(stash), in: .sidebar).outline, expected)
        XCTAssertEqual(tab.menus.rowMenu(forRow: row).outline, expected + [["Copy \(short(stash))"]])
    }

    /// The Tags list leads with the jump and checks out detached; on a pill the commit's own checkout covers that.
    func testTagMenusDifferBetweenListAndPill() throws {
        let list = tab.menus.menu(for: .tag("v1"), in: .sidebar)
        XCTAssertEqual(list.outline, [["Jump to Commit"], ["Checkout (Detached HEAD)"], ["Push v1 to origin"], ["Delete", "Delete on origin…"], ["Copy v1"]])
        let pill = tab.menus.pillMenu(forRow: try tab.row(of: fixture.tagged), ref: .tag("v1"))
        XCTAssertNil(pill.entry("Checkout (Detached HEAD)"))
        XCTAssertNotNil(pill.entry("Checkout Commit \(short(fixture.tagged)) (Detached HEAD)"))
        XCTAssertEqual(pill.outline.last, ["Copy v1", "Copy \(short(fixture.tagged))", "Save Patch…"])
    }

    /// Moves of a commit say why they cannot run instead of disappearing.
    func testRewriteEntriesSayWhyTheyAreDisabled() throws {
        let head = tab.menus.rowMenu(forRow: try tab.row(of: fixture.head))
        XCTAssertEqual(head.entry("Move up")?.disabledReason, "Already the topmost commit")
        XCTAssertTrue(head.entry("Move down")?.isEnabled ?? false)
        let root = tab.menus.rowMenu(forRow: try tab.row(of: fixture.root))
        XCTAssertEqual(root.entry("Drop Commit")?.disabledReason, "The repository’s first commit has no parent")
        XCTAssertEqual(root.entry("Move down")?.disabledReason, "The repository’s first commit has no parent")
    }

    /// The worktree the tab shows cannot be switched to or removed, and the main worktree cannot be locked or removed.
    func testWorktreeMenusProtectTheShownAndTheMainWorktree() throws {
        let main = try XCTUnwrap(tab.model.worktrees.first { $0.worktree.isMain })
        let other = try XCTUnwrap(tab.model.worktrees.first { !$0.worktree.isMain })
        XCTAssertEqual(tab.menus.menu(for: .worktree(main, isCurrent: true), in: .sidebar).outline, [["Show in Finder", "Open in terminal"], ["Prune missing Worktrees"]])
        XCTAssertEqual(tab.menus.menu(for: .worktree(other, isCurrent: false), in: .sidebar).outline, [["Switch to this Worktree", "Show in Finder", "Open in terminal"], ["Remove…"], ["Lock…"], ["Prune missing Worktrees"]])
    }

    func testRemoteMenuNamesItsGitCommands() {
        let menu = tab.menus.menu(for: .remote("origin"), in: .sidebar)
        XCTAssertEqual(menu.outline, [["Edit Remote…"], ["Remove Remote"]])
        XCTAssertEqual(menu.entry("Remove Remote")?.toolTip, "git remote remove origin")
    }
}
