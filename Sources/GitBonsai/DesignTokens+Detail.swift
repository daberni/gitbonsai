import AppKit

/// Component tokens of the detail panel: commit header, file lists, commit form, message editor and the diff.
@MainActor
extension Theme {
    enum Detail {
        /// Width of a new window's detail panel, and what a double click on its divider goes back to.
        static let defaultWidth: CGFloat = 360
        static let widths: ClosedRange<CGFloat> = 280...640
        static let padding = Space.l
        static let spacing: CGFloat = 10
        static let headerHeight: CGFloat = 34
        static let avatar: CGFloat = 28
        /// Between the name and the role line of a person.
        static let personLineGap: CGFloat = 1
        /// Between the lines of the trailer block under the message.
        static let trailerRowGap = Space.xs
        /// How long the copy icon shows its checkmark.
        static let copiedFeedback: TimeInterval = 1
        /// How long a commit's file list may take before the previous one gives way to a loading note.
        static let loadingDelay: Duration = .milliseconds(150)

        /// The trash at the right of the working directory's title, and the point size of its symbol; as large as the commit title's pencil.
        enum DiscardAll {
            static let button = MessageEditor.pencil
            static let symbol = MessageEditor.pencilSymbol
        }
    }

    /// File lists in the detail panel.
    enum FileList {
        static let rowHeight: CGFloat = 24
        static let letterWidth: CGFloat = 18
        static let sectionHeight: CGFloat = 28
        static let rowRadius = Radius.sm
        /// Space between the path and the line counts.
        static let statGap = Space.s
        /// Space above every section after the first.
        static let sectionGap = Space.l
        /// The stage or unstage button a row shows while hovered.
        static let actionButton: CGFloat = 20
        /// Between the buttons of one hovered row.
        static let actionGap = Space.xs / 2
    }

    /// The commit form at the bottom of the right column.
    enum CommitForm {
        static let padding = Space.m
        static let spacing = Space.s
        static let subjectHeight = TextField.height
        static let bodyHeight: CGFloat = 64
        /// Text inset inside the fields, and the room the subject keeps free for its counter.
        static let fieldInset = TextField.inset
        static let counterWidth: CGFloat = 26
        /// The subject counter turns ochre and then persimmon past these lengths.
        static let subjectWarning = 50
        static let subjectLimit = 72
    }

    /// A commit's message edited in place in the detail panel, in the commit form's style.
    enum MessageEditor {
        static let spacing = Space.s
        /// The body starts at the commit form's height and grows with its text up to the maximum, then scrolls; the detail panel shows a message body at most this tall too.
        static let bodyMinimumHeight = CommitForm.bodyHeight
        static let bodyMaximumHeight: CGFloat = 160
        static let counterWidth = CommitForm.counterWidth
        /// The pencil at the right of the panel's title, and the point size of its symbol.
        static let pencil = Icon.small
        static let pencilSymbol: CGFloat = 11
    }

    /// The diff of one file in the history pane.
    enum Diff {
        static let headerHeight = Window.columnHeader + Space.m
        static let lineHeight: CGFloat = 20
        static let hunkHeight: CGFloat = 32
        static let numberColumn: CGFloat = 44
        static let signColumn: CGFloat = 16
        static let textInset = Space.s
        /// Tint of added and removed lines, and the stronger tint of their number columns.
        static let lineTint: CGFloat = 0.12
        static let numberTint: CGFloat = 0.2
        static let tabWidth = 4
        static let badgePadding = Space.s
        static let badgeHeight: CGFloat = 20
        /// Long hunk sections are cut here so the hunk's button stays in view.
        static let hunkLabelWidth: CGFloat = 480
        /// The changed part of a changed line, over the line's tint.
        static let emphasisTint: CGFloat = 0.28
        /// Capsules naming invisible characters (BOM, NBSP, ZWSP) inside a line.
        static let invisibleBadgeHeight: CGFloat = 14
        static let invisibleBadgePadding: CGFloat = 3
        static let invisibleBadgeGap: CGFloat = 1
        @MainActor static let invisibleBadgeFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        /// A notice above the lines, such as a line ending conversion.
        static let noticeHeight: CGFloat = 26
        /// Most files the diff pane stacks one below the other; more selected files show their count and the shared actions instead.
        static let maximumStacked = 12
        /// Where a stacked file has no lines to show, such as a binary file.
        static let stackedEmptyHeight: CGFloat = 120
        /// A stacked image file: both sides scaled to fit this height.
        static let stackedImageHeight: CGFloat = 360
        /// Between two stacked files.
        static let stackedGap = Space.m
    }

    /// The image diff in the history pane: changed images side by side, under a swipe line or faded over each other.
    enum ImageDiff {
        static let padding = Space.xl
        static let columnGap = Space.xl
        /// Between a side's label, its image and its caption.
        static let gap = Space.s
        /// Squares of the checkerboard behind transparent pixels, drawn in `surface2` and `hairline`.
        static let checker: CGFloat = 8
        static let handleWidth = Stroke.strand
        static let knob = Icon.regular
        static let sliderWidth: CGFloat = 240
        /// The new image starts half faded in over the old one.
        static let initialOpacity: Double = 0.5
        /// Where the swipe line starts, as a share of the image width.
        static let initialSwipe: CGFloat = 0.5
        /// Height of the box in place of an image that is not shown, as a share of its width.
        static let placeholderAspect: CGFloat = 0.6
    }
}
