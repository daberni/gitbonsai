import AppKit

/// The title row: one tab per repository next to the traffic lights, then the button that opens another one.
/// The active tab takes the toolbar's color and flares into it at the bottom; the row itself stays in the window color.
final class TabBarView: NSView, NSViewToolTipOwner {
    struct Item: Equatable {
        let title: String
        let toolTip: String?
    }

    static let height: CGFloat = 38
    private static let tabTop: CGFloat = 4
    private static let radius: CGFloat = 10
    private static let textInset: CGFloat = 18
    private static let closeSlot: CGFloat = 28
    private static let widthRange: ClosedRange<CGFloat> = 96...240
    private static let minimumCompressedWidth: CGFloat = 56

    var items: [Item] = [] { didSet { if items != oldValue { needsLayout = true; needsDisplay = true } } }
    var activeIndex = 0 { didSet { needsDisplay = true } }
    /// Room for the traffic lights; less in full screen, where they are gone.
    var leadingInset: CGFloat = 84 { didSet { if leadingInset != oldValue { needsLayout = true; needsDisplay = true } } }
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
            let natural = ceil((item.title as NSString).size(withAttributes: attributes).width) + Self.textInset + Self.closeSlot
            return min(max(natural, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        }
        let plusWidth: CGFloat = 40
        let available = bounds.width - leadingInset - plusWidth - 12
        let total = widths.reduce(0, +)
        if total > available, total > 0 {
            let scale = available / total
            widths = widths.map { max(floor($0 * scale), Self.minimumCompressedWidth) }
        }
        var x = leadingInset
        tabFrames = widths.map { width in
            defer { x += width }
            return CGRect(x: x, y: Self.tabTop, width: width, height: bounds.height - Self.tabTop)
        }
        plusFrame = CGRect(x: x + 6, y: (Self.tabTop + Self.height) / 2 - 12, width: 28, height: 24)
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
        CGRect(x: tab.maxX - 8 - 16, y: tab.midY - 8, width: 16, height: 16)
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
                    Theme.ink.withAlphaComponent(0.06).setFill()
                    NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 4), xRadius: 7, yRadius: 7).fill()
                }
                let leftNeighbourIsQuiet = index > 0 && index - 1 != activeIndex && hover != .tab(index - 1) && hover != .close(index - 1)
                if leftNeighbourIsQuiet, !isHovered {
                    Theme.hairline.setFill()
                    CGRect(x: frame.minX, y: frame.minY + 7, width: 1, height: frame.height - 14).fill()
                }
            }

            let showsClose = isHovered
            let textWidth = frame.width - Self.textInset - (showsClose ? Self.closeSlot : 10)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: isActive ? Theme.bodyStrong : Theme.body, .foregroundColor: isActive ? Theme.ink : Theme.inkMuted, .paragraphStyle: paragraph]
            let title = NSAttributedString(string: items[index].title, attributes: attributes)
            let textHeight = title.size().height
            title.draw(in: CGRect(x: frame.minX + Self.textInset, y: frame.midY - textHeight / 2, width: max(textWidth, 0), height: textHeight))

            if showsClose {
                let box = closeFrame(in: frame)
                if hover == .close(index) {
                    Theme.ink.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                }
                Glyph.xmark.draw(in: box.insetBy(dx: 3.5, dy: 3.5), color: Theme.inkMuted, context: context)
            }
        }

        if hover == .plus {
            Theme.ink.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: plusFrame, xRadius: 6, yRadius: 6).fill()
        }
        Glyph.plus.draw(in: CGRect(x: plusFrame.midX - 7, y: plusFrame.midY - 7, width: 14, height: 14), color: Theme.inkMuted, context: context)
    }

    /// Rounded at the top, and at the bottom the outline swings outward so the tab runs into the toolbar below.
    private func activeTabPath(_ frame: CGRect) -> NSBezierPath {
        let r = Self.radius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: frame.minX - r, y: frame.maxY))
        path.curve(to: CGPoint(x: frame.minX, y: frame.maxY - r), controlPoint1: CGPoint(x: frame.minX - r * 0.45, y: frame.maxY), controlPoint2: CGPoint(x: frame.minX, y: frame.maxY - r * 0.45))
        path.line(to: CGPoint(x: frame.minX, y: frame.minY + r))
        path.curve(to: CGPoint(x: frame.minX + r, y: frame.minY), controlPoint1: CGPoint(x: frame.minX, y: frame.minY + r * 0.45), controlPoint2: CGPoint(x: frame.minX + r * 0.45, y: frame.minY))
        path.line(to: CGPoint(x: frame.maxX - r, y: frame.minY))
        path.curve(to: CGPoint(x: frame.maxX, y: frame.minY + r), controlPoint1: CGPoint(x: frame.maxX - r * 0.45, y: frame.minY), controlPoint2: CGPoint(x: frame.maxX, y: frame.minY + r * 0.45))
        path.line(to: CGPoint(x: frame.maxX, y: frame.maxY - r))
        path.curve(to: CGPoint(x: frame.maxX + r, y: frame.maxY), controlPoint1: CGPoint(x: frame.maxX, y: frame.maxY - r * 0.45), controlPoint2: CGPoint(x: frame.maxX + r * 0.45, y: frame.maxY))
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
            guard dragging != nil || abs(x - startX) > 4 else { continue }
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
