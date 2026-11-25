import AppKit
import XCTest
import GitEngine
@testable import GitBonsai

/// A fetch the user did not start must leave the history where the user left it.
@MainActor
final class BackgroundFetchSelectionTests: XCTestCase {
    func testBackgroundFetchKeepsACommitReachedThroughParentLinks() async throws {
        let repo = try FixtureRepo(name: "background-fetch")
        defer { repo.remove() }
        for index in 0..<60 { try repo.commit("Commit \(index)", contents: "\(index)\n") }
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-background-fetch-\(UUID().uuidString).git", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = try repo.git(["clone", "-q", "--bare", repo.url.path, remote.path])
        _ = try repo.git(["remote", "add", "origin", remote.path])
        _ = try repo.git(["fetch", "-q", "origin"])
        // Someone else pushes to the remote; the background fetch brings that commit in.
        let other = try FixtureRepo(name: "background-fetch-other")
        defer { other.remove() }
        _ = try other.git(["remote", "add", "origin", remote.path])
        _ = try other.git(["fetch", "-q", "origin"])
        _ = try other.git(["checkout", "-q", "-B", "main", "origin/main"])
        try other.commit("From elsewhere", contents: "elsewhere\n")
        _ = try other.git(["push", "-q", "origin", "main"])

        let fixture = TabFixture(repo)
        let controller = RepositoryViewController(context: fixture.context)
        let window = Snapshot.window(for: controller.view, size: CGSize(width: 1200, height: 500), appearance: .aqua)
        defer { window.close() }
        fixture.model.load()
        try await waitUntil { !fixture.model.isLoading && fixture.model.history.commitCount > 0 }
        controller.history.select(row: 0, scroll: true)
        for _ in 0..<40 {
            let row = try XCTUnwrap(controller.history.selectedRows.first)
            let parent = try XCTUnwrap(fixture.model.commits[row].parents.first)
            controller.detail.onNavigate?(parent)
        }
        let selected = try XCTUnwrap(controller.history.selectedID)
        let clip = try XCTUnwrap(controller.history.tableView.enclosingScrollView?.contentView)
        let offset = clip.bounds.minY

        let error = await fixture.model.fetch(.allRemotes, background: true)
        XCTAssertNil(error)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNotNil(fixture.model.refs.first { $0.name == "origin/main" && $0.target != fixture.model.headSHA }, "the fetch brought a new commit")
        XCTAssertEqual(controller.history.selectedID, selected)
        XCTAssertEqual(clip.bounds.minY, offset, accuracy: Theme.Graph.rowHeight * 1.5, "the rows move by the new commit at most")
    }

    /// The selected commit was only on a remote branch that the fetch prunes: the history stays where it was and nothing else gets selected.
    func testBackgroundFetchThatDropsTheSelectedCommitKeepsThePlace() async throws {
        let repo = try FixtureRepo(name: "background-prune")
        defer { repo.remove() }
        for index in 0..<60 { try repo.commit("Commit \(index)", contents: "\(index)\n") }
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-background-prune-\(UUID().uuidString).git", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = try repo.git(["clone", "-q", "--bare", repo.url.path, remote.path])
        _ = try repo.git(["-C", remote.path, "branch", "gone", "main~30"])
        _ = try repo.git(["remote", "add", "origin", remote.path])
        _ = try repo.git(["fetch", "-q", "origin"])
        // A commit only on the remote branch, off the middle of the history.
        _ = try repo.git(["checkout", "-q", "origin/gone"])
        _ = try repo.commit("Only on gone", date: "2023-01-01T12:00:00+0000")
        _ = try repo.git(["push", "-q", "origin", "HEAD:gone"])
        _ = try repo.git(["fetch", "-q", "origin"])
        _ = try repo.git(["checkout", "-q", "main"])
        let only = try repo.git(["rev-parse", "origin/gone"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let fixture = TabFixture(repo)
        let controller = RepositoryViewController(context: fixture.context)
        let window = Snapshot.window(for: controller.view, size: CGSize(width: 1200, height: 500), appearance: .aqua)
        defer { window.close() }
        fixture.model.load()
        try await waitUntil { !fixture.model.isLoading && fixture.model.history.commitCount > 0 }
        controller.history.navigate(to: only)
        XCTAssertEqual(controller.history.selectedID, only)
        let clip = try XCTUnwrap(controller.history.tableView.enclosingScrollView?.contentView)
        let offset = clip.bounds.minY
        XCTAssertGreaterThan(offset, Theme.Graph.rowHeight * 5, "the selected commit is far from HEAD")

        _ = try repo.git(["-C", remote.path, "branch", "-D", "gone"])
        let error = await fixture.model.fetch(.allRemotes, background: true)
        XCTAssertNil(error)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(fixture.model.rowIndex(of: only), "the prune took the commit out of the history")
        XCTAssertNil(controller.history.selectedID)
        XCTAssertEqual(clip.bounds.minY, offset, accuracy: Theme.Graph.rowHeight * 1.5)
    }
}
