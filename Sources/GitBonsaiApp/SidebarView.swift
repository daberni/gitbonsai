import AppKit
import GitEngine

/// The repository sidebar, drawn on one five-column grid: expander, icon, text, value, status slot.
///
/// Left of the text there is only hierarchy; everything that describes state (counters, ahead/behind, the checked-out mark, the worktree glyph) sits on the right.
final class SidebarView: NSView {
    private typealias M = Theme.Sidebar

    var onSelectCommit: ((String) -> Void)?
    /// Double click on a branch. `worktreePath` is set when the branch is checked out in another worktree.
    var onCheckout: ((CheckoutTarget, _ worktreePath: String?) -> Void)?
    /// Double click on a worktree other than the one shown.
    var onSwitchWorktree: ((String) -> Void)?
    /// The Tags or Stashes row was clicked; `anchor` is the row's rectangle in this view, for a popover.
    var onOpenPanel: ((SidebarPanel, NSRect) -> Void)?
    /// The plus on the Local header.
    var onNewBranch: (() -> Void)?
    /// The entries of a row's context menu.
    var menuItems: ((SidebarMenuSubject) -> [NSMenuItem])?

    private var items: [SidebarItem] = []
    private var frames: [CGRect] = []
    private var outline = SidebarOutline()
    private var hovered: Int?
    private var contentHeight: CGFloat = 0
    private weak var model: GraphViewModel?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview else { return }
        // A taller or shorter visible area can start or stop the scrolling, and with it the room kept for the scroller.
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func visibleAreaChanged() {
        if !items.isEmpty { layoutItems() }
    }

    /// Right edge of the status slot column. The overlay scroller lies on the rows while they scroll, so the slot moves out from under it; a legacy scroller narrows the visible area itself.
    var slotRight: CGFloat {
        let regular = bounds.width - M.rowInset - Theme.Space.xs
        guard let scrollView = enclosingScrollView, scrollView.scrollerStyle == .overlay, contentHeight > scrollView.contentSize.height else { return regular }
        let scrollerWidth = NSScroller.scrollerWidth(for: scrollView.verticalScroller?.controlSize ?? .regular, scrollerStyle: .overlay)
        return min(regular, bounds.width - scrollerWidth)
    }

    func reload(from model: GraphViewModel) {
        self.model = model
        items = outline.items(from: model)
        layoutItems()
        ScreenshotHarness.traceStartup("sidebar of \((model.repository.path as NSString).lastPathComponent): \(items.count) lines, \(model.worktrees.count) worktrees, \(model.worktrees.filter { $0.status != nil }.count) with counters")
    }

    private func layoutItems() {
        var y = Theme.Space.s
        frames = items.map { item in
            let height: CGFloat
            switch item {
            case .header: y += Theme.Space.xs; height = M.headerHeight
            case .worktree: height = M.worktreeHeight
            case .row: height = M.rowHeight
            }
            defer { y += height }
            return CGRect(x: M.rowInset, y: y, width: bounds.width - 2 * M.rowInset, height: height)
        }
        contentHeight = y + Theme.Space.s
        let total = max(contentHeight, enclosingScrollView?.contentSize.height ?? 0)
        if frame.height != total { setFrameSize(NSSize(width: frame.width, height: total)) }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, !items.isEmpty { layoutItems() }
    }

    // MARK: Interaction

    private func index(at point: CGPoint) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let new = index(at: convert(event.locationInWindow, from: nil))
        if new != hovered { hovered = new; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    /// Like Finder's sidebar, a click acts even when it also brings the window forward. Harness clicks rely on it: a background window never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), let model else { return }
        switch items[index] {
        case .header(let key, _, _, _, let plus):
            if plus, key == "local", plusRect(in: frames[index]).contains(convert(event.locationInWindow, from: nil)) {
                onNewBranch?()
                return
            }
            outline.toggle(key)
            reload(from: model)
        case .worktree(let info, let isCurrent):
            // Same as a branch row: one click shows where it stands in the history, a double click goes there.
            if event.clickCount == 2, !isCurrent, !info.worktree.isPrunable, !info.worktree.isBare {
                onSwitchWorktree?(info.worktree.path)
            } else if let head = info.worktree.headSHA {
                onSelectCommit?(head)
            }
        case .row(_, _, _, _, _, _, _, _, _, _, let target?, let linked, let checkout, _):
            if event.clickCount == 2, let checkout {
                onCheckout?(checkout, linked)
            } else if let panel = SidebarPanel(target: target) {
                onOpenPanel?(panel, frames[index])
            } else if target.hasPrefix("folder:") {
                let key = String(target.dropFirst(7))
                outline.toggle(key)
                reload(from: model)
            } else {
                onSelectCommit?(target)
            }
        default:
            break
        }
    }

