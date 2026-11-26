import GitEngine
import XCTest
@testable import GitBonsai

/// An action that stops on conflicts says so with their number and shows the working directory; the banner counts the open conflicts of every operation kind.
@MainActor
final class ConflictFeedbackTests: XCTestCase {
    private var repo: FixtureRepo!
    private var tab: TabFixture!
    private var base = ""

    /// `main` and `side` both change a.txt and b.txt from a common base; HEAD is on `main`.
    override func setUp() async throws {
        repo = try FixtureRepo(name: "conflict-feedback")
        try repo.write("a.txt", "base\n")
        base = try repo.commit("base", file: "b.txt", contents: "base\n")
        try repo.git("switch", "-q", "-c", "side")
        try repo.write("a.txt", "side\n")
        try repo.commit("side", file: "b.txt", contents: "side\n")
        try repo.git("switch", "-q", "main")
        try repo.write("a.txt", "main\n")
        try repo.commit("main", file: "b.txt", contents: "main\n")
        tab = TabFixture(repo)
        try await tab.load()
    }

    override func tearDown() async throws {
        tab.context.lifecycle.close()
        try? FileManager.default.removeItem(at: repo.url)
    }

    private var runner: ActionRunner { ActionRunner(context: tab.model, prompter: tab.prompter) }

    private func commit(_ ref: String) async throws -> Commit {
        let sha = try repo.git("rev-parse", ref)
        return try XCTUnwrap(tab.model.commits.first { $0.id == sha })
    }

    private func assertStopped(_ toast: String, kind: OperationProgress.Kind) async throws {
        XCTAssertEqual(tab.prompter.toasts, [toast])
        XCTAssertEqual(tab.prompter.reports, [])
        XCTAssertEqual(tab.prompter.conflictsShown, 1)
        let operation = await tab.model.repository.operationInProgress()
        XCTAssertEqual(operation?.kind, kind)
    }

    func testMergeStopToastsWithCountAndShowsConflicts() async throws {
        await runner.perform(failure: "Merge failed", conflict: .operation(.merge), note: "git merge") { try await $0.merge("side") }
        try await assertStopped("Merge stopped on conflicts in 2 files", kind: .merge)
    }

    func testRebaseStopToastsWithCount() async throws {
        await runner.perform(failure: "Rebase failed", conflict: .operation(.rebase), note: "git rebase") { [base] in _ = try await $0.rebase(onto: "side", from: base, branch: "main") }
        try await assertStopped("Rebase stopped on conflicts in 2 files", kind: .rebase)
    }

    func testCherryPickStopToastsWithCount() async throws {
        let side = try await commit("side")
        await runner.perform(failure: "Cherry-pick failed", conflict: .operation(.cherryPick), note: "git cherry-pick") { try await $0.cherryPick(side) }
        try await assertStopped("Cherry-pick stopped on conflicts in 2 files", kind: .cherryPick)
    }

    func testRevertStopToastsWithCount() async throws {
        // Reverting the base against main's changes conflicts in both files.
        let first = try await commit(base)
        await runner.perform(failure: "Revert failed", conflict: .operation(.revert), note: "git revert") { try await $0.revert(first) }
        try await assertStopped("Revert stopped on conflicts in 2 files", kind: .revert)
    }

    /// Without a named stop, the operation git is in names it.
    func testStopWithoutNameTakesTheOperationInProgress() async throws {
        await runner.perform(failure: "Merge failed", note: "git merge") { try await $0.merge("side") }
        XCTAssertEqual(tab.prompter.toasts, ["Merge stopped on conflicts in 2 files"])
    }

    /// The banner counts the open conflicts and follows staging and unstaging without a new read of the operation.
    func testBannerCountFollowsStaging() async throws {
        let banner = OperationBannerController(context: tab.context)
        await runner.perform(failure: "Merge failed", conflict: .operation(.merge), note: "git merge") { try await $0.merge("side") }
        banner.update()
        try await waitUntil { banner.view.text.hasSuffix("2 conflicts") }
        XCTAssertFalse(banner.view.isHidden)

        try repo.write("a.txt", "resolved\n")
        try repo.git("add", "a.txt")
        await tab.model.refresh(note: nil)
        banner.statusChanged()
        XCTAssertTrue(banner.view.text.hasSuffix("1 conflict"), banner.view.text)

        try repo.write("b.txt", "resolved\n")
        try repo.git("add", "b.txt")
        await tab.model.refresh(note: nil)
        banner.statusChanged()
        XCTAssertTrue(banner.view.text.hasSuffix("no open conflicts"), banner.view.text)
    }

    /// Each kind shows its count in the banner, a rebase also its step.
    func testBannerCountsEveryKind() async throws {
        let side = try await commit("side")
        let first = try await commit(base)
        let runs: [(String, @Sendable (Repository) async throws -> Void)] = [
            ("Merge of", { try await $0.merge("side") }),
            ("Rebase of main onto", { [base] in _ = try await $0.rebase(onto: "side", from: base, branch: "main") }),
            ("Cherry-pick of", { try await $0.cherryPick(side) }),
            ("Revert of", { try await $0.revert(first) }),
        ]
        for (head, run) in runs {
            let banner = OperationBannerController(context: tab.context)
            await runner.perform(failure: "failed", note: "git") { try await run($0) }
            banner.update()
            try await waitUntil { banner.progress != nil }
            XCTAssertTrue(banner.view.text.hasPrefix(head), banner.view.text)
            XCTAssertTrue(banner.view.text.hasSuffix("2 conflicts"), banner.view.text)
            try await tab.model.repository.abortOperation(XCTUnwrap(banner.progress?.kind))
            await tab.model.refresh(note: nil)
        }
    }
}
