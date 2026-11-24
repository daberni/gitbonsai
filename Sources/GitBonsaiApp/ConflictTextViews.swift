import AppKit

/// Text previews in the conflict view never wrap: a block of lines sits in a scroll view that only scrolls sideways and is exactly as tall as its lines.
enum NoWrapText {
    /// A text view whose lines grow sideways instead of wrapping, inside `scroll`.
    @MainActor static func install(_ text: NSTextView, in scroll: SidewaysScrollView) {
        text.font = Theme.mono
        text.textColor = Theme.ink
        text.drawsBackground = false
        text.isRichText = false
        text.textContainerInset = .zero
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width, .height]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
    }

    /// The height of the text's lines, at least one line.
    @MainActor static func height(of text: NSTextView) -> CGFloat {
        guard let layoutManager = text.layoutManager, let container = text.textContainer else { return 0 }
        layoutManager.ensureLayout(for: container)
        let line = layoutManager.defaultLineHeight(for: text.font ?? Theme.mono)
        return max(layoutManager.usedRect(for: container).height, line)
    }

    /// Scrolls sideways to `x`, kept inside the content.
    @MainActor static func scroll(_ scroll: NSScrollView, toX x: CGFloat) {
        let clip = scroll.contentView
        guard abs(clip.bounds.minX - x) > 0.5 else { return }
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: x, y: clip.bounds.minY), size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
    }
}

/// A scroll view for one block of lines: it scrolls sideways and leaves vertical scrolling to the conflict view around it.
final class SidewaysScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        NSEvent.split(event, sideways: { super.scrollWheel(with: $0) }, vertical: { nextResponder?.scrollWheel(with: $0) })
    }
}

/// A caption and lines in mono, tinted in a side's colour, such as the file one side kept. Long lines scroll sideways.
final class ConflictBlockView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private let tint: NSColor?
    private let scroll = SidewaysScrollView()
    private let text = NSTextView()

    init(caption: RefString, lines: [String], tint: NSColor?) {
        self.tint = tint
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.font = Theme.label
        label.textColor = Theme.inkMuted
        label.lineBreakMode = .byTruncatingTail
        label.setText(caption)
        NoWrapText.install(text, in: scroll)
        text.isEditable = false
        text.isSelectable = true
        // A trailing carriage return stays in the result but is not drawn.
        text.string = lines.isEmpty ? String(localized: "conflict.side.empty", defaultValue: "(no lines)", bundle: .module, comment: "A side of a conflict hunk that has no lines") : lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.joined(separator: "\n")
        text.textColor = lines.isEmpty ? Theme.inkFaint : Theme.ink
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let stack = NSStackView(views: [label, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let padding = Theme.Conflict.blockPadding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: NoWrapText.height(of: text)),
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The sideways scroll position; harness checks print it.
    var scrollX: CGFloat { scroll.contentView.bounds.minX }

    func scroll(toX x: CGFloat) {
        NoWrapText.scroll(scroll, toX: x)
    }

    @objc private func scrolled(_ notification: Notification) {
        onScroll?(scroll.contentView.bounds.minX)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Conflict.blockRadius
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        (tint?.mixed(into: Theme.surface0, fraction: Theme.Conflict.sideTint) ?? Theme.surface0).setFill()
        path.fill()
    }
}
