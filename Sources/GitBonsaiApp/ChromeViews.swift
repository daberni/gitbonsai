import AppKit

/// A view filled with one theme color; follows light and dark on its own.
final class FillView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// A flat bar in the chrome color with one hairline edge.
class BarView: NSView {
    enum Edge { case top, bottom }
    private let edge: Edge

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: edge == .bottom ? bounds.height - 1 : 0, width: bounds.width, height: 1).fill()
    }
}

/// Shows one of several views at a time, filling itself.
class ContainerView: NSView {
    private(set) var current: NSView?

    func show(_ content: NSView) {
        guard content !== current else { return }
        current?.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        current = content
    }
}

/// Content filling a column, with an optional bar pinned to its bottom edge.
final class ColumnWithBottomBar: NSView {
    var showsBar = false { didSet { update() } }
    private let bar: NSView
    private var contentToBottom: NSLayoutConstraint!
    private var contentToBar: NSLayoutConstraint!

    init(content: NSView, bar: NSView) {
        self.bar = bar
        super.init(frame: .zero)
        for view in [content, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        contentToBottom = content.bottomAnchor.constraint(equalTo: bottomAnchor)
        contentToBar = content.bottomAnchor.constraint(equalTo: bar.topAnchor)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The bar keeps its natural height; the content takes the rest.
        bar.setContentHuggingPriority(.defaultHigh, for: .vertical)
        update()
    }

    required init?(coder: NSCoder) { nil }

    private func update() {
        bar.isHidden = !showsBar
        contentToBottom.isActive = !showsBar
        contentToBar.isActive = showsBar
    }
}