    /// The status slot of a header, where its plus is drawn, with a little room around it for the click.
    private func plusRect(in rect: CGRect) -> CGRect {
        CGRect(x: slotRight - M.slot, y: rect.midY - M.slot / 2, width: M.slot, height: M.slot).insetBy(dx: -Theme.Space.xs, dy: -Theme.Space.xs)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menu(forItemAt: index)
    }

    /// The row whose menu the harness asks for, by `SidebarMenuSubject.harnessName`.
    func itemIndex(named name: String) -> Int? {
        items.firstIndex { $0.menuSubject?.harnessName == name }
    }

    func itemIndex(header key: String) -> Int? {
        items.firstIndex { if case .header(key, _, _, _, _) = $0 { true } else { false } }
    }

    func rowRect(at index: Int) -> CGRect { frames[index] }

    func menu(forItemAt index: Int) -> NSMenu? {
        guard let subject = items[index].menuSubject, let entries = menuItems?(subject), !entries.isEmpty else { return nil }
        let menu = NSMenu()
        entries.forEach(menu.addItem)
        return menu
    }

    /// The worktree path linked to the hovered row: a branch checked out elsewhere, or the worktree row itself.
    private var hoveredWorktreePath: String? {
        guard let hovered, hovered < items.count else { return nil }
        switch items[hovered] {
        case .row(_, _, _, _, _, _, _, _, _, _, _, let linked, _, _): return linked
        case .worktree(let info, let isCurrent): return isCurrent ? nil : info.worktree.path
        default: return nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let linkedPath = hoveredWorktreePath
        let slotRight = slotRight
        for (index, item) in items.enumerated() where frames[index].intersects(dirtyRect) {
            let rect = frames[index]
            let columnA = CGRect(x: rect.minX + M.rowInset, y: rect.midY - M.column / 2, width: M.column, height: M.column)
            let columnB = columnA.offsetBy(dx: M.columnStep, dy: 0)
            let slot = CGRect(x: slotRight - M.slot, y: rect.midY - M.slot / 2, width: M.slot, height: M.slot)
            let valueRight = slot.minX - M.textGap
            let textX = columnB.maxX + M.textGap

            func fillRow(_ color: NSColor) {
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
            }
            func drawValue(_ string: String, atY midY: CGFloat, color: NSColor = Theme.inkMuted) -> CGFloat {
                guard !string.isEmpty else { return valueRight }
                let value = NSAttributedString(string: string, attributes: [.font: Theme.captionDigits, .foregroundColor: color])
                let x = valueRight - value.size().width
                value.draw(at: CGPoint(x: x, y: midY - value.size().height / 2))
                return x - Theme.Space.s
            }
            func drawText(_ string: String, font: NSFont, color: NSColor, x: CGFloat, midY: CGFloat, maxX: CGFloat) {
                let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
                let height = text.size().height
                text.draw(with: CGRect(x: x, y: midY - height / 2, width: max(maxX - x, M.minimumText), height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }

            switch item {
            case .header(let key, let title, let count, let icon, let plus):
                (outline.isCollapsed(key) ? Glyph.chevronRight : .chevronDown).draw(in: columnA.insetBy(dx: M.chevronInset, dy: M.chevronInset), color: Theme.inkMuted, context: context)
                icon.draw(in: columnB.insetBy(dx: M.iconInset, dy: M.iconInset), color: Theme.inkMuted, context: context)
                let limit = drawValue("\(count)", atY: rect.midY)
                let label = NSAttributedString(string: title.uppercased(), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
                label.draw(with: CGRect(x: textX, y: rect.midY - label.size().height / 2, width: limit - textX, height: label.size().height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                if plus {
                    let circle = NSBezierPath(ovalIn: slot.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2))
                    Theme.surface2.setFill(); circle.fill()
                    Theme.hairline.setStroke(); circle.stroke()
                    Glyph.plus.draw(in: slot.insetBy(dx: M.plusInset, dy: M.plusInset), color: Theme.inkMuted, context: context)
                }

            case .worktree(let info, let isCurrent):
                let worktree = info.worktree
                if isCurrent {
                    fillRow(Theme.surfaceSelected)
                } else if linkedPath == worktree.path {
                    fillRow(Theme.claySoft)
                    Theme.clay.setStroke()
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: Theme.Stroke.icon / 2, dy: Theme.Stroke.icon / 2), xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm)
                    outline.lineWidth = Theme.Stroke.icon
                    outline.stroke()
                } else if hovered == index {
                    fillRow(Theme.surface2)
                }
                let faint = worktree.isPrunable
                let glyph: Glyph = worktree.isPrunable ? .bonsaiPrunable : worktree.isLocked ? .bonsaiLocked : worktree.isDetached ? .bonsaiDetached : worktree.isMain ? .bonsaiMain : .bonsaiLinked
                let line1 = rect.minY + M.worktreeLines.first, line2 = rect.minY + M.worktreeLines.second
                glyph.draw(in: CGRect(x: columnB.minX - M.worktreeGlyphShift, y: line1 - M.slot / 2, width: M.slot, height: M.slot), color: faint ? Theme.inkFaint : Theme.ink, context: context)
                var value = ""
                if worktree.isLocked { value = "gesperrt" }
                let dirtyCount = info.status?.entries.count ?? 0
                var limit = valueRight
                if dirtyCount > 0 {
                    limit = drawValue("\(dirtyCount)", atY: line1)
                    context.setFillColor(Theme.clay.cgColor)
                    context.fillEllipse(in: CGRect(x: limit + Theme.Space.s - Theme.Space.xs - M.dirtyDot, y: line1 - M.dirtyDot / 2, width: M.dirtyDot, height: M.dirtyDot))
                    limit -= M.dirtyDot + Theme.Space.xs
                }
                if !value.isEmpty {
                    let text = NSAttributedString(string: value, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
                    text.draw(at: CGPoint(x: limit - text.size().width, y: line1 - text.size().height / 2))
                    limit -= text.size().width + Theme.Space.s
                }
                let name = (worktree.path as NSString).lastPathComponent
                drawText(name, font: isCurrent ? Theme.bodyStrong : Theme.bodyMedium, color: faint ? Theme.inkFaint : Theme.ink, x: textX, midY: line1, maxX: limit)
                var detail: String
                if worktree.isPrunable { detail = "Ordner fehlt · prunable" }
                else if let branch = worktree.branchName { detail = branch }
                else { detail = "detached @ " + String((worktree.headSHA ?? "").prefix(7)) }
                if let branch = info.status?.branch, branch.upstream != nil {
                    let sync = [branch.ahead > 0 ? "↑\(branch.ahead)" : nil, branch.behind > 0 ? "↓\(branch.behind)" : nil].compactMap { $0 }.joined(separator: " ")
                    detail += " · " + (sync.isEmpty ? "synced" : sync)
                }
                drawText(detail, font: Theme.caption, color: faint ? Theme.inkFaint : Theme.inkMuted, x: textX, midY: line2, maxX: valueRight)

            case .row(let text, let value, let expander, let icon, let slotGlyph, let slotColor, let indent, let strong, let isCheckedOut, let ghost, let target, _, _, _):
                if isCheckedOut {
                    fillRow(Theme.surfaceSelected)
                } else if hovered == index, target != nil || slotGlyph == .chevronRight {
                    fillRow(Theme.surface2)
                }
                let shift = CGAffineTransform(translationX: indent, y: 0)
                expander?.draw(in: columnA.insetBy(dx: M.expanderInset, dy: M.expanderInset), color: ghost ? Theme.inkFaint : Theme.inkMuted, context: context)
                if let icon {
                    let inset = icon == .chevronDown || icon == .chevronRight ? M.chevronInset : M.iconInset
                    icon.draw(in: columnB.insetBy(dx: inset, dy: inset).applying(shift), color: Theme.inkMuted, context: context)
                }
                if let slotGlyph {
                    let inset = slotGlyph == .chevronRight ? M.slotChevronInset : M.slotInset
                    slotGlyph.draw(in: slot.insetBy(dx: inset, dy: inset), color: slotColor ?? Theme.inkMuted, context: context)
                }
                let limit = drawValue(value, atY: rect.midY)
                // The add-remote row is the one exception to the grid: its text starts right after the plus.
                let x = ghost ? columnB.minX : textX + indent
                drawText(text, font: strong ? Theme.bodyStrong : Theme.body, color: ghost ? Theme.inkFaint : Theme.ink, x: x, midY: rect.midY, maxX: limit)
            }
        }
    }
}
