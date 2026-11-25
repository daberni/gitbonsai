import AppKit

/// A changed image in place of the diff lines: the canvas, the opacity slider of the onion skin and the button that loads large images.
final class ImageDiffView: NSView {
    private typealias T = Theme.ImageDiff
    var onLoadLarge: (() -> Void)?
    let canvas = ImageCanvasView()
    let opacity = NSSlider(value: T.initialOpacity, minValue: 0, maxValue: 1, target: nil, action: nil)
    let loadButton = NSButton()
    private let controls = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        opacity.target = self
        opacity.action = #selector(changeOpacity(_:))
        opacity.toolTip = String(localized: "diff.image.opacity", defaultValue: "Opacity of the new image", bundle: .module, comment: "Tooltip of the onion skin slider")
        opacity.widthAnchor.constraint(equalToConstant: T.sliderWidth).isActive = true
        loadButton.bezelStyle = .rounded
        loadButton.title = String(localized: "diff.image.loadLarge", defaultValue: "Load large Images", bundle: .module, comment: "Button that loads images too large to load on their own")
        loadButton.target = self
        loadButton.action = #selector(loadLarge(_:))
        controls.orientation = .horizontal
        controls.spacing = Theme.Space.m
        controls.addArrangedSubview(opacity)
        controls.addArrangedSubview(loadButton)
        for subview in [canvas, controls] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -Theme.Space.s),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.m),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(old: ImageSideState, new: ImageSideState, mode: ImageDiffMode) {
        canvas.show(old: old, new: new, mode: mode)
        opacity.isHidden = canvas.drawnMode != .onionSkin
        opacity.doubleValue = canvas.opacity
        loadButton.isHidden = !canvas.hasLargeSide
        controls.isHidden = opacity.isHidden && loadButton.isHidden
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface0.setFill()
        bounds.fill()
    }

    @objc private func changeOpacity(_ sender: Any?) { canvas.opacity = opacity.doubleValue }
    @objc private func loadLarge(_ sender: Any?) { onLoadLarge?() }
}

/// Draws both sides of an image change on a checkerboard, with label and caption, in the chosen mode; in the swipe mode a drag moves the line.
final class ImageCanvasView: NSView {
    private typealias T = Theme.ImageDiff
    private var old = ImageSideState.absent
    private var new = ImageSideState.absent
    private var mode = ImageDiffMode.sideBySide
    var opacity = T.initialOpacity { didSet { needsDisplay = true } }
    /// The swipe line as a share of the image frame's width; left of it the old image, right of it the new one.
    var swipe = T.initialSwipe { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// Swipe and onion skin need an image on both sides; otherwise both are shown side by side.
    var drawnMode: ImageDiffMode {
        guard case .image = old, case .image = new else { return .sideBySide }
        return mode == .text ? .sideBySide : mode
    }

    var hasLargeSide: Bool {
        [old, new].contains { if case .tooLarge = $0 { true } else { false } }
    }

    func show(old: ImageSideState, new: ImageSideState, mode: ImageDiffMode) {
        self.old = old
        self.new = new
        self.mode = mode
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: T.padding, dy: T.padding)
        guard area.width > 0, area.height > 0 else { return }
        switch drawnMode {
        case .swipe, .onionSkin: drawOverlay(in: area)
        case .sideBySide, .text: drawSideBySide(in: area)
        }
    }

    private func drawSideBySide(in area: NSRect) {
        let sides: [(ImageSideState, Bool)] = [(old, false), (new, true)].filter { if case .absent = $0.0 { false } else { true } }
        guard !sides.isEmpty else { return }
        let width = (area.width - T.columnGap * CGFloat(sides.count - 1)) / CGFloat(sides.count)
        for (index, side) in sides.enumerated() {
            let column = NSRect(x: area.minX + CGFloat(index) * (width + T.columnGap), y: area.minY, width: width, height: area.height)
            drawColumn(side.0, isNew: side.1, in: column)
        }
    }

