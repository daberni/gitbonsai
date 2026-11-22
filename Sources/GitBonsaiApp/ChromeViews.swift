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
final class BarView: NSView {
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

/// Column captions above the history, aligned with the columns the rows draw.
final class HistoryHeaderView: NSView {
    var graphWidth: CGFloat = 50 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface0.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: 0.66]
        func caption(_ text: String, x: CGFloat, rightAligned: Bool = false) {
            let string = NSAttributedString(string: text.uppercased(), attributes: attributes)
            string.draw(at: CGPoint(x: rightAligned ? x - string.size().width : x, y: bounds.midY - string.size().height / 2))
        }
        typealias G = Theme.Graph
        caption("Branch / Tag", x: G.labelColumn - 14, rightAligned: true)
        caption("Graph", x: G.labelColumn + 8)
        caption("Commit", x: G.labelColumn + graphWidth + 12)
        if bounds.width >= G.authorMinimumWidth { caption("Autor", x: bounds.width - G.dateColumn - G.authorColumn) }
        caption("Datum", x: bounds.width - 12, rightAligned: true)
    }
}
