import AppKit

/// The title row: one tab per repository next to the traffic lights, then the button that opens another one.
/// The active tab takes the toolbar's color and flares into it at the bottom; the row itself stays in the window color.
final class TabBarView: NSView, NSViewToolTipOwner {
    struct Item: Equatable {
        let title: String
        let toolTip: String?
    }

    static let height = Theme.Window.titleRow
    private typealias M = Theme.Tabs
    /// Length of a corner's curve handles as a fraction of its radius; close to a circular arc.
    private static let cornerHandle: CGFloat = 0.45

    var items: [Item] = [] { didSet { if items != oldValue { needsLayout = true; needsDisplay = true } } }
    var activeIndex = 0 { didSet { needsDisplay = true } }
    /// Room for the traffic lights; less in full screen, where they are gone.
    var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true; needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    /// A dragged tab passed the middle of its neighbour; the two swap places.
    var onMove: ((_ from: Int, _ to: Int) -> Void)?

    private enum Hit: Equatable { case none, tab(Int), close(Int), plus }
    private var tabFrames: [CGRect] = []
    private var plusFrame = CGRect.zero
    private var hover = Hit.none { didSet { if hover != oldValue { needsDisplay = true } } }
    private var pressedClose: Int?
    private var mayDragWindow = false
    /// The tab being dragged and where its left edge currently is.
    private var dragging: (index: Int, minX: CGFloat)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Marks the whole row as a control for the title bar, so macOS does not start a window move under a tab.
    override var isOpaque: Bool { true }
    /// Without this the first click into an inactive window only activates it, and a drag from there moves the window instead of the tab.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func frameOfTab(_ index: Int) -> CGRect? {
        layoutSubtreeIfNeeded()
        return tabFrames.indices.contains(index) ? tabFrames[index] : nil
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.bodyStrong]
        var widths = items.map { item -> CGFloat in
            let natural = ceil((item.title as NSString).size(withAttributes: attributes).width) + M.titleInset + M.closeSlot
            return min(max(natural, M.width.lowerBound), M.width.upperBound)
        }
        let available = bounds.width - leadingInset - M.newTabSlot - Theme.Space.m
        let total = widths.reduce(0, +)
        if total > available, total > 0 {
            let scale = available / total
            widths = widths.map { max(floor($0 * scale), M.compressedWidth) }
        }
        var x = leadingInset
        tabFrames = widths.map { width in
            defer { x += width }
            return CGRect(x: x, y: M.top, width: width, height: bounds.height - M.top)
        }
        plusFrame = CGRect(x: x + M.newTabGap, y: (M.top + Self.height - M.newTabButton.height) / 2, width: M.newTabButton.width, height: M.newTabButton.height)
        // AppKit does not retain a tool tip's owner, so the view itself answers for every rectangle.
        removeAllToolTips()
        for frame in tabFrames + [plusFrame] { addToolTip(frame, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        switch hit(at: point) {
        case .plus: "Repository öffnen (⌘T)"
        case .tab(let index), .close(let index): items.indices.contains(index) ? items[index].toolTip ?? "" : ""
        case .none: ""
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func closeFrame(in tab: CGRect) -> CGRect {
        CGRect(x: tab.maxX - Theme.Space.s - M.closeButton, y: tab.midY - M.closeButton / 2, width: M.closeButton, height: M.closeButton)
    }

    private func hit(at point: CGPoint) -> Hit {
        if plusFrame.contains(point) { return .plus }
        guard let index = tabFrames.firstIndex(where: { $0.contains(point) }) else { return .none }
        return closeFrame(in: tabFrames[index]).contains(point) ? .close(index) : .tab(index)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Theme.surface0.setFill()
        bounds.fill()

        // The dragged tab follows the mouse and is drawn last, on top of its neighbours.
        let order = tabFrames.indices.filter { $0 != dragging?.index } + (dragging.map { [$0.index] } ?? [])
        for index in order {
            var frame = tabFrames[index]
            if let dragging, dragging.index == index { frame.origin.x = dragging.minX }
            let isActive = index == activeIndex
            let isHovered = hover == .tab(index) || hover == .close(index)
            if isActive {
                Theme.surface1.setFill()
                activeTabPath(frame).fill()
            } else {
                if isHovered {
                    Theme.ink.withAlphaComponent(Theme.Wash.hover).setFill()
                    NSBezierPath(roundedRect: frame.insetBy(dx: M.hoverInset.width, dy: M.hoverInset.height), xRadius: M.hoverRadius, yRadius: M.hoverRadius).fill()
                }
                let leftNeighbourIsQuiet = index > 0 && index - 1 != activeIndex && hover != .tab(index - 1) && hover != .close(index - 1)
                if leftNeighbourIsQuiet, !isHovered {
                    Theme.hairline.setFill()
                    CGRect(x: frame.minX, y: frame.minY + M.separatorInset, width: Theme.Stroke.hairline, height: frame.height - 2 * M.separatorInset).fill()
                }
            }

            let showsClose = isHovered
            let textWidth = frame.width - M.titleInset - (showsClose ? M.closeSlot : Theme.Cell.leading)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: isActive ? Theme.bodyStrong : Theme.body, .foregroundColor: isActive ? Theme.ink : Theme.inkMuted, .paragraphStyle: paragraph]
            let title = NSAttributedString(string: items[index].title, attributes: attributes)
            let textHeight = title.size().height
            title.draw(in: CGRect(x: frame.minX + M.titleInset, y: frame.midY - textHeight / 2, width: max(textWidth, 0), height: textHeight))

            if showsClose {
                let box = closeFrame(in: frame)
                if hover == .close(index) {
                    Theme.ink.withAlphaComponent(Theme.Wash.pressed).setFill()
                    NSBezierPath(roundedRect: box, xRadius: M.closeRadius, yRadius: M.closeRadius).fill()
                }
                Glyph.xmark.draw(in: box.insetBy(dx: M.closeGlyphInset, dy: M.closeGlyphInset), color: Theme.inkMuted, context: context)
            }
        }

        if hover == .plus {
            Theme.ink.withAlphaComponent(Theme.Wash.hoverStrong).setFill()
            NSBezierPath(roundedRect: plusFrame, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
        }
        Glyph.plus.draw(in: CGRect(x: plusFrame.midX - Theme.Icon.small / 2, y: plusFrame.midY - Theme.Icon.small / 2, width: Theme.Icon.small, height: Theme.Icon.small), color: Theme.inkMuted, context: context)
    }

    /// Rounded at the top, and at the bottom the outline swings outward so the tab runs into the toolbar below.
    private func activeTabPath(_ frame: CGRect) -> NSBezierPath {
        let r = M.radius
        let k = Self.cornerHandle
        let path = NSBezierPath()
        path.move(to: CGPoint(x: frame.minX - r, y: frame.maxY))
        path.curve(to: CGPoint(x: frame.minX, y: frame.maxY - r), controlPoint1: CGPoint(x: frame.minX - r * k, y: frame.maxY), controlPoint2: CGPoint(x: frame.minX, y: frame.maxY - r * k))
        path.line(to: CGPoint(x: frame.minX, y: frame.minY + r))
        path.curve(to: CGPoint(x: frame.minX + r, y: frame.minY), controlPoint1: CGPoint(x: frame.minX, y: frame.minY + r * k), controlPoint2: CGPoint(x: frame.minX + r * k, y: frame.minY))
        path.line(to: CGPoint(x: frame.maxX - r, y: frame.minY))
        path.curve(to: CGPoint(x: frame.maxX, y: frame.minY + r), controlPoint1: CGPoint(x: frame.maxX - r * k, y: frame.minY), controlPoint2: CGPoint(x: frame.maxX, y: frame.minY + r * k))
        path.line(to: CGPoint(x: frame.maxX, y: frame.maxY - r))
        path.curve(to: CGPoint(x: frame.maxX + r, y: frame.maxY), controlPoint1: CGPoint(x: frame.maxX, y: frame.maxY - r * k), controlPoint2: CGPoint(x: frame.maxX + r * k, y: frame.maxY))
        path.close()
        return path
    }

    // MARK: Mouse

    /// Follows the mouse until the button comes up. Past a few points of movement the tab comes loose and follows the mouse, swapping places with the neighbours it passes.
    private func trackTabDrag(from start: Int, event: NSEvent) {
        let startX = convert(event.locationInWindow, from: nil).x
        guard tabFrames.indices.contains(start), tabFrames.count > 1 else { return }
        let grab = startX - tabFrames[start].minX
        var index = start
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let x = convert(next.locationInWindow, from: nil).x
            guard dragging != nil || abs(x - startX) > Theme.dragThreshold else { continue }
            let width = tabFrames[index].width
            let lowest = tabFrames.first!.minX
            let highest = tabFrames.last!.maxX - width
            let minX = min(max(x - grab, lowest), highest)
            // A tab swaps once its leading edge in the direction of travel passes the neighbour's middle, so wide and narrow tabs both reach every place.
            if index + 1 < tabFrames.count, minX + width > tabFrames[index + 1].midX {
                onMove?(index, index + 1)
                index += 1
                layoutSubtreeIfNeeded()
            } else if index > 0, minX < tabFrames[index - 1].midX {
                onMove?(index, index - 1)
                index -= 1
                layoutSubtreeIfNeeded()
            }
            dragging = (index, minX)
            needsDisplay = true
        }
        dragging = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        hover = hit(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hover = .none
    }

    override func mouseDown(with event: NSEvent) {
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .tab(let index):
            onSelect?(index)
            trackTabDrag(from: index, event: event)
        case .close(let index):
            pressedClose = index
        case .plus:
            onNew?()
        case .none:
            // The empty part of the row is the window's title bar.
            if event.clickCount == 2 { window?.performZoom(nil) } else { mayDragWindow = true }
        }
    }

    /// The window move starts with the first real movement; starting it on a plain click makes AppKit log a warning.
    override func mouseDragged(with event: NSEvent) {
        guard mayDragWindow else { return }
        mayDragWindow = false
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedClose = nil }
        mayDragWindow = false
        guard let pressedClose, hit(at: convert(event.locationInWindow, from: nil)) == .close(pressedClose) else { return }
        hover = .none
        onClose?(pressedClose)
    }

    override func otherMouseUp(with event: NSEvent) {
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .tab(let index), .close(let index): onClose?(index)
        default: break
        }
    }
}
