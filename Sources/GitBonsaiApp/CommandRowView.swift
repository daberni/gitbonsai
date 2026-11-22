import AppKit

/// One line of the command bar: glyph, title with the matched characters highlighted, the muted context, and the shortcut on the right.
/// A disabled command keeps its place, drawn faint, with the reason instead of the context.
final class CommandRowView: NSView {
    private typealias C = Theme.CommandBar

    struct Content {
        let command: Command
        let titleRanges: [NSRange]
    }

    var content: Content? { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
        let command = content.command
        let enabled = command.isEnabled
        let ink = enabled ? Theme.ink : Theme.inkFaint
        let muted = enabled ? Theme.inkMuted : Theme.inkFaint
        let left = C.rowPadding
        var right = bounds.width - C.rowPadding
        let midY = bounds.midY
        Self.drawGlyph(command.glyph, in: CGRect(x: left, y: midY - C.glyph / 2, width: C.glyph, height: C.glyph), color: muted, context: context)
        if let shortcut = command.shortcut {
            right -= RefPickerRowView.drawRight(MainMenu.displayedShortcut(of: command.id) ?? shortcut.display, font: Theme.captionDigits, color: Theme.inkFaint, rightEdge: right, midY: midY) + C.detailGap
        }
        let textLeft = left + C.glyph + C.glyphGap
        let title = GraphRowView.highlighted(command.title, ranges: content.titleRanges, attributes: [.font: Theme.body, .foregroundColor: ink, .paragraphStyle: RefPickerRowView.truncating])
        let titleWidth = min(title.size().width, right - textLeft)
        guard titleWidth > 0 else { return }
        RefPickerRowView.draw(title, x: textLeft, width: titleWidth, midY: midY)
        let detailLeft = textLeft + titleWidth + C.detailGap
        guard let detail = command.disabledReason ?? command.context, right > detailLeft else { return }
        let text = NSAttributedString(string: detail, attributes: [.font: Theme.caption, .foregroundColor: muted, .paragraphStyle: RefPickerRowView.truncating])
        RefPickerRowView.draw(text, x: detailLeft, width: right - detailLeft, midY: midY)
    }

    static func drawGlyph(_ glyph: CommandGlyph, in rect: CGRect, color: NSColor, context: CGContext) {
        switch glyph {
        case .glyph(let glyph):
            glyph.draw(in: rect, color: color, context: context)
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * C.symbolScale, weight: .medium).applying(.init(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            let size = image.size
            let scale = min(rect.width / size.width, rect.height / size.height, 1)
            let target = CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .app(let url):
            NSWorkspace.shared.icon(forFile: url.path).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
