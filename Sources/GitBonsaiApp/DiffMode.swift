import Foundation

/// How a file diff is shown: the hunks with context around them, or the whole file with the changes in place. The last choice holds for the next file and the next launch.
enum DiffMode: String, CaseIterable {
    case diff
    case file

    var title: String {
        switch self {
        case .diff: String(localized: "diff.mode.diff", defaultValue: "Diff", bundle: .module, comment: "Diff mode: only the hunks")
        case .file: String(localized: "diff.mode.file", defaultValue: "Whole file", bundle: .module, comment: "Diff mode: the whole file with the changes in place")
        }
    }

    private static let key = "diffMode"

    /// Harness runs keep their own defaults and start in "Diff" unless `GITBONSAI_DIFF_MODE` names a mode or `remembered`, so they never inherit the user's choice or each other's.
    @MainActor static var remembered: DiffMode {
        get {
            let harnessMode = ProcessInfo.processInfo.environment["GITBONSAI_DIFF_MODE"]
            if ScreenshotHarness.isActive, harnessMode != "remembered" { return harnessMode.flatMap(DiffMode.init) ?? .diff }
            return defaults.string(forKey: key).flatMap(DiffMode.init) ?? .diff
        }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    @MainActor private static var defaults: UserDefaults { ScreenshotHarness.defaults }
}

/// Choices of the diff options menu next to "Diff | Whole File"; like the mode they hold for every file and the next launch.
struct DiffOptions: Equatable {
    /// Marks tabs and trailing spaces in changed lines, line ends with CR, a byte order mark, and names characters without a glyph such as NBSP and ZWSP.
    var showsInvisibles = false

    private static let invisiblesKey = "diffShowsInvisibles"

    /// Harness runs start without invisibles unless `GITBONSAI_DIFF_INVISIBLES` is `1` or `remembered`.
    @MainActor static var remembered: DiffOptions {
        get {
            let harnessValue = ProcessInfo.processInfo.environment["GITBONSAI_DIFF_INVISIBLES"]
            if ScreenshotHarness.isActive, harnessValue != "remembered" { return DiffOptions(showsInvisibles: harnessValue == "1") }
            return DiffOptions(showsInvisibles: defaults.bool(forKey: invisiblesKey))
        }
        set { defaults.set(newValue.showsInvisibles, forKey: invisiblesKey) }
    }

    @MainActor private static var defaults: UserDefaults { ScreenshotHarness.defaults }
}
