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

    var mode: DiffMode {
        get {
            defaults.string(forKey: DiffMode.key).flatMap(DiffMode.init) ?? .diff
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: DiffMode.key) }
    }

    var options: DiffOptions {
        get {
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

    var imageMode: ImageDiffMode {
        get {
            defaults.string(forKey: ImageDiffMode.key).flatMap(ImageDiffMode.init) ?? .sideBySide
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: ImageDiffMode.key) }
    }
}
