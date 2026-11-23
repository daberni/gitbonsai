import Foundation
import GitEngine

/// Harness switch for the order of the history.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_HISTORY_ORDER=date|authorDate|branchesTogether` stores that order in the run's defaults before the first tab loads.
    static func applyHistoryOrderSwitch() {
        guard isActive, let order = environment["GITBONSAI_HISTORY_ORDER"].flatMap(HistoryOrder.init) else { return }
        AppSettings.historyOrder = order
    }
}
