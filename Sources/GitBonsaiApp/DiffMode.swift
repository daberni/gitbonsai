import Foundation
import GitEngine

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
    /// Changed words are marked within their line instead of whole lines.
    var wordDiff = false
    var whitespace = DiffWhitespace()

    /// The diff shown is not the one git applies: hunks can be staged and discarded only without these options.
    var changesHunks: Bool { wordDiff || whitespace.isFiltering }

    /// The same lines read again under other options; only the invisibles change no more than the drawing.
    func readsDifferently(from other: DiffOptions) -> Bool { wordDiff != other.wordDiff || whitespace != other.whitespace }

    private static let invisiblesKey = "diffShowsInvisibles"
    private static let wordDiffKey = "diffWordDiff"
    private static let whitespaceKey = "diffIgnoresWhitespace"
    private static let blankLinesKey = "diffIgnoresBlankLines"

    /// Harness runs start without any option unless `GITBONSAI_DIFF_INVISIBLES` or `GITBONSAI_DIFF_WORDS` is `1`, `GITBONSAI_DIFF_WHITESPACE` names `changes` or `all`, `GITBONSAI_DIFF_BLANK_LINES` is `1`, or `GITBONSAI_DIFF_INVISIBLES` is `remembered`.
    @MainActor static var remembered: DiffOptions {
        get {
            let environment = ProcessInfo.processInfo.environment
            if ScreenshotHarness.isActive, environment["GITBONSAI_DIFF_INVISIBLES"] != "remembered" {
                let ignoring = environment["GITBONSAI_DIFF_WHITESPACE"].flatMap(DiffWhitespace.Ignoring.init) ?? .nothing
                return DiffOptions(showsInvisibles: environment["GITBONSAI_DIFF_INVISIBLES"] == "1", wordDiff: environment["GITBONSAI_DIFF_WORDS"] == "1", whitespace: DiffWhitespace(ignoring: ignoring, ignoresBlankLines: environment["GITBONSAI_DIFF_BLANK_LINES"] == "1"))
            }
            let ignoring = defaults.string(forKey: whitespaceKey).flatMap(DiffWhitespace.Ignoring.init) ?? .nothing
            return DiffOptions(showsInvisibles: defaults.bool(forKey: invisiblesKey), wordDiff: defaults.bool(forKey: wordDiffKey), whitespace: DiffWhitespace(ignoring: ignoring, ignoresBlankLines: defaults.bool(forKey: blankLinesKey)))
        }
        set {
            defaults.set(newValue.showsInvisibles, forKey: invisiblesKey)
            defaults.set(newValue.wordDiff, forKey: wordDiffKey)
            defaults.set(newValue.whitespace.ignoring.rawValue, forKey: whitespaceKey)
            defaults.set(newValue.whitespace.ignoresBlankLines, forKey: blankLinesKey)
        }
    }

    @MainActor private static var defaults: UserDefaults { ScreenshotHarness.defaults }
}
