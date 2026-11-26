import AppKit
import GitEngine
import XCTest
@testable import GitBonsai

/// The sidebar's tree from refs and worktrees, which sections start collapsed, and how the outline keeps and restores what the user opened.
@MainActor
final class SidebarTests: XCTestCase {
    private func ref(_ fullName: String, head: Bool = false, ahead: Int? = nil) -> Ref {
        let kind: GitEngine.RefKind
        let name: String
        if fullName.hasPrefix("refs/heads/") {
            name = String(fullName.dropFirst("refs/heads/".count))
            kind = .localBranch
        } else if fullName.hasPrefix("refs/remotes/") {
            name = String(fullName.dropFirst("refs/remotes/".count))
            kind = .remoteBranch(remote: String(name.prefix { $0 != "/" }))
        } else {
            name = String(fullName.dropFirst("refs/tags/".count))
            kind = .tag
        }
        return Ref(fullName: fullName, name: name, kind: kind, target: "c0ffee", isHead: head, upstream: nil, ahead: ahead, behind: nil)
    }

    private func ids(_ nodes: [SidebarNode]) -> [String] { nodes.map(\.id) }

    func testTreeGroupsBranchesIntoFoldersAndOrdersRemotesWithOriginFirst() {
        let refs = [
            ref("refs/heads/main", head: true),
            ref("refs/heads/feature/b"), ref("refs/heads/feature/a"), ref("refs/heads/fix"),
            ref("refs/tags/v1"), ref("refs/tags/v2"),
            ref("refs/remotes/upstream/main"),
            ref("refs/remotes/origin/HEAD"), ref("refs/remotes/origin/main"),
        ]
        var outline = SidebarOutline()
        let roots = outline.nodes(from: SidebarContent(refs: refs, remotes: ["origin", "upstream", "empty"]))

        XCTAssertEqual(ids(roots), ["section:worktrees", "panel:tags", "section:local", "section:remote:origin", "section:remote:empty", "section:remote:upstream", SidebarItem.addRemoteTarget], "a configured remote without branches still gets its header")
        guard case .row(let tags) = roots[1].item else { return XCTFail("tags row") }
        XCTAssertEqual(tags.value, "2")
        let local = roots[2]
        XCTAssertEqual(ids(local.children), ["workingDirectory", "panel:stashes", "folder:local/feature/", "ref:refs/heads/fix", "ref:refs/heads/main"], "folders sort among branches by name")
        XCTAssertEqual(ids(local.children[2].children), ["ref:refs/heads/feature/a", "ref:refs/heads/feature/b"])
        XCTAssertEqual(local.children[2].expansionKey, "local/feature/")
        XCTAssertEqual(ids(roots[3].children), ["ref:refs/remotes/origin/main"], "the remote's HEAD is left out")
        guard case .row(let main) = local.children[4].item else { return XCTFail("main row") }
        XCTAssertTrue(main.isCheckedOut)
        XCTAssertNil(main.checkout, "the checked-out branch has nothing to check out")
    }

    func testOnlyTheFirstSmallRemoteStartsOpenAndALaterChoiceIsKept() {
        let many = (0...SidebarOutline.expandedRemoteLimit).map { ref("refs/remotes/big/b\($0)") }
        var outline = SidebarOutline()
        _ = outline.nodes(from: SidebarContent(refs: [ref("refs/remotes/origin/main")] + many, remotes: ["origin", "big"]))
        XCTAssertFalse(outline.isCollapsed("remote:origin"))
        XCTAssertTrue(outline.isCollapsed("remote:big"), "later remotes start collapsed")

        var small = SidebarOutline()
        _ = small.nodes(from: SidebarContent(refs: many.map { ref($0.fullName.replacingOccurrences(of: "/big/", with: "/origin/")) }, remotes: ["origin"]))
        XCTAssertTrue(small.isCollapsed("remote:origin"), "even origin starts collapsed with more branches than the limit")

        outline.setCollapsed("remote:big", false)
        _ = outline.nodes(from: SidebarContent(refs: many, remotes: ["big"]))
        XCTAssertFalse(outline.isCollapsed("remote:big"), "a section seen before keeps the user's choice")
    }

