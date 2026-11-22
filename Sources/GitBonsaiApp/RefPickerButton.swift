import AppKit
import GitEngine

/// The closed ref picker: a field-like control showing the chosen ref with its glyph, the muted SHA and age or subject, and a chevron. A click or ↓ / Space opens the list.
/// Like a pop-up button it takes the keyboard focus only with full keyboard access.
final class RefPickerButton: KeyboardControl {
    private typealias R = Theme.RefPicker

    var item: RefCatalog.Item? { didSet { needsDisplay = true; setAccessibilityValue(item?.title) } }
    /// Drawn with the focus border while the list is open.
    var isOpen = false { didSet { needsDisplay = true } }
    var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(String(localized: "branch.new.startPoint", defaultValue: "Start point", bundle: .module, comment: "Where a new branch starts: a branch, tag or commit."))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: R.height) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var showsFocus: Bool { isOpen || super.showsFocus }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onOpen?()
    }

    override func keyDown(with event: NSEvent) {
        // Space opens it through `performClick`, as it presses any `KeyboardControl`.
        guard [125, 126].contains(event.keyCode), isEnabled else { return super.keyDown(with: event) }
        onOpen?()
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        onOpen?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        typealias C = Theme.Control
        let focus = showsFocus
        let inset = (focus ? C.focusWidth : Theme.Stroke.hairline) / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: C.radius, yRadius: C.radius)
        Theme.surface2.setFill()
        path.fill()
        (focus ? Theme.moss : Theme.hairline).setStroke()
        path.lineWidth = focus ? C.focusWidth : Theme.Stroke.hairline
        path.stroke()

        let left = Theme.TextField.inset.width
        let right = bounds.width - Theme.TextField.inset.width
        let midY = bounds.midY
        let chevron = CGRect(x: right - R.chevron, y: midY - R.chevron / 2, width: R.chevron, height: R.chevron)
        Glyph.chevronDown.draw(in: chevron, color: Theme.inkMuted, context: context)
        guard let item else { return }
        RefItemStyle.drawGlyph(of: item, in: CGRect(x: left, y: midY - R.glyph / 2, width: R.glyph, height: R.glyph), color: Theme.inkMuted, context: context)

        let textLeft = left + R.glyph + R.glyphGap
        let available = chevron.minX - R.detailGap - textLeft
        let isHead = if case .head = item.kind { true } else { false }
        let titleFont = item.kind == .commit ? Theme.mono : isHead ? Theme.bodyStrong : Theme.body
        let title = NSAttributedString(string: item.title, attributes: [.font: titleFont, .foregroundColor: Theme.ink, .paragraphStyle: RefPickerRowView.truncating])
        let titleWidth = min(title.size().width, available)
        guard titleWidth > 0 else { return }
        RefPickerRowView.draw(title, x: textLeft, width: titleWidth, midY: midY)
        // A commit names itself by its SHA, so its subject follows; a ref shows where it points.
        let parts = RefItemStyle.detail(of: item)
        let detailText = item.kind == .commit ? RefItemStyle.commitText(of: item) : ([parts.sha].compactMap { $0 } + [parts.rest]).joined(separator: " · ")
        let detailLeft = textLeft + titleWidth + R.detailGap
        let detailWidth = chevron.minX - R.detailGap - detailLeft
        guard detailWidth > 0 else { return }
        let detail = NSAttributedString(string: detailText, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted, .paragraphStyle: RefPickerRowView.truncating])
        RefPickerRowView.draw(detail, x: detailLeft, width: detailWidth, midY: midY)
    }
}
