import AppKit

/// The harness switches that act on a repository tab once its first full load has finished.
@MainActor
extension ScreenshotHarness {
    /// Runs every switch that drives a loaded tab, in a fixed order. Returns true when a one-time action reloads the tab, so the switches wait for the next full load.
    static func driveLoadedTab(_ tab: RepositoryViewController) -> Bool {
        guard outputPath != nil else { return false }
        if runOneTimeAction(on: tab) { return true }
        prepare(tab.history)
        driveHistoryContents(on: tab)
        driveStatusLine(on: tab)
        openDiff(on: tab)
        driveConflicts(on: tab)
        clickFile(on: tab)
        pressFileKeys(on: tab)
        fillCommit(on: tab)
        discard(on: tab)
        fileMenu(on: tab)
        driveFileSelection(on: tab)
        scrollSidebar(tab.sidebar)
        openCommitMenu(on: tab)
        runRemotesAndRebase(on: tab)
        driveStashesAndTags(on: tab)
        openSidebarMenu(on: tab)
        openAddRemote(on: tab)
        printStatusLine(of: tab)
        driveRebase(on: tab)
        navigate(on: tab)
        driveCoveredHover(on: tab)
        printFetchState(of: tab)
        return false
    }
}
