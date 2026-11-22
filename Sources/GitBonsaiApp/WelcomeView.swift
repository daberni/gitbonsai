import AppKit

/// What a tab shows before it has a repository: the recently used repositories and the way to open another folder.
final class WelcomeView: NSView {
    var recents: [String] = [] { didSet { needsDisplay = true } }
    var onOpenPath: ((String) -> Void)?
    var onChooseFolder: (() -> Void)?

    private typealias M = Theme.Welcome
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

    private var visibleRecents: [String] { Array(recents.prefix(M.maximumRows)) }
    private var columnX: CGFloat { max((bounds.width - M.columnWidth) / 2, Theme.Space.xl) }
    private var columnWidth: CGFloat { min(M.columnWidth, bounds.width - 2 * Theme.Space.xl) }
    private var listTop: CGFloat { max(bounds.height * M.topShare, M.minimumTop) + Theme.Window.toolbar + M.introHeight }

    private func rowFrame(_ index: Int) -> CGRect {
        CGRect(x: columnX, y: listTop + CGFloat(index) * M.rowHeight, width: columnWidth, height: M.rowHeight)
    }

    override func layout() {
        super.layout()
        let rows = max(visibleRecents.count, 1)
        openButton.sizeToFit()
        openButton.setFrameOrigin(CGPoint(x: columnX + M.textInset, y: listTop + CGFloat(rows) * M.rowHeight + M.buttonGap))
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
        CGRect(x: 0, y: 0, width: bounds.width, height: Theme.Window.toolbar).fill()
        Theme.hairline.setFill()
        CGRect(x: 0, y: Theme.Window.toolbar - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
        let top = listTop - M.introHeight
        Glyph.bonsaiMain.draw(in: CGRect(x: columnX + M.textInset, y: top, width: M.mark, height: M.mark), color: Theme.moss, context: context)
        NSAttributedString(string: "Repository öffnen", attributes: [.font: Theme.heading, .foregroundColor: Theme.ink]).draw(at: CGPoint(x: columnX + M.textInset, y: top + M.titleOffset))
        NSAttributedString(string: "ZULETZT VERWENDET", attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern]).draw(at: CGPoint(x: columnX + M.textInset, y: listTop - Theme.Space.xl))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        if visibleRecents.isEmpty {
            NSAttributedString(string: "Noch nichts geöffnet. Ein Ordner lässt sich auch auf das Fenster ziehen.", attributes: [.font: Theme.body, .foregroundColor: Theme.inkMuted]).draw(at: CGPoint(x: columnX + M.textInset, y: listTop + M.emptyTextOffset))
        }
        for (index, path) in visibleRecents.enumerated() {
            let frame = rowFrame(index)
            if hoveredRow == index {
                Theme.surfaceSelected.setFill()
                NSBezierPath(roundedRect: frame, xRadius: M.rowRadius, yRadius: M.rowRadius).fill()
            } else if index > 0, hoveredRow != index - 1 {
                Theme.hairline.setFill()
                CGRect(x: frame.minX + M.textInset, y: frame.minY, width: frame.width - 2 * M.textInset, height: Theme.Stroke.hairline).fill()
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let folder = (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            NSAttributedString(string: name, attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.ink, .paragraphStyle: paragraph]).draw(in: CGRect(x: frame.minX + M.textInset, y: frame.minY + M.nameLine.top, width: frame.width - 2 * M.textInset, height: M.nameLine.height))
            NSAttributedString(string: folder, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted, .paragraphStyle: paragraph]).draw(in: CGRect(x: frame.minX + M.textInset, y: frame.minY + M.folderLine.top, width: frame.width - 2 * M.textInset, height: M.folderLine.height))
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
