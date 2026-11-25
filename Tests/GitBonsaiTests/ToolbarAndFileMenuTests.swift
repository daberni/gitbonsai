import GitEngine
import XCTest
@testable import GitBonsai

/// The toolbar's split-button menus and the file lists' menu as data. A click on a split button's main part runs the first enabled entry, so which entry that is matters as much as the content.
@MainActor
final class ToolbarAndFileMenuTests: XCTestCase {
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

    private func firstEnabled(_ menu: [[MenuEntry]]) -> String? {
        menu.joined().first { $0.isEnabled }?.plainTitle
    }

    func testFetchMenuOffersEveryRemoteWithAndWithoutPruneAndShowsTheCommands() {
        let menu = tab.menus.toolbarMenu(.fetch)
        XCTAssertEqual(menu.outline, [["Fetch all Remotes"], ["Fetch origin", "Fetch origin and Prune deleted Branches"], ["Fetch Tags from all Remotes"]])
        XCTAssertEqual(menu.joined().map(\.toolTip), ["git fetch --all --prune", "git fetch --no-prune origin", "git fetch --prune origin", "git fetch --all --tags"])
        XCTAssertEqual(firstEnabled(menu), "Fetch all Remotes")
    }

    /// Without a remote there is nothing to fetch from: the entries stay visible but disabled, and say why.
    func testFetchMenuIsDisabledWithoutRemotes() async throws {
        try fixture.repo.git("remote", "remove", "origin")
        tab.fetch.refreshRemotes()
        try await waitUntil { self.tab.fetch.remotes.isEmpty }
        let menu = tab.menus.toolbarMenu(.fetch)
        XCTAssertEqual(menu.outline, [["Fetch all Remotes (No remote configured)"], ["Fetch Tags from all Remotes (No remote configured)"]])
        XCTAssertNil(firstEnabled(menu))
    }

    /// The configured mode leads, marked as the default, below a header that names the upstream; the header never runs.
    func testPullMenuLeadsWithTheDefaultModeBelowItsUpstream() throws {
        let menu = tab.menus.toolbarMenu(.pull)
        let entries = try XCTUnwrap(menu.first)
        XCTAssertEqual(menu.count, 1)
        XCTAssertEqual(entries.first?.plainTitle, "Pull origin/main into main")
        XCTAssertFalse(entries[0].isEnabled)
        XCTAssertEqual(entries.dropFirst().compactMap(\.marker), ["Default"])
        XCTAssertNotNil(entries[1].marker, "the default mode comes first")
        XCTAssertEqual(Set(entries.dropFirst().map(\.plainTitle)), ["Fast-Forward only", "Merge", "Rebase"])
        XCTAssertEqual(firstEnabled(menu), entries[1].plainTitle)
    }

    /// Pull needs an upstream and Push a remote; without one the button is disabled and its tooltip says why.
    func testPullAndPushSayWhyTheyCannotRun() async throws {
        XCTAssertNil(tab.upstream.pullBlocked)
        XCTAssertNil(tab.upstream.pushBlocked)
        try fixture.repo.git("branch", "--unset-upstream", "main")
        await tab.upstream.refresh().value
        XCTAssertEqual(tab.upstream.pullBlocked, "main has no upstream")
        XCTAssertNil(tab.upstream.pushBlocked, "the first push sets the upstream")
        XCTAssertEqual(tab.menus.toolbarMenu(.pull).outline, [])
        try fixture.repo.git("remote", "remove", "origin")
        await tab.upstream.refresh().value
        XCTAssertEqual(tab.upstream.pushBlocked, "No remote configured")
        try fixture.repo.git("switch", "-q", "--detach")
        await tab.model.refresh(note: nil)
        await tab.upstream.refresh().value
        XCTAssertEqual(tab.upstream.pullBlocked, "HEAD is detached")
    }

