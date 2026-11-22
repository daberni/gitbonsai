import AppKit

/// The scrolling list of the empty tab: group captions, repository rows with branch and open mark, and the hints of empty groups.
/// It draws everything itself; the search field above it moves the selection.
final class WelcomeListView: NSView {
    /// A new list keeps the selected repository when it is still listed, so a background refresh does not move the selection.
    var list = WelcomeList(recents: [], folders: [], openPaths: [], filter: "", recentLimit: 0) {
        didSet {
            layoutItems()
            let selectedPath = selection.flatMap { oldValue.entries.indices.contains($0) ? oldValue.entries[$0].path : nil }
            let entries = list.entries
            selection = entries.firstIndex { $0.path == selectedPath } ?? (entries.isEmpty ? nil : 0)
        }
    }
    /// No repository folder is configured, so the list offers the settings instead of folder groups.
    var showsFolderHint = false {
        didSet {
            settingsLink.isHidden = !showsFolderHint
            layoutItems()
        }
    }
    var onOpen: ((_ path: String, _ background: Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    private(set) var selection: Int? { didSet { if selection != oldValue { needsDisplay = true } } }
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private let settingsLink = NSButton(title: "", target: nil, action: nil)

    private typealias M = Theme.Welcome

    private enum Item {
        case caption(String)
        case entry(Int)
        case message(String)
    }

    private var items: [(item: Item, frame: CGRect)] = []
    private var settingsLinkFrame = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        settingsLink.isBordered = false
        settingsLink.attributedTitle = NSAttributedString(string: String(localized: "welcome.list.chooseFolders", defaultValue: "Choose repository folders in Settings…", bundle: .module), attributes: [.font: Theme.body, .foregroundColor: Theme.moss])
        settingsLink.target = self
        settingsLink.action = #selector(openSettings(_:))
        settingsLink.isHidden = true
        addSubview(settingsLink)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: Layout

    private func layoutItems() {
        items = []
        var y: CGFloat = 0
        var entryIndex = 0
        func add(_ item: Item, height: CGFloat) {
            items.append((item, CGRect(x: 0, y: y, width: bounds.width, height: height)))
            y += height
        }
        for section in list.sections {
            add(.caption(section.title.uppercased(with: AppLanguage.locale)), height: M.captionHeight)
            if section.entries.isEmpty {
                add(.message(emptyText(section)), height: M.messageHeight)
            }
            for _ in section.entries {
                add(.entry(entryIndex), height: M.rowHeight)
                entryIndex += 1
            }
            if section.isRecents, showsFolderHint {
                y += M.sectionGap
                add(.message(String(localized: "welcome.list.suggestFolders", defaultValue: "Also suggest repositories from your own folders:", bundle: .module)), height: M.messageHeight)
                settingsLinkFrame = CGRect(x: M.textInset, y: y, width: bounds.width - M.textInset, height: M.messageHeight)
                y += M.messageHeight
            }
            y += M.sectionGap
        }
        settingsLink.sizeToFit()
        settingsLink.setFrameOrigin(CGPoint(x: settingsLinkFrame.minX, y: settingsLinkFrame.minY))
        let height = max(y, superview?.bounds.height ?? 0)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
        needsDisplay = true
    }

    private func emptyText(_ section: WelcomeList.Section) -> String {
        if list.isFiltered { return String(localized: "welcome.list.noMatches", defaultValue: "No matches.", bundle: .module) }
        return section.isRecents ? String(localized: "welcome.list.noRecents", defaultValue: "Nothing opened yet. You can also drop a folder on the window.", bundle: .module) : String(localized: "welcome.list.noRepositories", defaultValue: "No repositories found.", bundle: .module)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { layoutItems() }
    }

    private func frame(ofEntry index: Int) -> CGRect? {
        items.first { if case .entry(index) = $0.item { true } else { false } }?.frame
    }

    // MARK: Selection

    /// Moves the selection by `step` rows and keeps it in view.
    func moveSelection(by step: Int) {
        let count = list.entries.count
        guard count > 0 else { return }
        selection = min(max((selection ?? -1) + step, 0), count - 1)
        if let selection, let frame = frame(ofEntry: selection) {
            // The caption above the first entry of a group comes along, so the group's name stays readable.
            scrollToVisible(selection == 0 ? frame.union(CGRect(x: 0, y: 0, width: 1, height: 1)) : frame.insetBy(dx: 0, dy: -M.captionHeight / 2))
        }
    }

    func openSelection(background: Bool) {
        guard let selection, list.entries.indices.contains(selection) else { return }
        onOpen?(list.entries[selection].path, background)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let entries = list.entries
        for (item, frame) in items where frame.intersects(dirtyRect) {
            switch item {
            case .caption(let title):
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingMiddle
                let text = NSAttributedString(string: title, attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern, .paragraphStyle: paragraph])
                text.draw(in: CGRect(x: frame.minX + M.textInset, y: frame.maxY - M.captionBaseline, width: frame.width - 2 * M.textInset, height: ceil(text.size().height)))
            case .message(let text):
                NSAttributedString(string: text, attributes: [.font: Theme.body, .foregroundColor: Theme.inkMuted]).draw(at: CGPoint(x: frame.minX + M.textInset, y: frame.minY + M.messageTextOffset))
            case .entry(let index):
                draw(entries[index], index: index, in: frame, context: context)
            }
        }
    }

    private func draw(_ entry: WelcomeList.Entry, index: Int, in frame: CGRect, context: CGContext) {
        if selection == index {
            Theme.surfaceSelected.setFill()
            NSBezierPath(roundedRect: frame, xRadius: M.rowRadius, yRadius: M.rowRadius).fill()
        } else if hovered == index {
            Theme.ink.withAlphaComponent(Theme.Wash.hover).setFill()
            NSBezierPath(roundedRect: frame, xRadius: M.rowRadius, yRadius: M.rowRadius).fill()
        }
        var textX = frame.minX + M.textInset
        if entry.isWorktree {
            textX += M.worktreeIndent
            Glyph.bonsaiLinked.draw(in: CGRect(x: textX - M.worktreeGlyph - Theme.Space.xs, y: frame.minY + M.nameLine.top, width: M.worktreeGlyph, height: M.worktreeGlyph), color: Theme.inkMuted, context: context)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let trailing = NSMutableParagraphStyle()
        trailing.alignment = .right
        trailing.lineBreakMode = .byTruncatingTail
        let rightEdge = frame.maxX - M.textInset
        let sideWidth = M.sideColumn
        let textWidth = rightEdge - sideWidth - Theme.Space.s - textX
        NSAttributedString(string: entry.name, attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.ink, .paragraphStyle: paragraph]).draw(in: CGRect(x: textX, y: frame.minY + M.nameLine.top, width: textWidth, height: M.nameLine.height))
        NSAttributedString(string: entry.detail, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted, .paragraphStyle: paragraph]).draw(in: CGRect(x: textX, y: frame.minY + M.folderLine.top, width: textWidth, height: M.folderLine.height))
        if let branch = entry.branch {
            let text = NSAttributedString(string: branch, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted, .paragraphStyle: trailing])
            let width = min(ceil(text.size().width), sideWidth - Theme.Icon.small - Theme.Space.xs)
            text.draw(in: CGRect(x: rightEdge - width, y: frame.minY + M.nameLine.top + M.branchShift, width: width, height: M.folderLine.height))
            Glyph.branch.draw(in: CGRect(x: rightEdge - width - Theme.Space.xs - Theme.Icon.small, y: frame.minY + M.nameLine.top + M.branchShift, width: Theme.Icon.small, height: Theme.Icon.small), color: Theme.inkFaint, context: context)
        }
        if entry.isOpen {
            NSAttributedString(string: String(localized: "welcome.list.opened", defaultValue: "Opened", bundle: .module, comment: "Badge on a welcome page entry whose repository is open in a tab."), attributes: [.font: Theme.pillStrong, .foregroundColor: Theme.moss, .paragraphStyle: trailing]).draw(in: CGRect(x: rightEdge - sideWidth, y: frame.minY + M.folderLine.top, width: sideWidth, height: M.folderLine.height))
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func entry(at point: CGPoint) -> Int? {
        for (item, frame) in items where frame.contains(point) {
            if case .entry(let index) = item { return index }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = entry(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = entry(at: convert(event.locationInWindow, from: nil)) else { return }
        selection = index
    }

    /// A click opens the repository; ⌘-click opens it in the background, like ⌘⏎.
    override func mouseUp(with event: NSEvent) {
        guard let index = entry(at: convert(event.locationInWindow, from: nil)), index == selection else { return }
        onOpen?(list.entries[index].path, event.modifierFlags.contains(.command))
    }

    @objc private func openSettings(_ sender: Any?) {
        onOpenSettings?()
    }
}
