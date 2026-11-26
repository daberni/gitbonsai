import AppKit
import TextViewerModel

/// Component tokens of the read-only text viewer: its gutter, the find bar and the syntax colours.
@MainActor
extension Theme {
    enum TextViewer {
        /// Every line is as tall as a diff line, so the viewer and the diff rows line up.
        static let lineHeight = Diff.lineHeight
        static let textInset = Space.s
        /// Room for line numbers up to five digits.
        static let lineNumberColumn = Diff.numberColumn
        static let findBarHeight: CGFloat = 32
        static let findFieldWidth: CGFloat = 220
        static let lineFieldWidth: CGFloat = 80
        /// Matches of the find bar, and the current one more strongly.
        static let matchWash: CGFloat = 0.22
        static let currentMatchWash: CGFloat = 0.5
        /// Lines above and below the visible ones that are highlighted ahead, so a short scroll shows colour at once.
        static let highlightMargin = 200
    }

    /// Text colours of the highlighted token kinds, from the palette's hues; comments step back, punctuation stays quiet.
    enum Syntax {
        @MainActor static func color(_ token: SyntaxToken) -> NSColor {
            switch token {
            case .keyword: Theme.strand(2)
            case .string: Theme.moss
            case .comment: Theme.inkFaint
            case .number, .constant: Theme.ochre
            case .type: Theme.sky
            case .function: Theme.strand(6)
            case .property: Theme.strand(7)
            case .attribute: Theme.strand(5)
            case .tag, .heading: Theme.clay
            case .operator, .punctuation: Theme.inkMuted
            case .escape: Theme.persimmon
            case .link: Theme.sky
            // As the diff view colours its added and removed lines.
            case .inserted: Theme.moss
            case .deleted: Theme.persimmon
            }
        }
    }
}