    func testPushMenuPushesToTheUpstreamOrSetsOneFirst() async throws {
        XCTAssertEqual(tab.menus.toolbarMenu(.push).outline, [["Push main to origin/main"], ["Push Tags to origin"]])
        XCTAssertEqual(tab.menus.toolbarMenu(.push).first?.first?.toolTip, "git push origin refs/heads/main:refs/heads/main")
        try fixture.repo.git("branch", "--unset-upstream", "main")
        await tab.upstream.refresh().value
        XCTAssertEqual(firstEnabled(tab.menus.toolbarMenu(.push)), "Push main and Set Upstream…")
    }

    /// A local branch without upstream, checked out or not, is pushed from its menu through the sheet that sets one.
    func testBranchWithoutUpstreamOffersAFirstPush() async throws {
        try fixture.repo.git("branch", "--unset-upstream", "feature")
        await tab.model.refresh(note: nil)
        await tab.upstream.refresh().value
        let menu = tab.menus.menu(for: .branch(try tab.ref("feature")), in: .sidebar)
        XCTAssertEqual(menu.entry("Push feature…")?.toolTip, "git push -u")
        XCTAssertNil(menu.entry("Push feature"))
    }

    /// Conflicted files get the conflict entries named after the branches, never ours and theirs; "Keep File" only where one side deleted the file.
    func testConflictedFilesOfferTheSidesByName() async throws {
        let repo = fixture.repo
        try repo.commit("base", file: "gone.txt", contents: "x\n")
        try repo.git("switch", "-q", "-c", "side")
        try repo.commit("side", file: "c.txt", contents: "side\n")
        try repo.git("rm", "-q", "gone.txt")
        try repo.git("commit", "-q", "-m", "delete")
        try repo.git("switch", "-q", "main")
        try repo.commit("main", file: "c.txt", contents: "main\n")
        try repo.commit("main gone", file: "gone.txt", contents: "y\n")
        XCTAssertThrowsError(try repo.git("merge", "side"))
        await tab.model.refresh(note: nil)
        tab.conflicts.sides = { ConflictSides(ours: RefName.branch("main"), theirs: RefName.branch("side")) }

        let both = tab.conflicts.groups(for: ["c.txt"])
        XCTAssertEqual(both.first?.map(\.plainTitle), ["Accept side", "Accept main", "Delete File", "Mark as resolved", "Restore Conflict Markers"])
        let deleted = tab.conflicts.groups(for: ["gone.txt", "c.txt"])
        XCTAssertNil(deleted.joined().first { $0.plainTitle == "Keep File" }, "c.txt has both sides")
        XCTAssertNotNil(tab.conflicts.groups(for: ["gone.txt"]).joined().first { $0.plainTitle == "Keep File" })
    }

    /// Stashing only staged changes needs some; stashing everything stays the main part's action.
    func testStashMenuOffersStagedOnlyWithStagedChanges() async throws {
        try fixture.repo.write("one.txt", "edited\n")
        await tab.model.refresh(note: nil)
        XCTAssertEqual(tab.menus.toolbarMenu(.stash).outline.joined().map { $0 }, ["Stash all changes", "Stash with Message…", "Stash staged changes only (Nothing staged)"])
        try fixture.repo.git("add", "one.txt")
        await tab.model.refresh(note: nil)
        XCTAssertTrue(tab.menus.toolbarMenu(.stash).entry("Stash staged changes only")?.isEnabled ?? false)
    }

    // MARK: File menu

    private func file(_ path: String, _ source: DiffSource, state: FileState? = .modified) -> FileRowView.Model {
        FileRowView.Model(selection: FileSelection(path: path, originalPath: nil, source: source), letter: "M", color: .labelColor, stat: nil, note: nil, state: state)
    }

