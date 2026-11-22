import AppKit

/// git's output under a failure: a "Git-Ausgabe" disclosure with "Kopieren" beside it, and below it, collapsed by default, a selectable monospace box in the text field style.
/// The box is as tall as the output, up to `Theme.Failure.outputMaxHeight`; longer output scrolls. Lines wrap, so nothing is cut off at either edge.
@MainActor
final class FailureDetailsView: NSView {
    private typealias M = Theme.Failure

    private(set) lazy var disclosure = LinkButton(target: self, action: #selector(toggle(_:)))
    private(set) lazy var copyButton = LinkButton(target: self, action: #selector(copy(_:)))
    let output = NSTextView()
    private let box = FieldBox()
    private let scroll = NSScrollView()
    private let details: String
    private var boxHeight: NSLayoutConstraint!
    private var collapsedBottom: NSLayoutConstraint!
    private var expandedBottom: NSLayoutConstraint!
    /// The sheet fits itself again, so it grows or shrinks with the details.
    var onToggle: (() -> Void)?

    init(details: String, width: CGFloat) {
        self.details = details
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        disclosure.imagePosition = .imageLeading
        disclosure.imageHugsTitle = true
        disclosure.setAccessibilityLabel("Git-Ausgabe")
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: M.copyGlyph, weight: .regular))
        copyButton.imagePosition = .imageLeading
        copyButton.imageHugsTitle = true
        copyButton.contentTintColor = Theme.inkMuted
        setCopyTitle("Kopieren")

        output.string = details
        output.font = Theme.monoSmall
        output.textColor = Theme.ink
        output.isEditable = false
        output.isSelectable = true
        output.drawsBackground = false
        output.textContainerInset = M.outputInset
        output.isVerticallyResizable = true
        output.isHorizontallyResizable = false
        output.autoresizingMask = .width
        output.textContainer?.widthTracksTextView = true
        scroll.documentView = output
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // A sheet's title bar would otherwise push the text below the box's top edge.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // The rounded box clips the scrolled text to its corners.
        scroll.contentView.wantsLayer = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Theme.Control.radius
        scroll.layer?.masksToBounds = true

        for view in [disclosure, copyButton, box] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        let inset = Theme.Stroke.hairline
        boxHeight = box.heightAnchor.constraint(equalToConstant: boxHeight(width: width))
        collapsedBottom = disclosure.bottomAnchor.constraint(equalTo: bottomAnchor)
        expandedBottom = box.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            disclosure.topAnchor.constraint(equalTo: topAnchor),
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: disclosure.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: disclosure.bottomAnchor, constant: M.outputGap),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            boxHeight,
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
        ])
        isExpanded = false
    }

    required init?(coder: NSCoder) { nil }

    var isExpanded: Bool {
        get { !box.isHidden }
        set {
            box.isHidden = !newValue
            collapsedBottom.isActive = !newValue
            expandedBottom.isActive = newValue
            let symbol = newValue ? "chevron.down" : "chevron.right"
            disclosure.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: M.chevron, weight: .semibold))
            disclosure.contentTintColor = Theme.inkMuted
            disclosure.attributedTitle = NSAttributedString(string: "Git-Ausgabe", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
            disclosure.setAccessibilityExpanded(newValue)
            layoutSubtreeIfNeeded()
            onToggle?()
            // The text view grows to its text only once the sheet has laid out, and the clip view keeps its bottom; git's first line belongs at the top.
            DispatchQueue.main.async { [weak self] in self?.output.scroll(.zero) }
        }
    }

    /// The output's height as the text view lays it out at the box's width, plus the box's insets and border, within the box's limits.
    private func boxHeight(width: CGFloat) -> CGFloat {
        let border = Theme.Stroke.hairline
        output.frame = NSRect(x: 0, y: 0, width: width - 2 * border, height: 0)
        guard let layoutManager = output.layoutManager, let container = output.textContainer else { return M.outputMaxHeight }
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height) + 2 * (M.outputInset.height + border)
        return min(max(height, M.outputMinHeight), M.outputMaxHeight)
    }

    @objc private func toggle(_ sender: Any?) { isExpanded.toggle() }

    @objc private func copy(_ sender: Any?) {
        ActionRunner.copy(details)
        setCopyTitle("Kopiert")
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Detail.copiedFeedback) { [weak self] in self?.setCopyTitle("Kopieren") }
    }

    private func setCopyTitle(_ title: String) {
        copyButton.attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
    }
}
