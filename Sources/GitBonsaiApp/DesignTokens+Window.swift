import AppKit

/// Component tokens of the window chrome: tabs, toolbar, sidebar, the empty tab, empty panes, settings and the command bar.
@MainActor
extension Theme {
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

    enum Settings {
        /// Every section has this width, so switching sections only changes the window's height.
        static let width: CGFloat = 560
        /// Tallest a section gets before it scrolls; leaves room for the toolbar on a 13-inch display.
        static let maxHeight: CGFloat = 600
        /// Between the git path field and its button.
        static let columnSpacing = Space.s
        static let pathFieldWidth: CGFloat = 260
        static let appIcon = Icon.regular
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
}
