import AppKit
import XCTest
import GitEngine
@testable import GitBonsai

/// The main screens rendered off screen in light and dark, against references in `__Snapshots__` (see `Snapshot`).
@MainActor
final class SnapshotTests: XCTestCase {
    private static let size = CGSize(width: 1200, height: 720)
    private static let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// main with a tag, a feature branch merged back and one ahead, with fixed dates so the SHAs stay the same; `Snapshot` blanks the relative dates.
    private func repository() throws -> FixtureRepo {
        // A fixed folder: its name shows in the sidebar.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let repo = try FixtureRepo(at: folder)
        func date(hoursAgo: Int) -> String { "2024-01-01T\(String(format: "%02d", 12 - hoursAgo)):00:00+0000" }
        try repo.write("README.md", "# Bonsai\n")
        _ = try repo.git(["add", "-A"], date: date(hoursAgo: 9))
        _ = try repo.git(["commit", "-q", "-m", "Plant the seed"], date: date(hoursAgo: 9))
        _ = try repo.git(["tag", "v0.1"])
        _ = try repo.git(["checkout", "-q", "-b", "feature/leaves"])
        try repo.write("Leaves.swift", "struct Leaf {\n\tlet color: String\n}\n")
        _ = try repo.git(["add", "-A"], date: date(hoursAgo: 8))
        _ = try repo.git(["commit", "-q", "-m", "Grow the first leaves"], date: date(hoursAgo: 8))
        _ = try repo.git(["checkout", "-q", "main"])
        try repo.write("README.md", "# Bonsai\n\nA small tree.\n")
        _ = try repo.git(["commit", "-q", "-am", "Describe the tree"], date: date(hoursAgo: 7))
        _ = try repo.git(["merge", "-q", "--no-ff", "-m", "Merge feature/leaves", "feature/leaves"], date: date(hoursAgo: 6))
        _ = try repo.git(["checkout", "-q", "feature/leaves"])
        try repo.write("Leaves.swift", "struct Leaf {\n\tlet color: String  \n\tlet size: Int\n}\n")
        _ = try repo.git(["commit", "-q", "-am", "Measure the leaves"], date: date(hoursAgo: 5))
        _ = try repo.git(["checkout", "-q", "main"])
        return repo
    }

    /// A loaded tab in an off-screen window, with the newest commit selected.
    private func tab(in repo: FixtureRepo, appearance: NSAppearance.Name, size: CGSize = SnapshotTests.size, prepare: (UserDefaults) -> Void = { _ in }) async throws -> (TabFixture, RepositoryViewController, NSWindow) {
        let fixture = TabFixture(repo)
        prepare(fixture.context.app.persistence.defaults)
        // The history draws its dates itself, where `Snapshot` cannot blank them; they would change as the fixed dates age.
        fixture.context.app.persistence.defaults.set(["date"], forKey: "hiddenColumns")
        let controller = RepositoryViewController(context: fixture.context)
        let window = Snapshot.window(for: controller.view, size: size, appearance: appearance)
        if fixture.model.history.commitCount == 0 { fixture.model.load() }
        try await waitUntil { !fixture.model.isLoading && fixture.model.history.commitCount > 0 }
        controller.history.select(row: 0, scroll: true)
        try await settle()
        return (fixture, controller, window)
    }

