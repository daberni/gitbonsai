import AppKit

/// Component tokens of controls, sheets, toasts and the banner of a running operation.
@MainActor
extension Theme {
    /// Hand-drawn controls in the warm palette.
    enum Control {
        static let height: CGFloat = 28
        static let radius = Radius.sm
        static let padding = Space.m
        static let focusWidth: CGFloat = 2
        static let checkbox: CGFloat = 16
        static let checkboxRadius: CGFloat = 4
        static let labelGap = Space.s
    }

    /// Sheets that ask for the values of a commit action: name, folder, message.
    enum ActionSheet {
        static let fieldWidth: CGFloat = 320
        static let messageHeight: CGFloat = 72
        static let rowSpacing = Space.s
        static let labelSpacing = Space.xs
        /// Rows a ref suggestion list shows before it scrolls.
        static let visibleSuggestions = 12
    }

    /// The app's one text field: a `FieldBox` with a borderless field, as in the commit form.
    enum TextField {
        static let height: CGFloat = 30
        /// Text inset inside the box.
        static let inset = NSSize(width: Space.s + 2, height: Space.xs + 2)
        /// Between the text and a glyph or button inside the box.
        static let accessoryGap = Space.xs
        static let accessory = Icon.regular
        /// Point size of an SF Symbol in an accessory; matches the drawn glyphs at `accessory`.
        static let accessorySymbol: CGFloat = 12.5
        /// Before a leading addon, such as a pill, which carries its own padding.
        static let addonInset = Space.xs
        /// Between a field's caption above it and the field, and between the field and its message below.
        static let captionGap = Space.xs
    }

    /// The ref picker: a popup-like control and the dropdown with search and sections.
    enum RefPicker {
        static let height = TextField.height
        static let glyph = Icon.regular
        static let glyphGap = Space.s
        static let chevron: CGFloat = 10
        /// Between the name and the muted SHA, date or subject after it.
        static let detailGap = Space.s
        static let panelWidth: CGFloat = 420
        static let panelPadding = Space.s
        static let rowHeight: CGFloat = 28
        static let headerHeight: CGFloat = 24
        static let rowPadding = Space.s
        static let maxVisibleRows = 11
        /// The commit glyph: a ring like a graph node, at icon size.
        static let commitRing: CGFloat = 4.5
    }

    /// The "New Branch" sheet.
    enum NewBranch {
        static let width: CGFloat = 460
        static let padding = Space.xl
        /// Between the groups of the form: name, start point, what happens afterwards, buttons.
        static let groupSpacing = Space.l
        static let buttonGap = Space.s
    }

    /// The sheet that adds a remote or edits its name and URL.
    enum RemoteForm {
        static let width: CGFloat = 460
        static let padding = Space.xl
        static let groupSpacing = Space.l
        static let buttonGap = Space.s
    }

    /// The note at the bottom of the history pane that fades out by itself.
    enum Toast {
        static let height: CGFloat = 34
        static let padding = Space.m
        static let radius = height / 2
        /// Distance from the bottom and the sides of the history pane.
        static let margin = Space.l
        /// Seconds the toast stays before it fades.
        static let duration: TimeInterval = 4
        /// A toast with an action stays longer, so the action can be reached.
        static let actionDuration: TimeInterval = 8
        static let fade: TimeInterval = 0.25
    }

    /// The "Clone Repository" sheet.
    enum Clone {
        static let width: CGFloat = 460
        static let minimumHeight: CGFloat = 200
        static let padding = Space.xl
        static let sectionGap = Space.m
        static let barHeight: CGFloat = 6
    }

    /// The sheet of a failed git command, and the disclosure with git's own output that it shares with the clone sheet.
    enum Failure {
        static let width: CGFloat = 480
        static let padding = Space.xl
        static let spacing = Space.m
        static let buttonGap = Space.s
        static let glyph = Icon.large
        /// The output box grows with git's text up to this height, then scrolls.
        static let outputMaxHeight: CGFloat = 220
        static let outputMinHeight = TextField.height
        static let outputInset = TextField.inset
        /// Between the disclosure row and the output box.
        static let outputGap = Space.xs
        static let chevron: CGFloat = 9
        static let copyGlyph: CGFloat = 11
    }

    /// The interactive rebase sheet: the steps on the left and the resulting history on the right on one baseline grid, the message of the selected step below both.
    enum InteractiveRebase {
        static let size = NSSize(width: 1040, height: 700)
        static let minimumSize = NSSize(width: 800, height: 660)
        static let maximumSize = NSSize(width: 1800, height: 1300)
        static let inset = Space.xl
        static let spacing = Space.m
        static let previewWidth: CGFloat = 300
        static let minimumPreviewWidth: CGFloat = 240
        /// The list keeps at least this width before the preview gives way.
        static let minimumListWidth: CGFloat = 420
        static let headerHeight = Window.columnHeader
        /// Rows the list shows at least, which sets the sheet's minimum height.
        static let minimumVisibleRows: CGFloat = 4
        /// One row of the list and of the preview: two lines of the preview fit.
        static let rowHeight: CGFloat = 38
        /// The fixed first column: grip and, for squash and fixup, the fold mark.
        static let handleWidth = Space.s + Icon.regular + Space.xs + foldIndent
        static let actionColumn: CGFloat = 108
        static let minimumActionColumn: CGFloat = 92
        static let shaColumn: CGFloat = 76
        static let minimumShaColumn: CGFloat = 60
        static let subjectColumn: CGFloat = 320
        static let minimumSubjectColumn: CGFloat = 160
        static let branchesColumn: CGFloat = 140
        static let minimumBranchesColumn: CGFloat = 60
        /// Squash and fixup rows show a mark in the handle column for the commit they melt into.
        static let foldIndent = Space.l
        static let messageHeight: CGFloat = 132
        static let baseFieldWidth: CGFloat = 300
        static let previewNode: CGFloat = 6
        static let previewStrandX: CGFloat = 18
        static let previewTextX: CGFloat = 36
    }

    /// The banner above the history while git is mid-rebase, cherry-pick or revert: clay-soft, persimmon-soft with conflicts.
    enum OperationBanner {
        static let height: CGFloat = 40
        static let inset = Space.s
        static let padding = Space.m
        static let radius = Radius.md
        static let spacing = Space.s
    }
}
