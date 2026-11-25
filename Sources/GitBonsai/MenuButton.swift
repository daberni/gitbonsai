import AppKit

/// A toolbar action with several variants, split in two like a macOS split button: the main part runs the default variant, the chevron behind a divider opens all variants below the button.
/// The default is the menu's first enabled entry, so the menus list it first. The chevron part adds a fixed width, so the button never changes size with the menu's contents.
/// While its operation runs, a spinner takes the glyph's place, the button stays pressed and every click opens `runningMenu` instead.
final class MenuButton: NSButton, NSMenuDelegate {
    private let entries: () -> NSMenu
    private let divider = DividerLine()
    private let chevron = NSImageView()
    private let spinner = NSProgressIndicator()
    private let glyph: NSImage?
    /// The menu a click opens while the operation runs, such as Cancel.
    var runningMenu: (() -> NSMenu)?
    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            // A blank image of the glyph's size keeps the title in place under the spinner.
            image = isRunning ? glyph.map { NSImage(size: $0.size) } : glyph
            if isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            setPressed(isRunning)
            needsLayout = true
        }
    }

    init(_ title: LocalizedStringResource, _ symbol: String, enabled: Bool, entries: @escaping () -> NSMenu) {
        self.entries = entries
        glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        super.init(frame: .zero)
        cell = SplitCell()
        self.title = title.text
        image = glyph
        imagePosition = .imageLeading
        bezelStyle = .rounded
        controlSize = .large
        target = self
        action = #selector(runDefault(_:))
        isEnabled = enabled

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: String(localized: "toolbar.menu.options", defaultValue: "Options", bundle: .module, comment: "The chevron part of a toolbar split button."))
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Toolbar.chevronSize, weight: .semibold)
        chevron.contentTintColor = Theme.inkMuted
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [divider, chevron, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: Theme.Stroke.hairline),
            divider.heightAnchor.constraint(equalToConstant: Theme.Toolbar.dividerHeight),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Toolbar.menuPart),
            chevron.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Toolbar.menuPart / 2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateParts()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { updateParts() } }

    override func layout() {
        super.layout()
        var main = bounds
        main.size.width -= Theme.Toolbar.menuPart
        let glyphFrame = cell?.imageRect(forBounds: main) ?? .zero
        let side = min(glyphFrame.width, glyphFrame.height).rounded(.up)
        spinner.frame = NSRect(x: glyphFrame.midX - side / 2, y: glyphFrame.midY - side / 2, width: side, height: side)
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += Theme.Toolbar.menuPart
        return size
    }

    /// Disabled, divider and chevron fade like the title.
    private func updateParts() {
        let alpha = isEnabled ? 1 : Theme.Toolbar.disabledAlpha
        divider.alphaValue = alpha
        chevron.alphaValue = alpha
    }

    /// A press on the chevron part opens the variants; anywhere else the button tracks the click as usual and runs the default.
    override func mouseDown(with event: NSEvent) {
        if isRunning, let runningMenu {
            open(runningMenu())
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, point.x >= bounds.maxX - Theme.Toolbar.menuPart else {
            super.mouseDown(with: event)
            return
        }
        // Built anew for every opening, since branch, upstream and remotes change between clicks. The button shows pressed while the menu is open and lets go the moment it closes:
        // `popUp` returns only after the chosen entry's action has run, so waiting for it would keep the button pressed through that action.
        open(entries())
    }

    private func open(_ menu: NSMenu) {
        menu.delegate = self
        setPressed(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + Theme.Space.xs), in: self)
        setPressed(isRunning)
    }

    func menuDidClose(_ menu: NSMenu) {
        setPressed(isRunning)
    }

    /// Draws the change at once instead of with the window's next update, which waits for the menu's tracking to unwind.
    private func setPressed(_ pressed: Bool) {
        guard isHighlighted != pressed else { return }
        isHighlighted = pressed
        displayIfNeeded()
    }

    /// Divider and chevron are drawing only; every press belongs to the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    @objc private func runDefault(_ sender: Any?) {
        if isRunning, let runningMenu {
            open(runningMenu())
            return
        }
        let menu = entries()
        guard let index = menu.items.firstIndex(where: { $0.isEnabled && !$0.isSeparatorItem && $0.action != nil }) else { return }
        menu.performActionForItem(at: index)
    }
}

/// Lays out image and title in the main part only, left of the chevron part.
private final class SplitCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var main = cellFrame
        main.size.width -= Theme.Toolbar.menuPart
        super.drawInterior(withFrame: main, in: controlView)
    }
}

/// The divider between the main part and the chevron part of a split button.
private final class DividerLine: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.inkFaint.cgColor
        }
    }
}
