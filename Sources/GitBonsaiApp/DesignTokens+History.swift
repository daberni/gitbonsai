import AppKit

/// Component tokens of the history: search, rows, ref labels, and the lists of the sidebar panels.
@MainActor
extension Theme {
    /// The commit search: the ground behind matched text and the counter inside the search field.
    @MainActor enum Search {
        /// search-highlight: stronger than ochre-soft so it still reads on a selected row.
        static let highlight = dynamic(0xf0d48a, 0x76602a)
        static let counterGap = Space.xs
    }

    /// Text cells of the history columns.
    enum Cell {
        static let leading: CGFloat = 10
        static let trailing = Space.m
        /// The commit text starts a little further in than the other cells.
        static let subjectLeading = Space.m
        static let minimumSubject: CGFloat = 40
        /// Narrower cells stay empty.
        static let minimumText = Space.s
        /// Captions keep this distance from the column edges or are left out.
        static let captionClearance: CGFloat = 2
    }

    /// Column boundaries in the history header and the bar that shows the visible part of a wider graph.
    enum ColumnHeader {
        static let dividerInset: CGFloat = 9
        static let scrollTrack: CGFloat = 2
        static let scrollTrackInset = Space.xs
        static let minimumKnob = Space.m
    }

    enum Pill {
        /// As tall as a commit node, so labels and nodes read as one size.
        static let height = Graph.nodeDiameter
        /// Glyphs, text and padding were drawn for a 20 pt pill and grow with it.
        private static let scale = height / 20
        private static func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        static let glyph = scaled(13)
        static let padding = scaled(6)
        static let glyphGap = scaled(Space.xs)
        /// Room kept for the "+n" counter while more labels follow.
        static let counterReserve = scaled(34)
        static let minimumText: CGFloat = 24
        /// Gap between the label column's edge and the rightmost pill.
        static let trailing: CGFloat = 14
        static let spacing = Space.xs
        static let textGap = scaled(2)
        static let trailingPadding = scaled(Space.s)
        @MainActor static let font = NSFont.systemFont(ofSize: scaled(11), weight: .medium)
        @MainActor static let fontStrong = NSFont.systemFont(ofSize: scaled(11), weight: .semibold)
        /// Width of the pill's outline; 0 draws filled pills only, `Stroke.hairline` brings the outline back.
        static let stroke: CGFloat = 0
        /// Share of the strand color in the pill's ground and its border, plain and for HEAD. Without an outline the ground alone has to set the pill off from the row and from the selection.
        static let tint: (plain: CGFloat, head: CGFloat) = stroke > 0 ? (0.16, 0.30) : (0.24, 0.44)
        static let border: (plain: CGFloat, head: CGFloat) = (0.55, 0.75)
    }

    /// Names inside running text (menus, alerts, sheets, command bar, banner, toasts): the ref pill in miniature. Its text has the size of the text around it; height, glyph and padding are these shares of that size.
    enum RefText {
        /// Longest name before it is cut in the middle, so its prefix (feature/) and its distinguishing end stay readable.
        static let maxNameWidth: CGFloat = 220
        /// Added to the pill text's line height.
        static let extraHeight: CGFloat = 0.3
        static let padding: CGFloat = 0.5
        static let trailingPadding: CGFloat = 0.6
        static let glyphInset: CGFloat = 0.3
        static let glyphGap: CGFloat = 0.3
        static let commitRing: CGFloat = 1.4
        /// Share of the glyph box the commit ring leaves free on each side.
        static let commitInset: CGFloat = 0.22
        /// Size of the hidden copy of each name that keeps a control's plain text readable.
        static let hiddenSize: CGFloat = 0.01
    }

