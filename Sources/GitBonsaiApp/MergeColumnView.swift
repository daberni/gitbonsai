import AppKit
import GitEngine

/// One column of the conflict view: read-only mono lines of one fixed height, never wrapped, with the bands of changes drawn behind them. Action rows show links, which `onLink` reports.
final class MergeColumnView: NSTextView, NSTextViewDelegate {
    static let linkScheme = "gitbonsai-conflict"
    var onLink: ((String) -> Void)?
    private(set) var bands: [MergeLayout.Band] = []
    private var actionRows: [Int] = []
    /// The line number of each row; nil for padding and action rows. `LineNumberMargin` draws them over the column's left inset.
    private(set) var numbers: [Int?] = []
    private(set) var numberWidth: CGFloat = 0
    var onNumbersChanged: (() -> Void)?
    /// The layout manager holds its storage only weakly; the column keeps it.
    private let storage = NSTextStorage()
    /// The change the keyboard navigation stands on, as a place in rows.
    var current: MergeLayout.Place? { didSet { needsDisplay = true } }
    static let lineHeight: CGFloat = {
        let layout = NSLayoutManager()
        return ceil(layout.defaultLineHeight(for: Theme.mono))
    }()

    init() {
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        storage.addLayoutManager(layout)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = [.width, .height]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        linkTextAttributes = [.foregroundColor: Theme.moss, .cursor: NSCursor.pointingHand]
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show(_ text: MergeLayout.Text) {
        bands = text.bands
        numbers = text.numbers
        let digits = max(String(numbers.compactMap { $0 }.max() ?? 1).count, 2)
        numberWidth = ceil(NSAttributedString(string: String(repeating: "8", count: digits), attributes: [.font: Theme.captionDigits]).size().width) + 2 * Theme.Conflict.numberPadding
        textContainerInset = NSSize(width: numberWidth + Theme.Conflict.numberPadding, height: 0)
        onNumbersChanged?()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        let content = NSMutableAttributedString(string: text.lines.joined(separator: "\n"), attributes: [.font: Theme.mono, .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
        // Faint text: the base standing in for an open conflict.
        let starts = text.lines.reduce(into: [0]) { $0.append($0.last! + ($1 as NSString).length + 1) }
        for band in text.bands where band.isFaint && band.lines > 0 {
            let start = starts[band.row]
            let end = starts[min(band.row + band.lines, text.lines.count)] - 1
            content.addAttribute(.foregroundColor, value: Theme.inkFaint, range: NSRange(location: start, length: max(0, end - start)))
        }
        // Action rows replace their empty line with a label and links, last row first so earlier offsets stay valid.
        for row in text.actionRows.keys.sorted(by: >) {
            guard let actionRow = text.actionRows[row], starts.indices.contains(row) else { continue }
            content.replaceCharacters(in: NSRange(location: starts[row], length: (text.lines[row] as NSString).length), with: Self.render(actionRow, paragraph: paragraph))
        }
        actionRows = Array(text.actionRows.keys)
        textStorage?.setAttributedString(content)
        sizeToFit()
        needsDisplay = true
    }

    private static func render(_ row: MergeLayout.ActionRow, paragraph: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString(string: row.label + "   ", attributes: base)
        for (offset, action) in row.actions.enumerated() {
            if offset > 0 { text.append(NSAttributedString(string: "  ·  ", attributes: base)) }
            var attributes = base
            attributes[.font] = Theme.pillStrong
            attributes[.link] = "\(linkScheme):\(action.link)"
            text.append(NSAttributedString(string: action.title, attributes: attributes))
        }
        return text
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let value = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
        guard value.hasPrefix(Self.linkScheme + ":") else { return false }
        onLink?(String(value.dropFirst(Self.linkScheme.count + 1)))
        return true
    }

    /// The center of a link in the column, for real clicks of the harness.
    func center(ofLink link: String) -> NSPoint? {
        guard let storage = textStorage, let layoutManager, let textContainer else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? String) == "\(Self.linkScheme):\(link)" { found = range; stop.pointee = true }
        }
        guard let found else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return NSPoint(x: rect.midX + textContainerOrigin.x, y: rect.midY + textContainerOrigin.y)
    }

    /// The vertical position of a row inside the column.
    static func y(ofRow row: Int) -> CGFloat { CGFloat(row) * lineHeight }

    static func color(of tint: MergeLayout.Tint) -> NSColor {
        switch tint {
        case .ours: Theme.moss
        case .theirs: Theme.sky
        case .conflict: Theme.persimmon
        case .resolved: Theme.ochre
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let width = max(bounds.width, enclosingScrollView?.contentView.bounds.maxX ?? 0)
        for band in bands {
            let color = Self.color(of: band.tint)
            let area = NSRect(x: 0, y: Self.y(ofRow: band.row), width: width, height: max(Self.y(ofRow: band.rows), Theme.Conflict.emptyBand))
            guard area.intersects(rect) else { continue }
            color.mixed(into: Theme.surface0, fraction: Theme.Conflict.bandTint).setFill()
            area.fill()
            // Padding rows show that the side has no line there.
            if band.lines < band.rows {
                color.mixed(into: Theme.surface0, fraction: Theme.Conflict.paddingTint).setFill()
                NSRect(x: 0, y: Self.y(ofRow: band.row + band.lines), width: width, height: max(Self.y(ofRow: band.rows - band.lines), Theme.Conflict.emptyBand)).fill()
            }
            color.withAlphaComponent(Theme.Conflict.bandEdgeAlpha).setFill()
            NSRect(x: 0, y: area.minY, width: width, height: Theme.Stroke.hairline).fill()
            NSRect(x: 0, y: area.maxY - Theme.Stroke.hairline, width: width, height: Theme.Stroke.hairline).fill()
        }
        for row in actionRows {
            let area = NSRect(x: 0, y: Self.y(ofRow: row), width: width, height: Self.lineHeight)
            guard area.intersects(rect) else { continue }
            Theme.surface1.setFill()
            area.fill()
        }
        if let current {
            let area = NSRect(x: 0, y: Self.y(ofRow: current.row), width: width, height: max(Self.y(ofRow: current.rows), Theme.Conflict.emptyBand))
            Theme.ink.withAlphaComponent(Theme.Conflict.currentAlpha).setFill()
            NSRect(x: 0, y: area.minY, width: Theme.Conflict.currentStroke, height: area.height).fill()
        }
    }
}

/// The strip between two columns with the actions of each change of one side: take it into the result, or ignore it.
final class MergeGutterView: NSView {
    struct Action {
        let change: Int
        let take: Bool
        let button: NSButton
    }

    var onAction: ((Int, Bool) -> Void)?
    private let side: ConflictSide
    private(set) var actions: [Action] = []
    private var places: [MergeLayout.Place] = []
    /// The scroll position of the columns; the buttons move with the lines.
    var offset: CGFloat = 0 { didSet { needsLayout = true } }

    init(side: ConflictSide) {
        self.side = side
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Buttons for every change in which this side differs from the base: take it when it is not in the result, ignore it when it is; an open conflict offers both.
    func show(_ resolution: MergeResolution, places: [MergeLayout.Place]) {
        actions.forEach { $0.button.removeFromSuperview() }
        actions = []
        self.places = places
        for (index, change) in resolution.changes.enumerated() where change.lines(of: side) != change.base || change.kind == .conflict {
            let isTaken = resolution.states[index].taken.contains(side) && resolution.states[index].merged == nil
            let isOpen = !resolution.isResolved(index)
            if isOpen || !isTaken { actions.append(Action(change: index, take: true, button: button(take: true))) }
            if isOpen || isTaken { actions.append(Action(change: index, take: false, button: button(take: false))) }
        }
        actions.forEach { addSubview($0.button) }
        needsLayout = true
    }

    private func button(take: Bool) -> NSButton {
        let symbol = take ? (side == .ours ? "chevron.right.2" : "chevron.left.2") : "xmark"
        let tip = switch (take, side) {
        case (true, .ours): String(localized: "conflict.action.takeOurs", defaultValue: "Take ours into the result", bundle: .module, comment: "Tooltip of the gutter button that puts our change into the merge result")
        case (true, .theirs): String(localized: "conflict.action.takeTheirs", defaultValue: "Take theirs into the result", bundle: .module, comment: "Tooltip of the gutter button that puts their change into the merge result")
        case (false, .ours): String(localized: "conflict.action.ignoreOurs", defaultValue: "Ignore ours", bundle: .module, comment: "Tooltip of the gutter button that leaves our change out of the merge result")
        case (false, .theirs): String(localized: "conflict.action.ignoreTheirs", defaultValue: "Ignore theirs", bundle: .module, comment: "Tooltip of the gutter button that leaves their change out of the merge result")
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.Conflict.gutterSymbol, weight: .semibold)
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(configuration) ?? NSImage(), target: self, action: #selector(run(_:)))
        button.isBordered = false
        button.toolTip = tip
        button.contentTintColor = take ? MergeColumnView.color(of: side == .ours ? .ours : .theirs) : Theme.inkMuted
        return button
    }

    override func layout() {
        super.layout()
        let size = Theme.Conflict.gutterButton
        for action in actions {
            guard places.indices.contains(action.change) else { continue }
            let top = MergeColumnView.y(ofRow: places[action.change].row) - offset
            let pair = actions.filter { $0.change == action.change }
            let slot = CGFloat(pair.firstIndex { $0.button === action.button } ?? 0)
            let x = (bounds.width - size * CGFloat(pair.count)) / 2 + slot * size
            action.button.frame = NSRect(x: x, y: top, width: size, height: max(size, MergeColumnView.lineHeight))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    @objc private func run(_ sender: NSButton) {
        guard let action = actions.first(where: { $0.button === sender }) else { return }
        onAction?(action.change, action.take)
    }
}

/// The line numbers of a column, over the left edge of its scroll view: they stay in place while the column scrolls sideways and follow it up and down.
final class LineNumberMargin: NSView {
    private weak var column: MergeColumnView?
    private var width: NSLayoutConstraint!

    init(column: MergeColumnView) {
        self.column = column
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: 0)
        width.isActive = true
        column.onNumbersChanged = { [weak self] in
            self?.width.constant = column.numberWidth
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Pins the margin over the left edge of the column's scroll view.
    func install(over scroll: NSScrollView, in container: NSView) {
        container.addSubview(self, positioned: .above, relativeTo: scroll)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            topAnchor.constraint(equalTo: scroll.topAnchor),
            bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
    }

    override func scrollWheel(with event: NSEvent) {
        column?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let column, let clip = column.enclosingScrollView?.contentView else { return }
        Theme.surface1.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: bounds.maxX - Theme.Stroke.hairline, y: 0, width: Theme.Stroke.hairline, height: bounds.height).fill()
        let top = clip.bounds.minY
        let height = MergeColumnView.lineHeight
        let numbers = column.numbers
        let first = max(0, Int(floor((top + dirtyRect.minY) / height)))
        let last = min(numbers.count - 1, Int(ceil((top + dirtyRect.maxY) / height)))
        guard first <= last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.captionDigits, .foregroundColor: Theme.inkFaint]
        for row in first...last {
            guard let number = numbers[row] else { continue }
            let label = NSAttributedString(string: String(number), attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.maxX - Theme.Conflict.numberPadding - size.width, y: MergeColumnView.y(ofRow: row) - top + (height - size.height) / 2))
        }
    }
}
