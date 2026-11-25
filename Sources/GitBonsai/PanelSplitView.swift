import AppKit

/// The widths the user gave the sidebar and the detail panel. One instance belongs to the window and is shared by every tab, so switching tabs keeps the panels where they were.
@MainActor
final class PanelWidths {
    private(set) var sidebar: CGFloat
    private(set) var detail: CGFloat
    /// Called after a drag or a reset changed a width, to save it.
    var onChange: (() -> Void)?
    /// Hidden panels keep their widths for when they come back. Like the widths, this holds for every tab.
    var showsSidebar = true
    var showsDetail = true

    init(sidebar: CGFloat = Theme.Sidebar.defaultWidth, detail: CGFloat = Theme.Detail.defaultWidth) {
        self.sidebar = sidebar.clamped(to: Theme.Sidebar.widths)
        self.detail = detail.clamped(to: Theme.Detail.widths)
    }

    func set(sidebar: CGFloat, detail: CGFloat) {
        let sidebar = sidebar.clamped(to: Theme.Sidebar.widths)
        let detail = detail.clamped(to: Theme.Detail.widths)
        guard sidebar != self.sidebar || detail != self.detail else { return }
        self.sidebar = sidebar
        self.detail = detail
        onChange?()
    }
}

/// Sidebar, history and detail panel side by side, with draggable dividers between them.
///
/// The panels keep the widths in `widths` and the history takes the rest. A narrower window shrinks the history down to its minimum first and only then the panels down to theirs; a wider one gives the panels back their widths.
/// Frames are set directly instead of through constraints, so a drag or a live resize touches three frames and no constraint solving.
final class PanelSplitView: NSSplitView, NSSplitViewDelegate {
    var widths = PanelWidths() {
        didSet { layoutPanels() }
    }

    private let sidebar: NSView
    private let history: NSView
    private let detail: NSView
    /// True while the user drags a divider; AppKit also names a divider when a window resize moves it.
    private var isDragging = false

    init(sidebar: NSView, history: NSView, detail: NSView) {
        self.sidebar = sidebar
        self.history = history
        self.detail = detail
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        for pane in [sidebar, history, detail] {
            pane.translatesAutoresizingMaskIntoConstraints = true
            addSubview(pane)
        }
    }

    required init?(coder: NSCoder) { nil }

    var sidebarWidth: CGFloat { sidebar.frame.width }
    var showsSidebar: Bool { widths.showsSidebar }
    var showsDetail: Bool { widths.showsDetail }

    /// Shows or hides a side panel; the history takes or gives back its room.
    func toggleSidebar() {
        widths.showsSidebar.toggle()
        layoutPanels()
    }

    func toggleDetail() {
        widths.showsDetail.toggle()
        layoutPanels()
    }
    var detailWidth: CGFloat { detail.frame.width }
    var historyWidth: CGFloat { history.frame.width }

    /// Where a divider sits, in this view's coordinates.
    func dividerFrame(at index: Int) -> NSRect {
        let pane = index == 0 ? sidebar : history
        return NSRect(x: pane.frame.maxX, y: 0, width: dividerThickness, height: bounds.height)
    }

    // Every tab has its own split view; showing a tab lays it out with the widths another tab may have changed meanwhile.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { layoutPanels() }
    }

    /// A double click on a divider puts that panel back to its default width.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 2, let index = (0..<2).first(where: { dividerFrame(at: $0).insetBy(dx: -Theme.Space.xs, dy: 0).contains(point) }) else {
            // The divider's tracking loop runs inside, until the button is released.
            isDragging = true
            super.mouseDown(with: event)
            isDragging = false
            return
        }
        if index == 0 {
            widths.set(sidebar: Theme.Sidebar.defaultWidth, detail: widths.detail)
        } else {
            widths.set(sidebar: widths.sidebar, detail: Theme.Detail.defaultWidth)
        }
        layoutPanels()
    }

    /// A hidden panel gets no width and its divider sits at the window's edge, where the window's own border covers it.
    private func layoutPanels() {
        guard bounds.width > 0 else { return }
        let showsSidebar = widths.showsSidebar
        let showsDetail = widths.showsDetail
        let available = bounds.width - 2 * dividerThickness
        let (fittedSidebar, fittedDetail) = Self.panelWidths(available: available, sidebar: showsSidebar ? widths.sidebar : 0, detail: showsDetail ? widths.detail : 0)
        let sidebarWidth = showsSidebar ? fittedSidebar.rounded() : 0
        let detailWidth = showsDetail ? fittedDetail.rounded() : 0
        let sidebarGap = showsSidebar ? dividerThickness : 0
        let detailGap = showsDetail ? dividerThickness : 0
        let historyWidth = max(bounds.width - sidebarWidth - detailWidth - sidebarGap - detailGap, 0)
        let height = bounds.height
        sidebar.isHidden = !showsSidebar
        detail.isHidden = !showsDetail
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
        history.frame = NSRect(x: sidebarWidth + sidebarGap, y: 0, width: historyWidth, height: height)
        detail.frame = NSRect(x: history.frame.maxX + detailGap, y: 0, width: detailWidth, height: height)
    }

    /// The panels' widths in `available` points: as wished while the history keeps its minimum, otherwise both give way in proportion to what they have above their minimums.
    private static func panelWidths(available: CGFloat, sidebar: CGFloat, detail: CGFloat) -> (CGFloat, CGFloat) {
        let missing = Theme.Window.historyMinimum + sidebar + detail - available
        guard missing > 0 else { return (sidebar, detail) }
        // A hidden panel passes 0 and has nothing to give.
        let sidebarSlack = max(sidebar - Theme.Sidebar.widths.lowerBound, 0)
        let detailSlack = max(detail - Theme.Detail.widths.lowerBound, 0)
        let slack = sidebarSlack + detailSlack
        guard slack > 0 else { return (sidebar, detail) }
        let share = min(missing / slack, 1)
        return (sidebar - sidebarSlack * share, detail - detailSlack * share)
    }

    private func panelIsHidden(besideDivider index: Int) -> Bool {
        index == 0 ? !widths.showsSidebar : !widths.showsDetail
    }

    override func drawDivider(in rect: NSRect) {
        let index = rect.midX < history.frame.midX ? 0 : 1
        guard !panelIsHidden(besideDivider: index) else { return }
        super.drawDivider(in: rect)
    }

    // MARK: NSSplitViewDelegate

    /// The divider of a hidden panel cannot be dragged.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        panelIsHidden(besideDivider: dividerIndex) ? .zero : proposedEffectiveRect
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanels()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { return Theme.Sidebar.widths.lowerBound }
        let historyEnd = sidebar.frame.maxX + dividerThickness + Theme.Window.historyMinimum
        return max(historyEnd, bounds.width - dividerThickness - Theme.Detail.widths.upperBound)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 1 { return bounds.width - dividerThickness - Theme.Detail.widths.lowerBound }
        let historyStart = detail.frame.minX - dividerThickness - Theme.Window.historyMinimum - dividerThickness
        return min(Theme.Sidebar.widths.upperBound, historyStart)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === history
    }

    /// Only a drag of a divider changes the wished width of the panel beside it; a window resize leaves them, so a wider window gives shrunk panels their widths back.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isDragging, let index = notification.userInfo?["NSSplitViewDividerIndex"] as? Int else { return }
        if index == 0 {
            widths.set(sidebar: sidebar.frame.width, detail: widths.detail)
        } else {
            widths.set(sidebar: widths.sidebar, detail: detail.frame.width)
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
