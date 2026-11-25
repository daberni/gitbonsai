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
    private func tab(in repo: FixtureRepo, appearance: NSAppearance.Name, prepare: (UserDefaults) -> Void = { _ in }) async throws -> (TabFixture, RepositoryViewController, NSWindow) {
        let fixture = TabFixture(repo)
        prepare(fixture.context.app.persistence.defaults)
        // The history draws its dates itself, where `Snapshot` cannot blank them; they would change as the fixed dates age.
        fixture.context.app.persistence.defaults.set(["date"], forKey: "hiddenColumns")
        let controller = RepositoryViewController(context: fixture.context)
        let window = Snapshot.window(for: controller.view, size: Self.size, appearance: appearance)
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

    /// The "Create Tag" form as the commit menu opens it, filled in.
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