    func testExpandToShowOpensSectionAndFolderAndNamesTheNodeOfTheTree() {
        let refs = [ref("refs/heads/feature/a"), ref("refs/remotes/origin/fix/b")]
        var outline = SidebarOutline(state: OutlineState(collapsed: ["local", "local/feature/", "remote:origin", "remote:origin/fix/"]))
        let local = outline.expand(toShow: RefJump.Target(kind: .localBranch(isHead: false), name: "feature/a", commit: nil, detail: nil))
        let remote = outline.expand(toShow: RefJump.Target(kind: .remoteBranch(remote: "origin"), name: "origin/fix/b", commit: nil, detail: nil))
        XCTAssertTrue(outline.state.collapsed.isEmpty)
        let all = outline.nodes(from: SidebarContent(refs: refs, remotes: ["origin"])).flatMap { [$0] + $0.children + $0.children.flatMap(\.children) }
        XCTAssertNotNil(all.first { $0.id == local }, "the id it returns is the node's")
        XCTAssertNotNil(all.first { $0.id == remote })
    }

    /// A loaded sidebar in a window, on a repository with a folder of branches.
    private func sidebar() async throws -> (TabFixture, SidebarView, NSWindow) {
        let repo = try FixtureRepo()
        _ = try repo.commit("Root")
        _ = try repo.git("branch", "feature/one")
        _ = try repo.git("branch", "feature/two")
        let fixture = TabFixture(repo)
        fixture.model.load()
        try await waitUntil { fixture.model.sidebarRevision != nil && !fixture.model.isLoading }
        let sidebar = SidebarView(sessions: fixture.context.app.sessions)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar)
        sidebar.reload(from: fixture.model)
        return (fixture, sidebar, window)
    }

    func testCollapsingAFolderIsStoredAndRestoredByANewSidebar() async throws {
        let (fixture, sidebar, window) = try await sidebar()
        defer { window.close() }
        let folder = try XCTUnwrap(sidebar.row(of: "folder:local/feature/"))
        XCTAssertNotNil(sidebar.row(of: "ref:refs/heads/feature/one"), "folders start open")

        sidebar.toggle(try XCTUnwrap(sidebar.node(atRow: folder)))
        XCTAssertNil(sidebar.row(of: "ref:refs/heads/feature/one"))
        XCTAssertEqual(fixture.context.app.sessions.sidebarState(for: fixture.model.repository.path)?.collapsed.contains("local/feature/"), true)

        sidebar.reload(from: fixture.model)
        XCTAssertNil(sidebar.row(of: "ref:refs/heads/feature/one"), "a reload keeps it collapsed")

        let restored = SidebarView(sessions: fixture.context.app.sessions)
        restored.reload(from: fixture.model)
        XCTAssertNotNil(restored.row(of: "folder:local/feature/"))
        XCTAssertNil(restored.row(of: "ref:refs/heads/feature/one"), "a new sidebar restores the stored state")
    }

    func testCollapsedSectionKeepsItsFoldersStateWhenOpenedAgain() async throws {
        let (_, sidebar, window) = try await sidebar()
        defer { window.close() }
        sidebar.toggle(try XCTUnwrap(sidebar.node(atRow: XCTUnwrap(sidebar.row(of: "folder:local/feature/")))))
        let local = try XCTUnwrap(sidebar.node(atRow: XCTUnwrap(sidebar.row(of: "section:local"))))
        sidebar.toggle(local)
        XCTAssertNil(sidebar.row(of: "folder:local/feature/"))
        sidebar.toggle(local)
        sidebar.toggle(try XCTUnwrap(sidebar.node(atRow: XCTUnwrap(sidebar.row(of: "folder:local/feature/")))))
        XCTAssertNotNil(sidebar.row(of: "ref:refs/heads/feature/one"))
        sidebar.toggle(local)
        sidebar.toggle(local)
        XCTAssertNotNil(sidebar.row(of: "ref:refs/heads/feature/one"), "collapsing the section does not collapse the open folder in it")
        sidebar.toggle(try XCTUnwrap(sidebar.node(atRow: XCTUnwrap(sidebar.row(of: "folder:local/feature/")))))
        sidebar.toggle(local)
        XCTAssertNil(sidebar.row(of: "folder:local/feature/"))
        sidebar.toggle(local)
        XCTAssertNotNil(sidebar.row(of: "folder:local/feature/"))
        XCTAssertNil(sidebar.row(of: "ref:refs/heads/feature/one"), "the folder stays as it was")
    }

    func testRevealOpensTheFolderAndSelectsTheBranch() async throws {
        let (fixture, sidebar, window) = try await sidebar()
        defer { window.close() }
        sidebar.toggle(try XCTUnwrap(sidebar.node(atRow: XCTUnwrap(sidebar.row(of: "section:local")))))
        XCTAssertNil(sidebar.row(of: "ref:refs/heads/feature/two"))
        XCTAssertEqual(sidebar.outline.state.collapsed, ["local"])

        sidebar.reveal(RefJump.Target(kind: .localBranch(isHead: false), name: "feature/two", commit: nil, detail: nil))

        let row = try XCTUnwrap(sidebar.row(of: "ref:refs/heads/feature/two"))
        XCTAssertEqual(sidebar.outlineView.selectedRow, row)
        XCTAssertNotNil(fixture.model, "the sidebar holds the model weakly")
    }

    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testSpaceShowsTheBranchAndReturnChecksItOut() async throws {
        let (fixture, sidebar, window) = try await sidebar()
        defer { window.close() }
        var shown: [String] = []
        var checkedOut: [CheckoutTarget] = []
        sidebar.onSelectCommit = { shown.append($0) }
        sidebar.onCheckout = { target, _ in checkedOut.append(target) }
        let row = try XCTUnwrap(sidebar.row(of: "ref:refs/heads/feature/one"))
        sidebar.outlineView.selectRowIndexes([row], byExtendingSelection: false)
        shown = []

        sidebar.outlineView.keyDown(with: key(KeyCode.space, " ", in: window))
        sidebar.outlineView.keyDown(with: key(KeyCode.return, "\r", in: window))

        XCTAssertEqual(shown, [try XCTUnwrap(fixture.model.headSHA)])
        XCTAssertEqual(checkedOut, [.localBranch("feature/one")])
    }

    func testReturnOnAFolderFoldsItAndSpaceOnTheCheckedOutBranchChecksNothingOut() async throws {
        let (_, sidebar, window) = try await sidebar()
        defer { window.close() }
        var checkedOut = 0
        sidebar.onCheckout = { _, _ in checkedOut += 1 }
        sidebar.outlineView.selectRowIndexes([try XCTUnwrap(sidebar.row(of: "folder:local/feature/"))], byExtendingSelection: false)
        sidebar.outlineView.keyDown(with: key(KeyCode.return, "\r", in: window))
        XCTAssertNil(sidebar.row(of: "ref:refs/heads/feature/one"), "⏎ does what a click does where there is nothing to go to")

        sidebar.outlineView.selectRowIndexes([try XCTUnwrap(sidebar.row(of: "ref:refs/heads/main"))], byExtendingSelection: false)
        sidebar.outlineView.keyDown(with: key(KeyCode.return, "\r", in: window))
        XCTAssertEqual(checkedOut, 0)
    }

    func testRowsTellVoiceOverWhatTheyShow() async throws {
        let (_, sidebar, window) = try await sidebar()
        defer { window.close() }
        sidebar.layoutSubtreeIfNeeded()
        func label(_ id: String) throws -> String? {
            let row = try XCTUnwrap(sidebar.row(of: id))
            return sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityLabel()
        }
        XCTAssertEqual(try label("ref:refs/heads/main"), "main, checked out")
        XCTAssertEqual(try label("section:local"), "Local, 3")
        XCTAssertEqual(try label("folder:local/feature/"), "feature/", "an open folder does not read its count")
        let folder = try XCTUnwrap(sidebar.node(atRow: XCTUnwrap(sidebar.row(of: "folder:local/feature/"))))
        sidebar.toggle(folder)
        XCTAssertEqual(try label("folder:local/feature/"), "feature/, 2")
        XCTAssertEqual(sidebar.outlineView.accessibilityLabel(), "Sidebar")
    }

    /// The outline can deliver an arrow key's selection change after the key event is over; it still shows the branch.
    func testASelectionChangeOutsideAKeyEventShowsTheBranch() async throws {
        let (fixture, sidebar, window) = try await sidebar()
        defer { window.close() }
        var shown: [String] = []
        sidebar.onSelectCommit = { shown.append($0) }
        sidebar.outlineView.selectRowIndexes([try XCTUnwrap(sidebar.row(of: "ref:refs/heads/feature/two"))], byExtendingSelection: false)
        XCTAssertEqual(shown, [try XCTUnwrap(fixture.model.headSHA)])
    }

    /// A refresh restores the selected branch without moving the history, which may show another commit meanwhile.
    func testAReloadKeepsTheSelectionWithoutShowingItAgain() async throws {
        let (fixture, sidebar, window) = try await sidebar()
        defer { window.close() }
        sidebar.outlineView.selectRowIndexes([try XCTUnwrap(sidebar.row(of: "ref:refs/heads/feature/two"))], byExtendingSelection: false)
        var shown: [String] = []
        sidebar.onSelectCommit = { shown.append($0) }
        sidebar.reload(from: fixture.model)
        XCTAssertEqual(sidebar.outlineView.selectedRow, try XCTUnwrap(sidebar.row(of: "ref:refs/heads/feature/two")))
        XCTAssertEqual(shown, [])
    }
}
