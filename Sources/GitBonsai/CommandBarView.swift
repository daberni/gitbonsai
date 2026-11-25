import AppKit

/// Covers the window while the command bar is open: a click beside the panel closes it, the panel floats centred `top` below the top edge, under the history header.
final class CommandBarOverlay: NSView {
    let panel = CommandBarPanel()
    var onClickOutside: (() -> Void)?

    init(top: CGFloat) {
        super.init(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: top),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(equalToConstant: Theme.CommandBar.width),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.Space.l),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { onClickOutside?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating panel: Liquid Glass tinted with paper, the search field with the mode it is in, and the result list.
final class CommandBarPanel: NSView {
    private typealias C = Theme.CommandBar

    let search = TextInput()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let glass = NSGlassEffectView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "commandBar.list.noMatches", defaultValue: "No matching commands", bundle: .module))
    private var listHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let content = NSView()
        glass.cornerRadius = Theme.Radius.lg
        glass.tintColor = Theme.surface1.withAlphaComponent(C.glassTint)
        glass.contentView = content
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        table.addTableColumn(NSTableColumn(identifier: .init("command")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.rowHeight = C.rowHeight
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        emptyLabel.font = Theme.body
        emptyLabel.textColor = Theme.inkMuted
        emptyLabel.isHidden = true

        for view in [search, scroll, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        listHeight = scroll.heightAnchor.constraint(equalToConstant: C.rowHeight)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: C.padding),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: C.padding),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -C.padding),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: C.listGap),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: C.listInset),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -C.listInset),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -C.listInset),
            listHeight,
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: C.padding + C.rowPadding),
        ])
    }

    /// The mode pill at the start of the field while a second step is open, such as "Go to Ref"; nil for the root list.
    func showMode(_ title: String?, glyph: CommandGlyph?) {
        guard let title, let glyph else { return search.leadingAddon = nil }
        if let pill = search.leadingAddon as? CommandModePill {
            pill.update(title: title, glyph: glyph)
        } else {
            search.leadingAddon = CommandModePill(title: title, glyph: glyph)
        }
    }

    /// Sizes the list to its rows, up to the visible maximum; an empty list keeps one row for "No matching commands".
    func showRows(_ count: Int) {
        listHeight.constant = CGFloat(max(min(count, C.maxVisibleRows), 1)) * C.rowHeight
        emptyLabel.isHidden = count > 0
    }
}

/// The mode of the command bar inside its field: the glyph and name of the command whose list is open, on an ink wash.
final class CommandModePill: NSView {
    private typealias C = Theme.CommandBar

    private(set) var title: String
    private var glyph: CommandGlyph

    init(title: String, glyph: CommandGlyph) {
        self.title = title
        self.glyph = glyph
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    func update(title: String, glyph: CommandGlyph) {
        self.title = title
        self.glyph = glyph
        setAccessibilityLabel(title)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    private var text: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Theme.caption, .foregroundColor: Theme.ink])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: C.modePadding * 2 + C.modeGlyph + C.modeGap + ceil(text.size().width), height: C.modeHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm)
        Theme.ink.withAlphaComponent(Theme.Wash.pressed).setFill()
        path.fill()
        let midY = bounds.midY
        CommandRowView.drawGlyph(glyph, in: CGRect(x: C.modePadding, y: midY - C.modeGlyph / 2, width: C.modeGlyph, height: C.modeGlyph), color: Theme.inkMuted, context: context)
        let label = text
        let size = label.size()
        label.draw(at: CGPoint(x: C.modePadding + C.modeGlyph + C.modeGap, y: midY - size.height / 2))
    }
}
