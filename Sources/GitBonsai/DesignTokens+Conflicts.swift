import AppKit

/// Component tokens of the conflict view in the history pane.
@MainActor
extension Theme {
    enum Conflict {
        static let headerHeight = Diff.headerHeight
        /// Around the card of a conflict without lines, such as delete/modify or binary.
        static let padding = Space.l
        static let cardPadding = Space.m
        static let cardRadius = Radius.md
        static let cardGap = Space.s
        static let blockPadding = Space.s
        static let blockRadius = Radius.sm
        /// Tint of a side's preview block over the card.
        static let sideTint: CGFloat = 0.10
        /// Longest preview of the file one side kept.
        static let previewLines = 40
        /// The captions above the three columns.
        static let captionHeight = Window.columnHeader
        static let captionInset = Space.m
        /// The strip between two columns and its take and ignore buttons.
        static let gutterWidth: CGFloat = 44
        static let gutterButton: CGFloat = 20
        static let gutterSymbol: CGFloat = 10
        /// A change's band behind its lines, the lighter part where a side has no line, and the hairlines at its edges.
        static let bandTint: CGFloat = 0.16
        static let paddingTint: CGFloat = 0.07
        static let bandEdgeAlpha: CGFloat = 0.45
        /// A change without lines on any side still shows as a thin band.
        static let emptyBand: CGFloat = 3
        /// The bar at the left edge of the change the keyboard navigation stands on.
        static let currentStroke = Stroke.strand + 1
        static let currentAlpha: CGFloat = 0.7
        /// Space left and right of a line number.
        static let numberPadding = Space.s
        /// The width the file name keeps in the header before the optional elements give way.
        static let minimumTitle: CGFloat = 180
        /// The merge window when it first opens, and its smallest size.
        static let windowSize = NSSize(width: 1280, height: 820)
        static let windowMinimumSize = NSSize(width: 820, height: 420)
    }
}
