import AppKit

/// The body of a commit message in the detail panel: selectable text as tall as it is, up to the inline editor's maximum, and scrolling inside beyond it, so a long message neither pushes the files down nor moves anything when it turns into the editor.
final class MessageBodyView: NSScrollView {
    private let text = NSTextView()
    private var height: NSLayoutConstraint!

    init(_ string: String) {
        super.init(frame: .zero)
        text.string = string
        text.font = Theme.body
        text.textColor = Theme.inkMuted
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        documentView = text
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    required init?(coder: NSCoder) { nil }

    /// The text wraps at the panel's width, so its height is known only once the width is. The height is decided from the view's own width alone: measuring at the current content width would let a legacy scroller that appears or hides change the wrap, then the height, then the scroller again, a layout loop AppKit ends with an exception.
    override func layout() {
        super.layout()
        let fullWidth = bounds.width
        let fullHeight = measuredHeight(width: fullWidth)
        let fitting = min(fullHeight, Theme.MessageEditor.bodyMaximumHeight)
        if fullHeight > fitting, scrollerStyle == .legacy {
            text.frame.size.width = fullWidth - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        if height.constant != fitting { height.constant = fitting }
    }

    private func measuredHeight(width: CGFloat) -> CGFloat {
        text.frame.size.width = width
        guard let manager = text.layoutManager, let container = text.textContainer else { return 0 }
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    var string: String { text.string }
}