    /// Lets loads started by a selection, such as the commit details, finish.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    func testHistoryWithCommitDetails() async throws {
        let repo = try repository()
        for (name, look) in Self.looks {
            let (_, controller, window) = try await tab(in: repo, appearance: look)
            try Snapshot.assert(controller.view, named: "history-\(name)")
            window.close()
        }
    }

    /// Eight branches side by side in a graph column that shows five lanes, scrolled right: avatars of lanes out of view stay pinned in the strip at its right end.
    func testHistoryWithPinnedAvatars() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots-lanes", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let repo = try FixtureRepo(at: folder)
        _ = try repo.commit("Plant the seed", date: "2024-01-01T00:00:00+0000")
        for branch in 1...8 {
            _ = try repo.git(["checkout", "-q", "-b", "branch-\(branch)", "main"])
            try repo.write("b\(branch).txt", "\(branch)\n")
            _ = try repo.git(["add", "-A"], date: "2024-01-01T0\(branch):00:00+0000")
            _ = try repo.git(["commit", "-q", "-m", "Grow branch \(branch)"], date: "2024-01-01T0\(branch):00:00+0000")
        }
        _ = try repo.git(["checkout", "-q", "main"])
        for (name, look) in Self.looks {
            let (_, controller, window) = try await tab(in: repo, appearance: look)
            let columns = controller.history.columnsController
            let graph = try XCTUnwrap(columns.columns.layout(in: window.frame.width).graph)
            _ = columns.scrollGraph(by: -2 * Theme.Graph.lane, at: NSPoint(x: graph.lowerBound + 1, y: 0))
            try await settle()
            try Snapshot.assert(controller.view, named: "history-pinned-avatars-\(name)")
            window.close()
        }
    }

    func testDiffOfACommit() async throws {
        let repo = try repository()
        for (name, look) in Self.looks {
            let (fixture, controller, window) = try await tab(in: repo, appearance: look)
            let head = try XCTUnwrap(fixture.model.commits.first)
            controller.openFile(FileSelection(path: "Leaves.swift", originalPath: nil, source: .commit(head)))
            try await settle()
            try Snapshot.assert(controller.view, named: "diff-\(name)")
            window.close()
        }
    }

    /// A merge stopped on conflicts in two files: the banner counts them and the working directory lists them.
    func testOperationBannerWithConflicts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots-banner", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let repo = try FixtureRepo(at: folder)
        let date = "2024-01-01T08:00:00+0000"
        try repo.write("Leaves.swift", "let color = \"green\"\n")
        try repo.write("Roots.swift", "let depth = 1\n")
        _ = try repo.git(["add", "-A"], date: date)
        _ = try repo.git(["commit", "-q", "-m", "Plant the seed"], date: date)
        _ = try repo.git(["checkout", "-q", "-b", "feature/leaves"])
        try repo.write("Leaves.swift", "let color = \"red\"\n")
        try repo.write("Roots.swift", "let depth = 2\n")
        _ = try repo.git(["commit", "-q", "-am", "Grow red and deep"], date: date)
        _ = try repo.git(["checkout", "-q", "main"])
        try repo.write("Leaves.swift", "let color = \"gold\"\n")
        try repo.write("Roots.swift", "let depth = 3\n")
        _ = try repo.git(["commit", "-q", "-am", "Grow gold and deeper"], date: date)
        _ = try? repo.git(["merge", "feature/leaves"], date: date)
        for (name, look) in Self.looks {
            let (_, controller, window) = try await tab(in: repo, appearance: look)
            controller.showWorkingDirectory()
            try await settle()
            try Snapshot.assert(controller.view, named: "banner-conflicts-\(name)")
            window.close()
        }
    }

    /// A rebase of a long branch onto another long one in a narrow history column: the names give way, the step and the conflict count stay whole.
    func testOperationBannerWithLongNamesInANarrowColumn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots-banner-narrow", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let repo = try FixtureRepo(at: folder)
        let date = "2024-01-01T08:00:00+0000"
        let feature = "feature/grow-the-leaves-in-autumn-colours"
        let base = "release/spring-planting-season-2024"
        try repo.write("Leaves.swift", "let color = \"green\"\n")
        _ = try repo.git(["add", "-A"], date: date)
        _ = try repo.git(["commit", "-q", "-m", "Plant the seed"], date: date)
        _ = try repo.git(["checkout", "-q", "-b", base])
        try repo.write("Leaves.swift", "let color = \"gold\"\n")
        _ = try repo.git(["commit", "-q", "-am", "Colour the leaves gold"], date: date)
        _ = try repo.git(["checkout", "-q", "-b", feature, "main"])
        try repo.write("Leaves.swift", "let color = \"red\"\n")
        _ = try repo.git(["commit", "-q", "-am", "Colour the leaves red"], date: date)
        _ = try? repo.git(["rebase", base], date: date)
        for (name, look) in Self.looks {
            let (_, controller, window) = try await tab(in: repo, appearance: look, size: NSSize(width: 1200, height: 400))
            try await settle()
            try Snapshot.assert(controller.view, named: "banner-narrow-\(name)")
            window.close()
        }
    }

    /// The "Create Tag" form as the commit menu opens it, filled in.
    /// The command bar over the conflict view of a rebase that stopped: it opens below the operation banner, as it opens below the history header, never under the window's title bar.
    func testCommandBarOverConflictView() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots-conflict", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let repo = try FixtureRepo(at: folder)
        let date = "2024-01-01T08:00:00+0000"
        try repo.write("Leaves.swift", "let color = \"green\"\n")
        _ = try repo.git(["add", "-A"], date: date)
        _ = try repo.git(["commit", "-q", "-m", "Plant the seed"], date: date)
        _ = try repo.git(["checkout", "-q", "-b", "feature/leaves"])
        try repo.write("Leaves.swift", "let color = \"red\"\n")
        _ = try repo.git(["commit", "-q", "-am", "Colour the leaves red"], date: date)
        _ = try repo.git(["checkout", "-q", "main"])
        try repo.write("Leaves.swift", "let color = \"gold\"\n")
        _ = try repo.git(["commit", "-q", "-am", "Colour the leaves gold"], date: date)
        _ = try repo.git(["checkout", "-q", "feature/leaves"])
        _ = try? repo.git(["rebase", "main"], date: date)
        for (name, look) in Self.looks {
            let (fixture, controller, window) = try await tab(in: repo, appearance: look)
            controller.showConflict("Leaves.swift")
            try await waitUntil { controller.historyPane.current === controller.conflicts.view }
            try await settle()
            let bar = CommandBarController(persistence: fixture.context.app.persistence)
            bar.open(in: window, commands: [Command(id: "probe", title: .verbatim("Open in Editor"), glyph: .symbol("chevron.left.forwardslash.chevron.right"), context: "repo · Visual Studio Code") {}])
            let panel = try XCTUnwrap(window.contentView?.subviews.compactMap { ($0 as? CommandBarOverlay)?.panel }.first)
            window.contentView?.layoutSubtreeIfNeeded()
            let paneTop = controller.historyPane.convert(controller.historyPane.bounds, to: nil).maxY
            let panelTop = panel.convert(panel.bounds, to: nil).maxY
            XCTAssertLessThan(panelTop, paneTop, "The command bar must open inside the history column, below toolbar and banner")
            try Snapshot.assert(controller.view, named: "commandBar-conflict-\(name)")
            bar.close()
            window.close()
        }
    }

    func testCreateTagForm() async throws {
        let repo = try repository()
        for (name, look) in Self.looks {
            let (fixture, _, window) = try await tab(in: repo, appearance: look)
            try XCTUnwrap(fixture.menus.rowMenu(forRow: 0).entry("Create Tag…")).run()
            try await waitUntil { fixture.prompter.lastForm != nil }
            let form = try XCTUnwrap(fixture.prompter.lastForm)
            form.fill(["name": "v0.2"])
            form.prepare()
            form.alert.window.appearance = NSAppearance(named: look)
            form.alert.applyRefText()
            try Snapshot.assert(sheet: form.alert.window, named: "form-createTag-\(name)")
            window.close()
        }
    }

    /// The worktree's pill and the checkbox with the branch pill each keep their own line, also with long names.
    func testRemoveWorktreeForm() throws {
        for (name, look) in Self.looks {
            let form = ActionForm(title: LocalizedStringResource("worktree.remove.title", defaultValue: "Remove Worktree?", bundle: .module), names: RefString(marked: RefName.worktree("engineering-docs-domain-with-a-much-longer-folder-name")), confirm: LocalizedStringResource("worktree.remove.confirm", defaultValue: "Remove", bundle: .module))
            form.addCheckbox(LocalizedStringResource("worktree.remove.deleteBranch", defaultValue: "Also delete branch \(RefName.branch("codex/engineering-docs-domain-with-a-much-longer-branch-name"))", bundle: .module), checked: true)
            form.prepare()
            form.alert.window.appearance = NSAppearance(named: look)
            form.alert.applyRefText()
            try Snapshot.assert(sheet: form.alert.window, named: "form-removeWorktree-\(name)")
        }
    }

    /// A long squash message opens at its first line, inset from the border, in a box that grows to its limit and scrolls.
    func testSquashForm() throws {
        let paragraph = "Nothing follows the parent links in the title line any more, so they sit in the same place for commits, merges, stashes and the working directory."
        let message = "Keep the parent links at the right end of the title line\n\n" + Array(repeating: paragraph, count: 4).joined(separator: "\n\n")
        for (name, look) in Self.looks {
            let form = ActionForm(title: LocalizedStringResource("rebase.squash.sheet.title", defaultValue: "Squash \(2) Commits", bundle: .module), confirm: LocalizedStringResource("rebase.squash.sheet.confirm", defaultValue: "Squash", bundle: .module))
            form.addMessage(label: LocalizedStringResource("rebase.squash.sheet.message", defaultValue: "Message", bundle: .module), value: message)
            form.prepare()
            form.alert.window.appearance = NSAppearance(named: look)
            form.alert.applyRefText()
            try Snapshot.assert(sheet: form.alert.window, named: "form-squash-\(name)")
        }
    }

    /// A confirmation with two long names wraps them as full pills above its sentence.
    func testLongNameConfirmation() throws {
        for (name, look) in Self.looks {
            let alert = NSAlert()
            alert.setConfirmation(LocalizedStringResource("branch.deleteWithWorktree.title", defaultValue: "Delete Branch and Worktree?", bundle: .module), names: RefString(marked: RefName.branch("task/TIMR-13355-migrate-existing-requests-to-the-new-approval-flow") + " " + RefName.worktree("timr-backend-TIMR-13355-migrate-existing-requests")))
            alert.addButton(withTitle: "Delete Worktree and Branch")
            alert.addButton(withTitle: "Cancel")
            alert.window.appearance = NSAppearance(named: look)
            alert.layout()
            try Snapshot.assert(sheet: alert.window, named: "confirm-longNames-\(name)")
        }
    }

    /// A failure sheet with its actions and git's output.
    func testFailureSheet() throws {
        for (name, look) in Self.looks {
            let sheet = FailureSheet(title: RefString(verbatim: "Push rejected"), summary: RefString(verbatim: "The remote has commits that main does not have."), details: "! [rejected]        main -> main (fetch first)\nerror: failed to push some refs", actions: [FailureAction(title: "Pull") {}], pasteboard: Pasteboard(pasteboard: NSPasteboard(name: NSPasteboard.Name("snapshots"))))
            sheet.window.appearance = NSAppearance(named: look)
            sheet.details?.isExpanded = true
            sheet.fitToContent()
            try Snapshot.assert(sheet: sheet.window, named: "failure-\(name)")
        }
    }

    /// Invisible characters in changed lines: tabs, trailing spaces.
    func testDiffWithInvisibles() async throws {
        let repo = try repository()
        for (name, look) in Self.looks {
            let (fixture, controller, window) = try await tab(in: repo, appearance: look) { DiffPreferences(defaults: $0).options = DiffOptions(showsInvisibles: true) }
            let head = try XCTUnwrap(fixture.model.commits.first)
            controller.openFile(FileSelection(path: "Leaves.swift", originalPath: nil, source: .commit(head)))
            try await settle()
            try Snapshot.assert(controller.view, named: "diff-invisibles-\(name)")
            window.close()
        }
    }

    /// The sidebar with every kind of row: worktrees, a folder of branches, a branch ahead of its upstream, a remote and a collapsed folder.
    func testSidebar() async throws {
        let repo = try repository()
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots-sidebar-remote.git", isDirectory: true)
        let linked = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots-linked", isDirectory: true)
        try? FileManager.default.removeItem(at: remote)
        try? FileManager.default.removeItem(at: linked)
        defer {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: linked)
        }
        _ = try repo.git(["clone", "-q", "--bare", repo.url.path, remote.path])
        _ = try repo.git(["remote", "add", "origin", remote.path])
        _ = try repo.git(["fetch", "-q", "origin"])
        _ = try repo.git(["branch", "-q", "--set-upstream-to=origin/main", "main"])
        _ = try repo.git(["commit", "-q", "--allow-empty", "-m", "Water the tree"], date: "2024-01-01T08:00:00+0000")
        _ = try repo.git(["branch", "bugfix/roots"])
        _ = try repo.git(["branch", "bugfix/bark"])
        _ = try repo.git(["worktree", "add", "-q", linked.path, "feature/leaves"])
        for (name, look) in Self.looks {
            let (fixture, controller, window) = try await tab(in: repo, appearance: look)
            try await waitUntil { fixture.model.worktrees.count == 2 && fixture.model.worktrees.allSatisfy { $0.status != nil } }
            try await settle()
            let sidebar = controller.sidebar
            if let folder = sidebar.row(of: "folder:remote:origin/feature/"), let node = sidebar.node(atRow: folder) { sidebar.toggle(node) }
            try Snapshot.assert(sidebar, named: "sidebar-\(name)")
            window.close()
        }
    }

    /// The "Whole file" mode in the text viewer: old and new numbers, washed changes, the changed part marked, syntax colours and invisibles.
    func testWholeFileViewer() async throws {
        let repo = try repository()
        for (name, look) in Self.looks {
            let (fixture, controller, window) = try await tab(in: repo, appearance: look) { defaults in
                let preferences = DiffPreferences(defaults: defaults)
                preferences.mode = .file
                preferences.options = DiffOptions(showsInvisibles: true)
            }
            let head = try XCTUnwrap(fixture.model.commits.first)
            controller.openFile(FileSelection(path: "Leaves.swift", originalPath: nil, source: .commit(head)))
            try await settle()
            try Snapshot.assert(controller.view, named: "whole-file-\(name)")
            window.close()
        }
    }

    /// The Tags list as its popover shows it.
    func testTagsPanel() async throws {
        let repo = try repository()
        _ = try repo.git(["tag", "-a", "v0.2", "-m", "Second release", "HEAD~1"])
        for (name, look) in Self.looks {
            let fixture = TabFixture(repo)
            try await fixture.load()
            let list = fixture.tags.popover.list
            let window = Snapshot.window(for: list, size: list.fittingSize, appearance: look)
            try Snapshot.assert(list, named: "panel-tags-\(name)")
            window.close()
        }
    }

    /// The Tags list with a remote: the switch in the title line and a tag of each kind.
    func testTagsPanelWithRemote() async throws {
        let repo = try repository()
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-snapshots-remote.git", isDirectory: true)
        try? FileManager.default.removeItem(at: remote)
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = try repo.git(["clone", "-q", "--bare", repo.url.path, remote.path])
        _ = try repo.git(["remote", "add", "origin", remote.path])
        _ = try repo.git(["-C", remote.path, "tag", "v0.0", "HEAD~1"])
        _ = try repo.git(["-C", remote.path, "tag", "-f", "v0.1", "feature/leaves"])
        _ = try repo.git(["tag", "v0.2", "HEAD~1"])
        for (name, look) in Self.looks {
            let fixture = TabFixture(repo)
            try await fixture.load()
            // The remote answers on its own; the list shows its marks only once it has.
            try await waitUntil { fixture.tags.isSettled && !fixture.tags.popover.list.isBusy }
            let list = fixture.tags.popover.list
            let window = Snapshot.window(for: list, size: list.fittingSize, appearance: look)
            try Snapshot.assert(list, named: "panel-tags-remote-\(name)")
            list.selectScope(2)
            try Snapshot.assert(list, named: "panel-tags-remote-diverging-\(name)")
            window.close()
        }
    }

    /// A merge names both parents in the title line beside its SHA.
    func testMergeDetails() async throws {
        let repo = try repository()
        let merge = try repo.git(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
        for (name, look) in Self.looks {
            let (fixture, controller, window) = try await tab(in: repo, appearance: look)
            controller.history.select(row: try fixture.row(of: merge), scroll: true)
            try await settle()
            try Snapshot.assert(controller.view, named: "merge-\(name)")
            window.close()
        }
    }

    /// A stash with staged, unstaged and untracked changes: two areas like the working directory, one parent, no helper commits in the history.
    func testStashDetails() async throws {
        let repo = try repository()
        try repo.write("README.md", "# Bonsai\n\nA small tree, staged.\n")
        _ = try repo.git(["add", "README.md"])
        try repo.write("README.md", "# Bonsai\n\nA small tree, staged and edited.\n")
        try repo.write("Notes.txt", "untracked\n")
        _ = try repo.git(["stash", "push", "-u", "-q", "-m", "Half a tree"], date: "2024-01-01T08:00:00+0000")
        for (name, look) in Self.looks {
            let (fixture, controller, window) = try await tab(in: repo, appearance: look)
            let stash = try XCTUnwrap(fixture.model.stashes.first)
            controller.history.select(row: try fixture.row(of: stash.commitID), scroll: true)
            try await settle()
            try Snapshot.assert(controller.view, named: "stash-\(name)")
            window.close()
        }
    }

    /// The working directory with its parent link in the place a commit has it.
    func testWorkingDirectoryDetails() async throws {
        let repo = try repository()
        try repo.write("README.md", "# Bonsai\n\nA small tree, edited.\n")
        for (name, look) in Self.looks {
            let (_, controller, window) = try await tab(in: repo, appearance: look)
            try Snapshot.assert(controller.view, named: "workdir-\(name)")
            window.close()
        }
    }

    /// The New Branch sheet starting at HEAD.
    func testNewBranchSheet() async throws {
        let repo = try repository()
        for (name, look) in Self.looks {
            let repository = Repository(path: repo.path)
            let tips = try await repository.refTips()
            let head = await repository.commitSummary("HEAD")
            let current: [RefCatalog.Item] = head.map { [.head(branch: "main", commit: $0)] } ?? []
            let picker = RefPicker(repository: repository)
            picker.setCatalog(RefCatalog(tips: tips, current: current), selection: current.first)
            let form = NewBranchViewController(repository: repository, existingBranches: ["main", "feature/leaves"], picker: picker) { "/tmp/\($0)" }
            let sheet = NewBranchSheet(form: form)
            sheet.window.appearance = NSAppearance(named: look)
            form.nameInput.stringValue = "feature/roots"
            sheet.window.setContentSize(form.view.fittingSize)
            try Snapshot.assert(sheet: sheet.window, named: "sheet-newBranch-\(name)")
        }
    }

    /// Every settings section.
    func testSettingsPanes() async throws {
        for (name, look) in Self.looks {
            let suite = "app.gitbonsai.snapshots.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsWindowController(settings: AppSettings(persistence: Persistence(defaults: defaults)))
            let window = try XCTUnwrap(settings.window)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look)
            for section in SettingsWindowController.Section.allCases {
                settings.select(section)
                try await Task.sleep(for: .milliseconds(300))
                try Snapshot.assert(sheet: window, named: "settings-\(section.rawValue)-\(name)")
            }
            window.close()
        }
    }

    /// The empty tab with recent repositories.
    func testWelcome() async throws {
        let repo = try repository()
        for (name, look) in Self.looks {
            let fixture = TabFixture(repo)
            // No repository folders: the default would list the machine's own repositories.
            fixture.context.settings.repositoryFolders = []
            let welcome = WelcomeView(settings: fixture.context.settings, discovery: fixture.context.app.discovery)
            welcome.recents = [repo.path]
            let window = Snapshot.window(for: welcome, size: Self.size, appearance: look)
            welcome.refresh()
            try await settle()
            try Snapshot.assert(welcome, named: "welcome-\(name)")
            window.close()
        }
    }
}
