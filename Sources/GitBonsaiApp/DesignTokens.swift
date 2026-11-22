import AppKit

/// Design tokens from docs/design/tokens.json. Colors resolve per appearance; metrics are the graph and sidebar grid.
@MainActor
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? hex(dark, darkAlpha) : hex(light, lightAlpha)
        }
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: alpha)
    }

    static let surface0 = dynamic(0xf8f4ee, 0x1e1a17)
    static let surface1 = dynamic(0xf1ebe2, 0x26211d)
    static let surface2 = dynamic(0xffffff, 0x2f2924)
    static let surfaceSelected = dynamic(0x456f45, 0x8fbe86, lightAlpha: 0.12, darkAlpha: 0.16)
    static let hairline = dynamic(0xe4dccf, 0x3a332c)
    static let ink = dynamic(0x2a241e, 0xf1eae1)
    static let inkMuted = dynamic(0x6b6156, 0xb3a89b)
    static let inkFaint = dynamic(0x8f857a, 0x857a6e)
    static let moss = dynamic(0x456f45, 0x8fbe86)
    static let onMoss = dynamic(0xffffff, 0x15200f)
    static let clay = dynamic(0x9a4f33, 0xd9906f)
    static let claySoft = dynamic(0xf0dccf, 0x43302a)
    static let persimmonSoft = dynamic(0xf6dcd4, 0x4a2a24)
    static let ochre = dynamic(0x8c6212, 0xe0b04a)
    static let persimmon = dynamic(0xb53d27, 0xea7d64)
    static let sky = dynamic(0x2f6f96, 0x7fb4d8)

    /// Twelve strand colors, cycled in this order so neighbouring strands never share a hue family.
    private static let strands: [NSColor] = [
        dynamic(0x5a9458, 0x6fae6b), dynamic(0xdd7446, 0xde8f6b), dynamic(0x9657a6, 0xad8bbb), dynamic(0x4489c2, 0x7aa6cf),
        dynamic(0xd19f2a, 0xd1b05e), dynamic(0xd25f78, 0xd68aa0), dynamic(0x2c8b7c, 0x6aae9f), dynamic(0x8577cf, 0x9f98d4),
        dynamic(0xe39a5c, 0xdfb18a), dynamic(0x35a3b1, 0x74bcc6), dynamic(0xad4a7c, 0xbf86a6), dynamic(0x86943a, 0xaab46e),
    ]

    static func strand(_ index: Int) -> NSColor {
        strands[((index % strands.count) + strands.count) % strands.count]
    }

    // MARK: Type (type in tokens.json)

    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyStrong = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let bodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let bodyDigits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 11)
    static let captionDigits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Tracking of `label` (0.06 em at 11 pt).
    static let labelKern: CGFloat = 0.66
    static let pill = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let pillStrong = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let heading = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoStrong = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    /// Initials inside avatar rings.
    static let initials = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let initialsSmall = NSFont.systemFont(ofSize: 8.5, weight: .semibold)

    // MARK: Scales (spacing, radius and stroke in tokens.json)

    enum Space {
        /// space-1
        static let xs: CGFloat = 4
        /// space-2
        static let s: CGFloat = 8
        /// space-3
        static let m: CGFloat = 12
        /// space-4
        static let l: CGFloat = 16
        /// space-6
        static let xl: CGFloat = 24
        /// space-8
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let xs: CGFloat = 3
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let icon: CGFloat = 1.5
        static let strand: CGFloat = 2
        /// Dash pattern of parked strands (stash, working directory) and their nodes.
        static let dash: [CGFloat] = [3, 3]
        static let nodeDash: [CGFloat] = [2.5, 2]
    }

    /// Glyph boxes.
    enum Icon {
        static let small: CGFloat = 14
        static let regular: CGFloat = 16
        static let large: CGFloat = 18
    }

    /// Alpha of ink washes for hover and press feedback.
    enum Wash {
        static let hover: CGFloat = 0.06
        static let hoverStrong: CGFloat = 0.08
        static let pressed: CGFloat = 0.12
        static let guide: CGFloat = 0.18
    }

    /// Rows and lanes outside the current focus, such as commits a search does not match or everything but source and target during a drag-and-drop merge.
    enum Focus {
        static let dimmedAlpha: CGFloat = 0.35
    }

    /// Movement or distance in points before a press becomes a drag, and the reach of a draggable boundary.
    static let dragThreshold: CGFloat = 4

    // MARK: Components

    enum Window {
        static let defaultSize = NSSize(width: 1440, height: 900)
        static let minimumSize = NSSize(width: 900, height: 520)
        /// Same as the compact title bar, so the tabs fill it.
        static let titleRow: CGFloat = 38
        /// Height of a macOS unified toolbar; its controls use the large control size.
        static let toolbar: CGFloat = 52
        static let statusBar: CGFloat = 28
        static let columnHeader: CGFloat = 30
        /// The history between the two panels never gets narrower; below it the panels give way.
        static let historyMinimum: CGFloat = 380
        /// How long a moved or resized window waits before its frame is saved.
        static let frameSaveDelay: Duration = .milliseconds(500)
        static let searchWidth: CGFloat = 260
        /// Leading inset of the fetch status in the toolbar.
        static let toolbarInset: CGFloat = 14
    }

    /// Split buttons of the repository toolbar: actions with several variants.
    enum Toolbar {
        /// Width of the chevron part behind the divider.
        static let menuPart: CGFloat = 22
        static let chevronSize: CGFloat = 10
        static let dividerHeight: CGFloat = 16
        /// Divider and chevron of a disabled button fade about as far as its title.
        static let disabledAlpha: CGFloat = 0.4
    }

    enum Tabs {
        /// Tabs sit at the bottom of the title row.
        static let height: CGFloat = 34
        static let radius = Radius.md
        static let titleInset: CGFloat = 18
        static let closeSlot: CGFloat = 28
        static let closeButton = Icon.regular
        static let closeGlyphInset: CGFloat = 3.5
        static let width: ClosedRange<CGFloat> = 96...240
        /// Narrowest a tab gets when many share the row.
        static let compressedWidth: CGFloat = 56
        static let newTabSlot: CGFloat = 40
        static let newTabGap: CGFloat = 6
        static let newTabButton = NSSize(width: 28, height: 24)
        static let separatorInset: CGFloat = 7
        static let hoverInset = NSSize(width: 3, height: 4)
        static let hoverRadius: CGFloat = 7
        static let closeRadius: CGFloat = 5
        /// Gap between the traffic lights and the first tab.
        static let afterTrafficLights: CGFloat = 14
    }

    enum Sidebar {
        /// Width of a new window's sidebar, and what a double click on its divider goes back to.
        static let defaultWidth: CGFloat = 264
        static let widths: ClosedRange<CGFloat> = 200...480
        static let rowHeight: CGFloat = 26
        static let headerHeight: CGFloat = 30
        static let worktreeHeight: CGFloat = 44
        /// Inset of the row backgrounds from the sidebar edge.
        static let rowInset: CGFloat = 6
        /// Width of the expander and icon columns, and the step from one to the next.
        static let column = Icon.regular
        static let columnStep: CGFloat = 22
        static let slot = Icon.large
        static let textGap: CGFloat = 6
        static let folderIndent = Space.l
        static let dirtyDot: CGFloat = 7
        /// Centre lines of the two text lines of a worktree row, from its top.
        static let worktreeLines: (first: CGFloat, second: CGFloat) = (14, 31)
        /// The bonsai glyph of a worktree sits one point left of the icon column, so its pot lines up with the icons below.
        static let worktreeGlyphShift: CGFloat = 1
        static let minimumText: CGFloat = 10
        /// Optical insets that give the glyphs in the grid the same visual weight.
        static let chevronInset: CGFloat = 2.5
        static let iconInset: CGFloat = 1
        static let expanderInset: CGFloat = 2
        static let plusInset: CGFloat = 4.5
        static let slotChevronInset = Space.xs
        static let slotInset: CGFloat = 2
    }

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
        /// Longest file list shown before it is cut off.
        static let maximumFiles = 200
        /// How long the copy icon shows its checkmark.
        static let copiedFeedback: TimeInterval = 1
        /// How long a commit's file list may take before the previous one gives way to a loading note.
        static let loadingDelay: Duration = .milliseconds(150)
    }

    enum Welcome {
        static let columnWidth: CGFloat = 520
        static let rowHeight: CGFloat = 46
        static let maximumRows = 8
        static let mark: CGFloat = 40
        /// Distance from the top of the mark to the list caption.
        static let introHeight: CGFloat = 132
        /// The intro starts at this share of the height, but never closer to the toolbar than `minimumTop`.
        static let topShare: CGFloat = 0.16
        static let minimumTop: CGFloat = 40
        static let titleOffset: CGFloat = 52
        static let textInset = Cell.leading
        static let rowRadius: CGFloat = 8
        /// Top and height of the name and folder lines in a list row.
        static let nameLine: (top: CGFloat, height: CGFloat) = (7, 17)
        static let folderLine: (top: CGFloat, height: CGFloat) = (25, 14)
        static let searchHeight: CGFloat = 32
        static let searchGap = Space.m
        static let captionHeight: CGFloat = 30
        /// Distance from the bottom of a group caption to its text's top.
        static let captionBaseline: CGFloat = 22
        static let sectionGap = Space.m
        static let messageHeight: CGFloat = 30
        static let messageTextOffset: CGFloat = 6
        /// The branch and the open mark on the right of a row.
        static let sideColumn: CGFloat = 150
        static let branchShift: CGFloat = 1
        static let worktreeIndent = Space.xl
        static let worktreeGlyph = Icon.small
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
        /// The body starts at the commit form's height and grows with its text.
        static let bodyMinimumHeight = CommitForm.bodyHeight
        static let counterWidth = CommitForm.counterWidth
        /// The pencil at the right of the panel's title, and the point size of its symbol.
        static let pencil = Icon.small
        static let pencilSymbol: CGFloat = 11
    }

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

    /// The "Neuer Branch" sheet.
    enum NewBranch {
        static let width: CGFloat = 460
        static let padding = Space.xl
        /// Between the groups of the form: name, start point, what happens afterwards, buttons.
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

    /// The "Repository klonen" sheet.
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
        static let markGap = Space.xs
    }

    /// The banner above the history while git is mid-rebase, cherry-pick or revert: clay-soft, persimmon-soft with conflicts.
    enum OperationBanner {
        static let height: CGFloat = 40
        static let inset = Space.s
        static let padding = Space.m
        static let radius = Radius.md
        static let spacing = Space.s
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
    }

    /// A pane with nothing to show: a centred message over the bonsai drawing (`icons/empty-state-bonsai.svg`).
    @MainActor enum EmptyState {
        static let maximumTextWidth: CGFloat = 440
        static let lineSpacing = Space.xs
        static let titleGap = Space.s
        /// The message sits this far above the middle, where the eye expects it.
        static let lift = Space.xl
        /// The drawing fills this share of the pane height, anchored to the lower right corner.
        static let artHeightShare: CGFloat = 2.0 / 3.0
        /// … but never more than this share of the pane width, so it stays at the edge in narrow panes.
        static let artMaximumWidthShare: CGFloat = 0.42
        static let artInset = Space.xl
        /// Line widths in points, whatever the drawing's size: twigs and pads, branches, trunk.
        static let artStroke = Stroke.icon
        static let artBranchStroke = Stroke.strand
        static let artTrunkStroke: CGFloat = 3
        /// Ink at a whisper, so the drawing never competes with the message.
        static let art = dynamic(0x2a241e, 0xf1eae1, lightAlpha: 0.07, darkAlpha: 0.07)
    }

    /// Capsules on a control's corner, such as the commit counts on Pull and Push: opaque `sky` informs, `persimmon` warns of danger.
    @MainActor enum Badge {
        static let height: CGFloat = 16
        static let padding = Space.xs
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        static let symbolSize: CGFloat = 8
        /// Larger counts read "99+".
        static let maximumCount = 99
        /// How far the badge reaches past the top and trailing edge of its control.
        static let overhang: CGFloat = 6
        static let onAccent = dynamic(0xffffff, 0x1e1a17)
    }

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

    /// Names inside running text (menus, sheets, banner, toasts): the ref pill in miniature, sized from the surrounding font.
    enum RefText {
        /// Longest name before it is cut in the middle, so its prefix (feature/) and its distinguishing end stay readable.
        static let maxNameWidth: CGFloat = 220
        /// The pill's text is this much smaller than the text around it.
        static let shrink: CGFloat = 1
        /// Added to the pill text's line height.
        static let extraHeight: CGFloat = 3
        static let padding: CGFloat = 5
        static let trailingPadding: CGFloat = 6
        static let glyphInset: CGFloat = 3
        static let glyphGap: CGFloat = 3
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

    enum Settings {
        /// Every section has this width, so switching sections only changes the window's height.
        static let width: CGFloat = 560
        static let inset = Space.xl
        static let rowSpacing = Space.m
        static let columnSpacing = Space.s
        /// Gap between a control and the explanation under it.
        static let captionGap = Space.xs
        static let popupWidth: CGFloat = 240
        static let pathFieldWidth: CGFloat = 260
        static let captionWidth: CGFloat = 340
        static let appIcon = Icon.regular
        static let folderRowHeight: CGFloat = 22
        /// Room for five folders before the list scrolls.
        static let folderListHeight: CGFloat = 112
    }

    /// The command bar (⌘⇧P): a glass panel centred near the top of the window.
    enum CommandBar {
        static let width: CGFloat = 560
        /// From the top of the window's content, below the tab row and the toolbar.
        static let topOffset: CGFloat = 88
        static let padding = Space.s
        /// The list reaches closer to the edges than the field, so the selection wash lines up with it.
        static let listInset = Space.xs
        static let listGap = Space.xs
        static let rowHeight: CGFloat = 32
        static let rowPadding = Space.s
        static let maxVisibleRows = 10
        static let glyph = Icon.regular
        static let glyphGap = Space.s
        /// Between the title and the muted context, and before the shortcut.
        static let detailGap = Space.s
        /// SF Symbols carry their own padding; at this share of the box they match the drawn glyphs.
        static let symbolScale: CGFloat = 0.78
        /// Height of the step's caption above the field while a second list is open.
        static let stepHeight: CGFloat = 20
        /// Paper tint of the glass, about 60 % as the design language asks for system-level glass.
        static let glassTint: CGFloat = 0.6
    }

    /// The editor list of Settings → Allgemein.
    enum Editors {
        /// Room for five editors before the list scrolls.
        static let listHeight: CGFloat = 112
    }
}

extension NSColor {
    /// Mixes this color into `ground` and returns an opaque result, resolved for the current drawing appearance.
    func mixed(into ground: NSColor, fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = ground.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: b.redComponent + (a.redComponent - b.redComponent) * fraction, green: b.greenComponent + (a.greenComponent - b.greenComponent) * fraction, blue: b.blueComponent + (a.blueComponent - b.blueComponent) * fraction, alpha: 1)
    }
}
