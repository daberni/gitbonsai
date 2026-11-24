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

    static let key = "diffMode"
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

    static let invisiblesKey = "diffShowsInvisibles"
    static let wordDiffKey = "diffWordDiff"
    static let whitespaceKey = "diffIgnoresWhitespace"
    static let blankLinesKey = "diffIgnoresBlankLines"

}

/// How diffs are shown, remembered for every file and the next launch: the mode, the options and the mode of image diffs.
@MainActor
struct DiffPreferences {
    let defaults: UserDefaults

    // harness: the harness stores these choices in its defaults domain before launch; the switches below go away with it.
    /// Harness runs keep their own defaults and start in "Diff" unless `GITBONSAI_DIFF_MODE` names a mode or `remembered`, so they never inherit the user's choice or each other's.
    var mode: DiffMode {
        get {
            let harnessMode = ProcessInfo.processInfo.environment["GITBONSAI_DIFF_MODE"]
            // harness: stored in the harness's defaults domain before launch.
            if ScreenshotHarness.isActive, harnessMode != "remembered" { return harnessMode.flatMap(DiffMode.init) ?? .diff }
            return defaults.string(forKey: DiffMode.key).flatMap(DiffMode.init) ?? .diff
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: DiffMode.key) }
    }

    /// Harness runs start without any option unless `GITBONSAI_DIFF_INVISIBLES` or `GITBONSAI_DIFF_WORDS` is `1`, `GITBONSAI_DIFF_WHITESPACE` names `changes` or `all`, `GITBONSAI_DIFF_BLANK_LINES` is `1`, or `GITBONSAI_DIFF_INVISIBLES` is `remembered`.
    var options: DiffOptions {
        get {
            let environment = ProcessInfo.processInfo.environment
            // harness: stored in the harness's defaults domain before launch.
            if ScreenshotHarness.isActive, environment["GITBONSAI_DIFF_INVISIBLES"] != "remembered" {
                let ignoring = environment["GITBONSAI_DIFF_WHITESPACE"].flatMap(DiffWhitespace.Ignoring.init) ?? .nothing
                return DiffOptions(showsInvisibles: environment["GITBONSAI_DIFF_INVISIBLES"] == "1", wordDiff: environment["GITBONSAI_DIFF_WORDS"] == "1", whitespace: DiffWhitespace(ignoring: ignoring, ignoresBlankLines: environment["GITBONSAI_DIFF_BLANK_LINES"] == "1"))
            }
            let ignoring = defaults.string(forKey: DiffOptions.whitespaceKey).flatMap(DiffWhitespace.Ignoring.init) ?? .nothing
            return DiffOptions(showsInvisibles: defaults.bool(forKey: DiffOptions.invisiblesKey), wordDiff: defaults.bool(forKey: DiffOptions.wordDiffKey), whitespace: DiffWhitespace(ignoring: ignoring, ignoresBlankLines: defaults.bool(forKey: DiffOptions.blankLinesKey)))
        }
        nonmutating set {
            defaults.set(newValue.showsInvisibles, forKey: DiffOptions.invisiblesKey)
            defaults.set(newValue.wordDiff, forKey: DiffOptions.wordDiffKey)
            defaults.set(newValue.whitespace.ignoring.rawValue, forKey: DiffOptions.whitespaceKey)
            defaults.set(newValue.whitespace.ignoresBlankLines, forKey: DiffOptions.blankLinesKey)
        }
    }

    /// Harness runs start side by side unless `GITBONSAI_IMAGE_MODE` names a mode.
    var imageMode: ImageDiffMode {
        get {
            // harness: stored in the harness's defaults domain before launch.
            if ScreenshotHarness.isActive { return ProcessInfo.processInfo.environment["GITBONSAI_IMAGE_MODE"].flatMap(ImageDiffMode.init) ?? .sideBySide }
            return defaults.string(forKey: ImageDiffMode.key).flatMap(ImageDiffMode.init) ?? .sideBySide
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: ImageDiffMode.key) }
    }
}
