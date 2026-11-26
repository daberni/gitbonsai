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
            ["Delete feature…", "Delete Branches…"],
            ["Create Branch…", "Create Worktree…", "Create Tag…", "Create annotated Tag…"],
            ["Rename…", "Change Upstream…"],
            ["Copy feature", "Copy \(short(fixture.feature))"],
        ])
    }

    /// Checking out, merging, rebasing onto or deleting the branch HEAD is on would act on itself.
    func testCheckedOutBranchOffersOnlyWhatDoesNotActOnItself() throws {
        let menu = tab.menus.menu(for: .branch(try tab.ref("main")), in: .sidebar)
        XCTAssertEqual(menu.outline, [
            ["Pull main", "Push main"],
            ["Create Branch…", "Create Tag…", "Create annotated Tag…"],
            ["Rename…", "Change Upstream…"],
            ["Copy main", "Copy \(short(fixture.head))"],
        ])
    }

    /// A branch checked out in another worktree is reached by switching the tab there, and only goes together with that worktree.
    func testBranchOfAnotherWorktreeSwitchesThereInsteadOfCheckingOut() throws {
        let menu = tab.menus.menu(for: .branch(try tab.ref("other")), in: .sidebar)
        XCTAssertEqual(menu.outline.first, ["Switch to Worktree wt"])
        XCTAssertNil(menu.entry("Create Worktree…"), "a branch with a worktree gets no second one")
        XCTAssertNil(menu.entry("Pull other"), "no upstream, nothing to pull")
    }

    /// On a pill the commit section offers Copy SHA, Create Worktree… and the rebase onto the commit, so the branch's section leaves them out.
    func testPillMenuZipsTheBranchWithItsCommitWithoutDuplicates() throws {
        let row = try tab.row(of: fixture.feature)
        let menu = tab.menus.pillMenu(forRow: row, ref: .branch("feature"))
        let titles = menu.joined().map(\.plainTitle)
        XCTAssertEqual(titles.filter { $0 == "Copy \(short(fixture.feature))" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Create Worktree…" }.count, 1)
        XCTAssertEqual(menu.outline.first, ["Checkout feature", "Checkout Commit \(short(fixture.feature)) (Detached HEAD)"])
        XCTAssertEqual(menu.outline.last, ["Copy feature", "Copy \(short(fixture.feature))", "Save Patch…"])
        XCTAssertFalse(menu.joined().contains { $0.plainTitle == "origin/feature" }, "the remote branch beside its local branch adds no submenu of its own")
        XCTAssertEqual(titles.filter { $0 == "Rebase main onto feature" }.count, 1)
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

    /// Stash menus follow the shared group order, the same in the Stashes list and on the history's stash row.
    func testStashMenusFollowTheGroupOrder() throws {
        let stash = try XCTUnwrap(tab.model.stashes.first).commitID
        let row = try XCTUnwrap(tab.model.kinds.firstIndex(of: .stash))
        let expected = [["Show Diff"], ["Apply Stash", "Pop Stash"], ["Drop Stash…"], ["Create Branch…"], ["Copy \(short(stash))"]]
        XCTAssertEqual(tab.menus.menu(for: .stash(stash), in: .sidebar).outline, expected)
        XCTAssertEqual(tab.menus.rowMenu(forRow: row).outline, expected)
    }

    /// The Tags list leads with the jump and checks out detached; on a pill the commit's own checkout covers that. origin lacks the tag, so it is offered a push and no delete.
    func testTagMenusDifferBetweenListAndPill() async throws {
        try await waitUntil { self.tab.tags.isSettled && !self.tab.tags.rows.remoteOffers("v1", remotes: ["origin"]).allSatisfy(\.canDelete) }
        let list = tab.menus.menu(for: .tag("v1"), in: .sidebar)
        XCTAssertEqual(list.outline, [["Jump to Commit", "Checkout (Detached HEAD)"], ["Push v1 to origin"], ["Delete v1"], ["Copy v1"]])
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

    /// The worktree the tab shows cannot be switched to, and its Remove says why it is disabled; the main worktree cannot be locked or removed.
    func testWorktreeMenusProtectTheShownAndTheMainWorktree() throws {
        let main = try XCTUnwrap(tab.model.worktrees.first { $0.worktree.isMain })
        let other = try XCTUnwrap(tab.model.worktrees.first { !$0.worktree.isMain })
        XCTAssertEqual(tab.menus.menu(for: .worktree(main, isCurrent: true), in: .sidebar).outline, [["Show in Finder", "Open in Terminal"]])
        XCTAssertEqual(tab.menus.menu(for: .worktree(other, isCurrent: false), in: .sidebar).outline, [["Switch to this Worktree", "Show in Finder", "Open in Terminal"], ["Remove…"], ["Lock…"]])
        XCTAssertEqual(tab.menus.menu(for: .worktree(other, isCurrent: true), in: .sidebar).outline, [["Show in Finder", "Open in Terminal"], ["Remove… (Currently open)"], ["Lock…"]])
    }

    /// A worktree whose folder is gone offers only removing git's record of it.
    func testMissingWorktreeOffersOnlyRemove() async throws {
        try FileManager.default.removeItem(atPath: fixture.worktreePath)
        await tab.model.refresh(note: nil)
        let missing = try XCTUnwrap(tab.model.worktrees.first { !$0.worktree.isMain })
        XCTAssertTrue(missing.worktree.isPrunable)
        XCTAssertEqual(tab.menus.menu(for: .worktree(missing, isCurrent: false), in: .sidebar).outline, [["Remove"]])
    }

    /// While git is in the middle of an operation, entries that move HEAD or rewrite history say so; copying, creating and pushing stay.
    func testEntriesThatMoveHeadWaitWhileAnOperationRuns() throws {
        tab.menus.operation = { .rebase }
        let branch = tab.menus.menu(for: .branch(try tab.ref("feature")), in: .sidebar)
        for title in ["Checkout feature", "Pull feature", "Merge feature into main", "Rebase main onto feature"] {
            XCTAssertEqual(branch.entry(title)?.disabledReason, "Rebase in progress", title)
        }
        for title in ["Push feature", "Create Branch…", "Copy feature", "Rename…"] {
            XCTAssertEqual(branch.entry(title)?.isEnabled, true, title)
        }
        let row = tab.menus.rowMenu(forRow: try tab.row(of: fixture.tagged))
        XCTAssertEqual(row.entry("Reset main to here")?.disabledReason, "Rebase in progress")
        XCTAssertEqual(row.entry("Revert Commit")?.disabledReason, "Rebase in progress")
        XCTAssertEqual(row.entry("Edit Message")?.disabledReason, "Rebase in progress")
        XCTAssertEqual(row.entry("Create Tag…")?.isEnabled, true)
    }

    /// A remote branch checks out the local branch of its name, offers Merge and Rebase like a local one, and deletes under its own name.
    func testRemoteBranchMenuChecksOutTheLocalBranchAndIntegrates() throws {
        let menu = tab.menus.menu(for: .branch(try tab.ref("origin/feature")), in: .sidebar)
        XCTAssertEqual(menu.outline.first, ["Checkout feature"])
        XCTAssertNotNil(menu.entry("Merge origin/feature into main"))
        XCTAssertNotNil(menu.entry("Rebase main onto origin/feature"))
        XCTAssertNotNil(menu.entry("Delete origin/feature…"))
    }

    /// A branch whose tip HEAD already contains has nothing to merge or rebase onto, and deleting it asks nothing, so it has no ellipsis.
    func testBranchContainedInHeadOffersNoMergeOrRebase() async throws {
        try fixture.repo.git("branch", "old", fixture.tagged)
        await tab.model.refresh(note: nil)
        let menu = tab.menus.menu(for: .branch(try tab.ref("old")), in: .sidebar)
        XCTAssertNil(menu.entry("Merge old into main"))
        XCTAssertNil(menu.entry("Rebase main onto old"))
        XCTAssertNotNil(menu.entry("Delete old"))
    }

    /// "Delete Branches…" needs a remote branch to delete; a configured upstream that was deleted on the remote and pruned does not count.
    func testDeleteBranchesNeedsAnExistingRemoteBranch() async throws {
        XCTAssertNotNil(tab.menus.menu(for: .branch(try tab.ref("feature")), in: .sidebar).entry("Delete Branches…"))
        try fixture.origin.git("branch", "-D", "feature")
        try fixture.repo.git("fetch", "-q", "--prune", "origin")
        await tab.model.refresh(note: nil)
        let feature = try tab.ref("feature")
        XCTAssertEqual(feature.upstream, "origin/feature", "the upstream stays configured")
        XCTAssertNil(tab.menus.menu(for: .branch(feature), in: .sidebar).entry("Delete Branches…"))
    }

    func testRemoteMenuNamesItsGitCommands() {
        let menu = tab.menus.menu(for: .remote("origin"), in: .sidebar)
        XCTAssertEqual(menu.outline, [["Edit Remote…"], ["Remove Remote"]])
        XCTAssertEqual(menu.entry("Remove Remote")?.toolTip, "git remote remove origin")
    }
}
