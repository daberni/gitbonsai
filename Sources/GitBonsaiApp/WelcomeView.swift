import AppKit

/// What a tab shows before it has a repository: the recently used repositories and the way to open another folder.
final class WelcomeView: NSView {
    var recents: [String] = [] { didSet { needsDisplay = true } }
    var onOpenPath: ((String) -> Void)?
    var onChooseFolder: (() -> Void)?

    private static let columnWidth: CGFloat = 520
    private static let rowHeight: CGFloat = 46
    private static let maximumRows = 8
    private static let toolbarHeight: CGFloat = 48
    private let openButton = NSButton(title: "Ordner öffnen …", target: nil, action: nil)
    private var hoveredRow: Int? { didSet { if hoveredRow != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.bezelColor = Theme.moss
        openButton.target = self
        openButton.action = #selector(chooseFolder(_:))
        addSubview(openButton)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private var visibleRecents: [String] { Array(recents.prefix(Self.maximumRows)) }
    private var columnX: CGFloat { max((bounds.width - Self.columnWidth) / 2, 24) }
    private var columnWidth: CGFloat { min(Self.columnWidth, bounds.width - 48) }
    private var listTop: CGFloat { max(bounds.height * 0.16, 40) + Self.toolbarHeight + 132 }

    private func rowFrame(_ index: Int) -> CGRect {
        CGRect(x: columnX, y: listTop + CGFloat(index) * Self.rowHeight, width: columnWidth, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        let rows = max(visibleRecents.count, 1)
        openButton.sizeToFit()
        openButton.setFrameOrigin(CGPoint(x: columnX + 10, y: listTop + CGFloat(rows) * Self.rowHeight + 20))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Theme.surface0.setFill()
        bounds.fill()
        // An empty toolbar band, so the active tab has something to run into and the layout does not jump between tabs.
        Theme.surface1.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: Self.toolbarHeight).fill()
        Theme.hairline.setFill()
        CGRect(x: 0, y: Self.toolbarHeight - 1, width: bounds.width, height: 1).fill()
        let top = listTop - 132
        Glyph.bonsaiMain.draw(in: CGRect(x: columnX + 10, y: top, width: 40, height: 40), color: Theme.moss, context: context)
        NSAttributedString(string: "Repository öffnen", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: Theme.ink]).draw(at: CGPoint(x: columnX + 10, y: top + 52))
        NSAttributedString(string: "ZULETZT VERWENDET", attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: 0.66]).draw(at: CGPoint(x: columnX + 10, y: listTop - 24))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        if visibleRecents.isEmpty {
            NSAttributedString(string: "Noch nichts geöffnet. Ein Ordner lässt sich auch auf das Fenster ziehen.", attributes: [.font: Theme.body, .foregroundColor: Theme.inkMuted]).draw(at: CGPoint(x: columnX + 10, y: listTop + 14))
        }
        for (index, path) in visibleRecents.enumerated() {
            let frame = rowFrame(index)
            if hoveredRow == index {
                Theme.surfaceSelected.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            } else if index > 0, hoveredRow != index - 1 {
                Theme.hairline.setFill()
                CGRect(x: frame.minX + 10, y: frame.minY, width: frame.width - 20, height: 1).fill()
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let folder = (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            NSAttributedString(string: name, attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.ink, .paragraphStyle: paragraph]).draw(in: CGRect(x: frame.minX + 10, y: frame.minY + 7, width: frame.width - 20, height: 17))
            NSAttributedString(string: folder, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted, .paragraphStyle: paragraph]).draw(in: CGRect(x: frame.minX + 10, y: frame.minY + 25, width: frame.width - 20, height: 14))
        }
    }

    private func row(at point: CGPoint) -> Int? {
        visibleRecents.indices.first { rowFrame($0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)) else { return }
        onOpenPath?(visibleRecents[index])
    }

    @objc private func chooseFolder(_ sender: Any?) {
        onChooseFolder?()
    }
}

/// Hosts the active tab's content and accepts a folder dropped anywhere on it.
final class TabContentView: NSView {
    var onDropFolders: (([String]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ content: NSView) {
        guard content.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    private func folders(in sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(\.hasDirectoryPath).map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folders(in: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = folders(in: sender)
        guard !paths.isEmpty else { return false }
        onDropFolders?(paths)
        return true
    }
}
