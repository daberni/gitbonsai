import Foundation

/// How a file diff is shown: the hunks with context around them, or the whole file with the changes in place. The last choice holds for the next file and the next launch.
enum DiffMode: String, CaseIterable {
    case diff
    case file

    var title: String {
        switch self {
        case .diff: String(localized: "Diff", bundle: .module, comment: "Diff mode: only the hunks")
        case .file: String(localized: "Whole File", bundle: .module, comment: "Diff mode: the whole file with the changes in place")
        }
    }

    private static let key = "diffMode"

    /// Harness runs keep their own defaults and start in "Diff" unless `GITBONSAI_DIFF_MODE` names a mode or `remembered`, so they never inherit the user's choice or each other's.
    @MainActor static var remembered: DiffMode {
        get {
            let harnessMode = ProcessInfo.processInfo.environment["GITBONSAI_DIFF_MODE"]
            if ScreenshotHarness.isActive, harnessMode != "remembered" { return harnessMode.flatMap(DiffMode.init) ?? .diff }
            return defaults?.string(forKey: key).flatMap(DiffMode.init) ?? .diff
        }
        set { defaults?.set(newValue.rawValue, forKey: key) }
    }

    @MainActor private static var defaults: UserDefaults? {
        ScreenshotHarness.isActive ? UserDefaults(suiteName: "app.gitbonsai.harness") : .standard
    }
}
