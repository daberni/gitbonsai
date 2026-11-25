import AppKit
import GitEngine
import XCTest
@testable import GitBonsai

/// A question of a tab in the background waits for the tab to be shown; closing the tab must answer it, or the question's task hangs for good.
@MainActor
final class TabLifecycleTests: XCTestCase {
    private func lifecycle() -> TabLifecycle {
        let suite = "app.gitbonsai.tests.\(UUID().uuidString)"
        let settings = AppSettings(persistence: Persistence(defaults: UserDefaults(suiteName: suite)!))
        UserDefaults().removePersistentDomain(forName: suite)
        let path = FileManager.default.temporaryDirectory.path
        return TabLifecycle(viewModel: GraphViewModel(location: RepositoryLocation(root: path, commonDirectory: path), settings: settings))
    }

    func testClosingAnswersAWaitingQuestionWithoutWindow() async {
        let lifecycle = lifecycle()
        let waiting = Task { await lifecycle.windowWhenShown() }
        await Task.yield()
        lifecycle.close()
        let window = await waiting.value
        XCTAssertNil(window)
    }

    func testAClosedTabAnswersAtOnce() async {
        let lifecycle = lifecycle()
        lifecycle.close()
        let window = await lifecycle.windowWhenShown()
        XCTAssertNil(window)
    }
}
