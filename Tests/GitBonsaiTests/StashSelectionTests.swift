import AppKit
import XCTest
import GitEngine
@testable import GitBonsai

/// Popping or applying a stash brings its changes back into the working directory, so the history selects that row.
@MainActor
final class StashSelectionTests: XCTestCase {
    func testPopAndApplySelectTheWorkingDirectory() async throws {
        let repo = try FixtureRepo(name: "stash-selection")
        defer { repo.remove() }
        for index in 0..<5 { try repo.commit("Commit \(index)", contents: "\(index)\n") }
        try repo.write("Notes.txt", "kept aside\n")
        _ = try repo.git(["stash", "push", "-u", "-q", "-m", "Aside"])

        let fixture = TabFixture(repo)
        let controller = RepositoryViewController(context: fixture.context)
        let window = Snapshot.window(for: controller.view, size: CGSize(width: 1200, height: 500), appearance: .aqua)
        defer { window.close() }
        fixture.model.load()
        try await waitUntil { !fixture.model.isLoading && fixture.model.history.commitCount > 0 }

        for (name, run) in [("apply", controller.stashActions.apply), ("pop", controller.stashActions.pop)] {
            // The applied changes go away again so the pop does not collide with them.
            if name == "pop" { _ = try repo.git(["clean", "-fdq"]) }
            controller.history.navigate(to: try repo.git(["rev-parse", "HEAD~3"]).trimmingCharacters(in: .whitespacesAndNewlines))
            let stash = try XCTUnwrap(fixture.model.stashes.first)
            run(stash.commitID)
            try await waitUntil { controller.history.selectedID == GraphViewModel.wipID }
            XCTAssertEqual(controller.history.selectedID, GraphViewModel.wipID, name)
        }
        XCTAssertTrue(fixture.model.stashes.isEmpty, "the pop removed the stash")
    }
}