    /// Label right above, caption right below, the image as large as fits between them but never above its own size.
    private func drawColumn(_ state: ImageSideState, isNew: Bool, in column: NSRect) {
        let label = Self.label(isNew: isNew)
        let caption = Self.caption(state)
        let labelSize = label.size()
        let captionSize = caption.size()
        let room = NSRect(x: column.minX, y: column.minY + labelSize.height + T.gap, width: column.width, height: column.height - labelSize.height - captionSize.height - 2 * T.gap)
        let frame: NSRect
        switch state {
        case .image(let preview):
            frame = Self.fit(preview.size, in: room)
            Self.drawChecker(in: frame)
            preview.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        default:
            frame = Self.fit(CGSize(width: room.width, height: min(room.height, room.width * T.placeholderAspect)), in: room)
            Theme.surface1.setFill()
            NSBezierPath(roundedRect: frame, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
        }
        Theme.hairline.setStroke()
        NSBezierPath(rect: frame.insetBy(dx: -Theme.Stroke.hairline / 2, dy: -Theme.Stroke.hairline / 2)).stroke()
        label.draw(at: CGPoint(x: column.midX - labelSize.width / 2, y: frame.minY - T.gap - labelSize.height))
        caption.draw(at: CGPoint(x: column.midX - captionSize.width / 2, y: frame.maxY + T.gap))
    }

    /// One frame holds both images, each fitted into it, so images of different sizes line up at the centre.
    private func drawOverlay(in area: NSRect) {
        guard case .image(let before) = old, case .image(let after) = new else { return }
        let oldCaption = Self.caption(old, prefix: Self.label(isNew: false).string)
        let newCaption = Self.caption(new, prefix: Self.label(isNew: true).string)
        let captionHeight = max(oldCaption.size().height, newCaption.size().height)
        let room = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - captionHeight - T.gap)
        let size = CGSize(width: max(before.size.width, after.size.width), height: max(before.size.height, after.size.height))
        let frame = Self.fit(size, in: room)
        Self.drawChecker(in: frame)
        let oldRect = Self.fit(before.size, in: frame)
        let newRect = Self.fit(after.size, in: frame)
        if drawnMode == .onionSkin {
            before.image.draw(in: oldRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            after.image.draw(in: newRect, from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
        } else {
            let lineX = frame.minX + frame.width * swipe
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: frame.minX, y: frame.minY, width: lineX - frame.minX, height: frame.height).clip()
            before.image.draw(in: oldRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: lineX, y: frame.minY, width: frame.maxX - lineX, height: frame.height).clip()
            after.image.draw(in: newRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            drawHandle(at: lineX, in: frame)
        }
        Theme.hairline.setStroke()
        NSBezierPath(rect: frame.insetBy(dx: -Theme.Stroke.hairline / 2, dy: -Theme.Stroke.hairline / 2)).stroke()
        oldCaption.draw(at: CGPoint(x: frame.minX, y: frame.maxY + T.gap))
        newCaption.draw(at: CGPoint(x: frame.maxX - newCaption.size().width, y: frame.maxY + T.gap))
        swipeFrame = frame
    }

    private func drawHandle(at x: CGFloat, in frame: NSRect) {
        Theme.moss.setFill()
        NSRect(x: x - T.handleWidth / 2, y: frame.minY, width: T.handleWidth, height: frame.height).fill()
        let knob = NSRect(x: x - T.knob / 2, y: frame.midY - T.knob / 2, width: T.knob, height: T.knob)
        NSBezierPath(ovalIn: knob).fill()
        Theme.onMoss.setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: T.knob / 4, dy: T.knob / 4))
        ring.lineWidth = Theme.Stroke.hairline
        ring.stroke()
    }

    private static func drawChecker(in frame: NSRect) {
        Theme.surface2.setFill()
        frame.fill()
        Theme.hairline.setFill()
        let columns = Int((frame.width / T.checker).rounded(.up))
        let rows = Int((frame.height / T.checker).rounded(.up))
        NSGraphicsContext.saveGraphicsState()
        frame.clip()
        for row in 0..<rows {
            for column in 0..<columns where (row + column) % 2 == 1 {
                NSRect(x: frame.minX + CGFloat(column) * T.checker, y: frame.minY + CGFloat(row) * T.checker, width: T.checker, height: T.checker).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Scaled down to fit, never up, centred, on whole points.
    private static func fit(_ size: CGSize, in room: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return .zero }
        let scale = min(1, room.width / size.width, room.height / size.height)
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        return NSRect(x: (room.midX - width / 2).rounded(), y: (room.midY - height / 2).rounded(), width: width, height: height)
    }

    // MARK: Text

    private static func label(isNew: Bool) -> NSAttributedString {
        let text = isNew ? String(localized: "diff.image.new", defaultValue: "New", bundle: .module, comment: "Label above the new side of an image diff") : String(localized: "diff.image.old", defaultValue: "Old", bundle: .module, comment: "Label above the old side of an image diff")
        return NSAttributedString(string: text, attributes: [.font: Theme.bodyStrong, .foregroundColor: isNew ? Theme.moss : Theme.clay])
    }

    /// Dimensions and file size, or why the side shows no image.
    private static func caption(_ state: ImageSideState, prefix: String? = nil) -> NSAttributedString {
        var text: String
        switch state {
        case .image(let preview):
            let width = Int(preview.size.width.rounded()).formatted(.number.locale(AppLanguage.locale))
            let height = Int(preview.size.height.rounded()).formatted(.number.locale(AppLanguage.locale))
            let dimensions = preview.pixelSize == nil ? String(localized: "diff.image.points", defaultValue: "\(width) × \(height) pt", bundle: .module, comment: "Size of a vector image, width × height in points") : String(localized: "diff.image.pixels", defaultValue: "\(width) × \(height) px", bundle: .module, comment: "Size of a bitmap image, width × height in pixels")
            text = "\(dimensions) · \(bytes(preview.byteCount))"
        case .tooLarge(let byteCount):
            text = String(localized: "diff.image.tooLarge", defaultValue: "\(bytes(byteCount)), not loaded", bundle: .module, comment: "Caption of an image too large to load on its own, e.g. 48 MB, not loaded")
        case .unreadable(let byteCount):
            let reason = String(localized: "diff.image.unreadable", defaultValue: "Cannot show this image", bundle: .module)
            text = byteCount.map { "\(reason) · \(bytes($0))" } ?? reason
        case .absent:
            text = ""
        }
        if let prefix { text = "\(prefix): \(text)" }
        return NSAttributedString(string: text, attributes: [.font: Theme.captionDigits, .foregroundColor: Theme.inkMuted])
    }

    private static func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file).locale(AppLanguage.locale))
    }

    // MARK: Swipe

    private var swipeFrame = NSRect.zero

    /// Follows the mouse in a tracking loop until the button is released, so the line moves with the drag wherever the pointer goes.
    override func mouseDown(with event: NSEvent) {
        guard drawnMode == .swipe else { return }
        moveSwipe(to: event)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            moveSwipe(to: next)
            if next.type == .leftMouseUp { break }
        }
    }

    private func moveSwipe(to event: NSEvent) {
        guard drawnMode == .swipe, swipeFrame.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        swipe = min(1, max(0, (x - swipeFrame.minX) / swipeFrame.width))
    }

    override func resetCursorRects() {
        if drawnMode == .swipe { addCursorRect(swipeFrame, cursor: .resizeLeftRight) }
    }
}