    /// One changed file: stage or discard, open it, copy its path (⌥ for the full path).
    func testFileMenuOfOneUnstagedFile() throws {
        try fixture.repo.write("one.txt", "edited\n")
        let menu = tab.menus.fileMenu(for: [file("one.txt", .unstaged)])
        XCTAssertEqual(menu.outline[0], ["Stage", "Discard…"])
        XCTAssertEqual(menu.outline[1].first, "Open in diff tool")
        XCTAssertEqual(menu.outline[1].suffix(2), ["Open with default app", "Show in Finder"])
        XCTAssertEqual(menu.outline[2], ["Copy path", "Copy full path"])
        XCTAssertEqual(menu[2][1].alternateModifiers, .option)
        XCTAssertEqual(menu.outline.count, 3, "nothing rewrites a working-directory file beyond Discard")
    }

    /// An untracked file is discarded like a tracked one; it goes to the Trash, which the question says.
    func testDiscardingAnUntrackedFileMovesItToTheTrash() async throws {
        try fixture.repo.write("new.txt", "new\n")
        await tab.model.refresh(note: nil)
        let menu = tab.menus.fileMenu(for: [file("new.txt", .untracked, state: .added)])
        XCTAssertEqual(menu.outline[0], ["Stage", "Discard…"])
        tab.prompter.confirmations = [true]
        try XCTUnwrap(menu.entry("Discard…")).run()
        let path = fixture.repo.url.appendingPathComponent("new.txt").path
        try await waitUntil { !FileManager.default.fileExists(atPath: path) }
        XCTAssertEqual(tab.prompter.asked, ["Discard Changes?"])
    }

    /// With several files an entry that does not fit every one stays visible and says why.
    func testFileMenuOfMixedFilesExplainsDisabledEntries() throws {
        let menu = tab.menus.fileMenu(for: [file("one.txt", .unstaged), file("two.txt", .staged)])
        XCTAssertEqual(menu.entry("Stage")?.disabledReason, "Not every selected file has unstaged changes")
        XCTAssertEqual(menu.entry("Unstage")?.disabledReason, "Not every selected file is staged")
        XCTAssertEqual(menu.entry("Open in diff tool")?.disabledReason, "The diff tool opens one file at a time")
    }

    /// Files of a commit can be restored or reverted, but only when they all belong to the same commit.
    func testFileMenuOfCommitFilesRestoresOnlyWithinOneCommit() throws {
        let head = try XCTUnwrap(tab.model.rowIndex(of: fixture.head).map { tab.model.commits[$0] })
        let tagged = try XCTUnwrap(tab.model.rowIndex(of: fixture.tagged).map { tab.model.commits[$0] })
        let same = tab.menus.fileMenu(for: [file("three.txt", .commit(head))])
        XCTAssertEqual(same.outline.last, ["Restore from this Commit", "Revert changes of this Commit"])
        let mixed = tab.menus.fileMenu(for: [file("three.txt", .commit(head)), file("two.txt", .commit(tagged))])
        XCTAssertEqual(mixed.entry("Restore from this Commit")?.disabledReason, "The selected files belong to different Commits")
    }

    // MARK: Diff options

    /// Ignoring all whitespace and only its amount exclude each other; the checkmarks follow the options.
    func testDiffOptionsShowTheirStateAndExcludeEachOther() throws {
        var options = DiffOptions()
        options.whitespace.ignoring = .all
        var changed = options
        let menu = MenuBuilder.diffOptions(options) { edit in edit(&changed) }
        XCTAssertEqual(menu.outline, [["Show invisible characters"], ["Word diff"], ["Ignore whitespace", "Ignore whitespace changes", "Ignore blank lines"]])
        XCTAssertEqual(menu.joined().filter(\.isChecked).map(\.plainTitle), ["Ignore whitespace"])
        try XCTUnwrap(menu.entry("Ignore whitespace changes")).run()
        XCTAssertEqual(changed.whitespace.ignoring, .changes)
        changed = options
        try XCTUnwrap(menu.entry("Ignore whitespace")).run()
        XCTAssertEqual(changed.whitespace.ignoring, .nothing, "choosing the checked option turns it off")
    }
}