    /// A history row's pills expanded over the columns when the label column cuts some of them off.
    @MainActor enum RefOverlay {
        /// Inner margin around the pills, all sides.
        static let padding = Space.xs
        /// Between two lines of the card.
        static let lineSpacing = Space.xs
        static let radius = Radius.md
        /// Keeps the overlay this far from the left edge of the history and the right edge of the visible area.
        static let edgeInset = Space.xs
        /// A single line wider than this wraps into a card.
        static let maxWidth: CGFloat = 560
        /// shadow-popover: it floats above the rows like a popover, with a hairline edge.
        static let shadowBlur: CGFloat = 24
        static let shadowOffset: CGFloat = 8
        static let shadow = dynamic(0x2a241e, 0x000000, lightAlpha: 0x24 / 255, darkAlpha: 0xa6 / 255)
        /// Room around the overlay for its shadow; the view is this much larger than what it draws.
        static let shadowMargin = shadowBlur + shadowOffset
        /// How long the pointer has to rest on a row's labels before they expand; once one is open the next row expands at once.
        static let hoverDelay: TimeInterval = 0.3
        /// Extra reach around the "+n" counter for a click.
        static let counterHitInset = Space.xs
    }

    /// The Tags and Stashes popovers of the sidebar.
    enum Panel {
        static let width: CGFloat = 400
        static let padding = Space.m
        /// The list reaches closer to the edges than the title and the buttons, so the selection wash lines up with the field.
        static let listInset = Space.xs
        static let rowHeight: CGFloat = 42
        static let rowPadding = Space.s
        /// Centre lines of the two text lines, as a share of the row height.
        static let firstLine: CGFloat = 0.34
        static let secondLine: CGFloat = 0.70
        static let selectionInset: CGFloat = 1
        /// The title row keeps this height whether a note or the busy spinner shows.
        static let headerHeight: CGFloat = 18
        /// Room the mini spinner always takes at the header's end.
        static let busySlot: CGFloat = 12
        static let maxVisibleRows = 9
        /// Longer lists get a filter field.
        static let filterThreshold = 8
    }

    enum Avatar {
        /// One download size for every place an avatar shows: the detail panel's at @2x. History nodes draw it scaled down.
        static let pixels = Int(Detail.avatar * 2)
        /// Background between the lane ring and the picture, so the ring keeps its full width over a picture of the same colour.
        static let ringGap = Stroke.hairline
        /// How a missing avatar is drawn; `ScreenshotHarness` can override it for a run.
        static let fallback: AvatarFallbackStyle = .tintedInitials
        /// Strength of the hashed tint behind the initials.
        static let tintAlpha: CGFloat = 0.24
        /// Share of the picture circle the 5×5 pattern's square spans; its corners stay inside the circle.
        static let patternSpan: CGFloat = 0.66
    }

    enum Graph {
        static let rowHeight: CGFloat = 36
        static let lane: CGFloat = 28
        /// Commit nodes and ref pills share this size.
        static let nodeDiameter: CGFloat = 24
        static let nodeRadius = nodeDiameter / 2
        static let mergeRadius: CGFloat = 5.5
        static let stashHalf: CGFloat = 9
        static let stashRadius: CGFloat = 4
        static let wipRadius: CGFloat = 7.5
        static let strandWidth = Stroke.strand
        /// Height of the S transition between two lanes; outside it a strand runs straight.
        static let elbow: CGFloat = 12
        static let bandInset: CGFloat = 5
        /// Distance of the strand bar from the right edge of the graph column.
        static let barInset: CGFloat = 6
        /// Strands and nodes end this far before the strand bar and the left edge of the graph column.
        static let edgeGap = Stroke.hairline
        static let labelColumn: CGFloat = 200
        static let firstLane: CGFloat = 22
        /// The automatic graph width stops growing at this many lanes; wider graphs scroll.
        static let maxVisibleLanes = 5
        static let authorColumn: CGFloat = 150
        static let shaColumn: CGFloat = 80
        /// Smallest widths a column can be dragged to.
        static let minimumLabelColumn: CGFloat = 80
        static let minimumCommitColumn: CGFloat = 160
        static let minimumAuthorColumn: CGFloat = 60
        static let minimumShaColumn: CGFloat = 60
        static let minimumDateColumn: CGFloat = 64
        static let dateColumn: CGFloat = 96
        static let bandAlpha: CGFloat = 0.13
        static let headBandAlpha: CGFloat = 0.26
        /// Working directory counters: glyph to number, and one counter to the next.
        static let counterGap: CGFloat = 5
        static let counterSpacing: CGFloat = 14
    }
}
