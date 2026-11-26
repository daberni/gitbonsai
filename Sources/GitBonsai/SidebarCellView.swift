import AppKit
import GitEngine

/// One sidebar row's content, drawn on the sidebar's five-column grid: expander, icon, text, value, status slot.
///
/// Left of the text there is only hierarchy; everything that describes state (counters, ahead/behind, the checked-out mark, the worktree glyph) sits on the right.
final class SidebarCellView: NSView {
    typealias M = Theme.Sidebar
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private(set) var node: SidebarNode?
    /// Whether a section or folder shows its children; drives the chevron and a folder's count.
    var isExpanded = false { didSet { if isExpanded != oldValue { needsDisplay = true; updateAccessibility() } } }
    /// The plus of the Local and Worktrees headers.
    let plusButton = PlusButton()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        plusButton.isHidden = true
        addSubview(plusButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(_ node: SidebarNode, expanded: Bool) {
        self.node = node
        isExpanded = expanded
        if case .header(let key, _, _, _, let plus) = node.item, plus {
            plusButton.isHidden = false
            plusButton.toolTip = key == "worktrees"
                ? String(localized: "worktree.new.title", defaultValue: "New Worktree", bundle: .module, comment: "Title of the sheet that creates a worktree.")
                : String(localized: "command.newBranch.title", defaultValue: "New Branch…", bundle: .module)
            plusButton.setAccessibilityLabel(plusButton.toolTip)
        } else {
            plusButton.isHidden = true
        }
        updateAccessibility()
        needsLayout = true
        needsDisplay = true
    }

    /// Width the rows are laid out in, which keeps the right edge still whether or not a scroller shows.
    private var contentWidth: CGFloat {
        (enclosingScrollView?.documentView as? SidebarOutlineView)?.contentWidth ?? bounds.width
    }

    private var slotRight: CGFloat { min(bounds.width, contentWidth) - 2 * M.rowInset - Theme.Space.xs + M.rowInset }
    private var valueRight: CGFloat { slotRight - M.slot - M.textGap }

    /// The part of the row the content is laid out in; a header keeps a little room above it.
    private var contentRect: CGRect {
        var rect = CGRect(x: M.rowInset, y: 0, width: min(bounds.width, contentWidth) - 2 * M.rowInset, height: bounds.height)
        if case .header = node?.item { rect.origin.y += Theme.Space.xs; rect.size.height -= Theme.Space.xs }
        return rect
    }

    private var slotRect: CGRect {
        let rect = contentRect
        return CGRect(x: slotRight - M.slot, y: rect.midY - M.slot / 2, width: M.slot, height: M.slot)
    }

    override func layout() {
        super.layout()
        plusButton.frame = slotRect.insetBy(dx: -Theme.Space.xs, dy: -Theme.Space.xs)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let node, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = contentRect
        let columnA = CGRect(x: rect.minX + M.rowInset, y: rect.midY - M.column / 2, width: M.column, height: M.column)
        let columnB = columnA.offsetBy(dx: M.columnStep, dy: 0)
        let slot = slotRect
        let textX = columnB.maxX + M.textGap
        let valueRight = valueRight

        func drawValue(_ string: String, atY midY: CGFloat) -> CGFloat {
            guard !string.isEmpty else { return valueRight }
            let value = NSAttributedString(string: string, attributes: [.font: Theme.captionDigits, .foregroundColor: Theme.inkMuted])
            let x = valueRight - value.size().width
            value.draw(at: CGPoint(x: x, y: midY - value.size().height / 2))
            return x - Theme.Space.s
        }
        func drawText(_ string: String, font: NSFont, color: NSColor, x: CGFloat, midY: CGFloat, maxX: CGFloat) {
            let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let height = text.size().height
            text.draw(with: CGRect(x: x, y: midY - height / 2, width: max(maxX - x, M.minimumText), height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        switch node.item {
        case .header(_, let title, let count, let icon, let plus):
            (isExpanded ? Glyph.chevronDown : .chevronRight).draw(in: columnA.insetBy(dx: M.chevronInset, dy: M.chevronInset), color: Theme.inkMuted, context: context)
            icon.draw(in: columnB.insetBy(dx: M.iconInset, dy: M.iconInset), color: Theme.inkMuted, context: context)
            let limit = drawValue("\(count)", atY: rect.midY)
            let label = NSAttributedString(string: title.uppercased(with: AppLanguage.locale), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
            label.draw(with: CGRect(x: textX, y: rect.midY - label.size().height / 2, width: limit - textX, height: label.size().height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if plus {
                let circle = NSBezierPath(ovalIn: slot.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2))
                Theme.surface2.setFill(); circle.fill()
                Theme.hairline.setStroke(); circle.stroke()
                Glyph.plus.draw(in: slot.insetBy(dx: M.plusInset, dy: M.plusInset), color: Theme.inkMuted, context: context)
            }

        case .worktree(let info, let isCurrent):
            let worktree = info.worktree
            let faint = worktree.isPrunable
            let line1 = rect.minY + M.worktreeLines.first, line2 = rect.minY + M.worktreeLines.second
            Self.glyph(of: worktree).draw(in: CGRect(x: columnB.minX - M.worktreeGlyphShift, y: line1 - M.slot / 2, width: M.slot, height: M.slot), color: faint ? Theme.inkFaint : Theme.ink, context: context)
            let dirtyCount = info.status?.entries.count ?? 0
            var limit = valueRight
            if dirtyCount > 0 {
                limit = drawValue("\(dirtyCount)", atY: line1)
                context.setFillColor(Theme.clay.cgColor)
                context.fillEllipse(in: CGRect(x: limit + Theme.Space.s - Theme.Space.xs - M.dirtyDot, y: line1 - M.dirtyDot / 2, width: M.dirtyDot, height: M.dirtyDot))
                limit -= M.dirtyDot + Theme.Space.xs
            }
            if worktree.isLocked {
                let text = NSAttributedString(string: Self.lockedText, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
                text.draw(at: CGPoint(x: limit - text.size().width, y: line1 - text.size().height / 2))
                limit -= text.size().width + Theme.Space.s
            }
            drawText(Self.name(of: worktree), font: isCurrent ? Theme.bodyStrong : Theme.bodyMedium, color: faint ? Theme.inkFaint : Theme.ink, x: textX, midY: line1, maxX: limit)
            drawText(Self.detail(of: info), font: Theme.caption, color: faint ? Theme.inkFaint : Theme.inkMuted, x: textX, midY: line2, maxX: valueRight)

        case .row(let row):
            let shift = CGAffineTransform(translationX: row.indent, y: 0)
            row.expander?.draw(in: columnA.insetBy(dx: M.expanderInset, dy: M.expanderInset), color: row.ghost ? Theme.inkFaint : Theme.inkMuted, context: context)
            let icon = node.isExpandable ? (isExpanded ? Glyph.chevronDown : .chevronRight) : row.icon
            if let icon {
                let inset = icon == .chevronDown || icon == .chevronRight ? M.chevronInset : M.iconInset
                icon.draw(in: columnB.insetBy(dx: inset, dy: inset).applying(shift), color: Theme.inkMuted, context: context)
            }
            if let slotGlyph = row.slot {
                let inset = slotGlyph == .chevronRight ? M.slotChevronInset : M.slotInset
                slotGlyph.draw(in: slot.insetBy(dx: inset, dy: inset), color: row.slotColor ?? Theme.inkMuted, context: context)
            }
            // A folder counts its branches only while they are hidden.
            let value = node.isExpandable && isExpanded ? "" : row.value
            let limit = row.ahead > 0 || row.behind > 0 ? drawSyncBadges(behind: row.behind, ahead: row.ahead, right: valueRight, midY: rect.midY) : drawValue(value, atY: rect.midY)
            // The add-remote row is the one exception to the grid: its text starts right after the plus.
            let x = row.ghost ? columnB.minX : textX + row.indent
            drawText(row.text, font: row.strong ? Theme.bodyStrong : Theme.body, color: row.ghost ? Theme.inkFaint : Theme.ink, x: x, midY: rect.midY, maxX: limit)
        }
    }

    /// Behind and ahead as capsules like the toolbar's Pull and Push badges, right-aligned at `right`; a count of 0 gets none. Returns where the text has to end.
    private func drawSyncBadges(behind: Int, ahead: Int, right: CGFloat, midY: CGFloat) -> CGFloat {
        typealias B = Theme.Badge
        var x = right
        for (arrow, count) in [("↑", ahead), ("↓", behind)] where count > 0 {
            let number = count > B.maximumCount ? "\(B.maximumCount)+" : "\(count)"
            let text = NSAttributedString(string: arrow + number, attributes: [.font: B.font, .foregroundColor: B.onAccent])
            let size = text.size()
            let width = max(size.width + 2 * B.padding, B.height)
            let capsule = CGRect(x: x - width, y: midY - B.height / 2, width: width, height: B.height)
            Theme.sky.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: B.height / 2, yRadius: B.height / 2).fill()
            text.draw(at: CGPoint(x: capsule.midX - size.width / 2, y: midY - size.height / 2))
            x = capsule.minX - Theme.Space.xs
        }
        return x - Theme.Space.xs
    }

    // MARK: Text

    private static func glyph(of worktree: Worktree) -> Glyph {
        worktree.isPrunable ? .bonsaiPrunable : worktree.isLocked ? .bonsaiLocked : worktree.isDetached ? .bonsaiDetached : worktree.isMain ? .bonsaiMain : .bonsaiLinked
    }

    private static var lockedText: String {
        String(localized: "sidebar.worktree.locked", defaultValue: "locked", bundle: .module, comment: "Marks a locked worktree in the sidebar.")
    }

    private static func name(of worktree: Worktree) -> String {
        (worktree.path as NSString).lastPathComponent
    }

    /// The second line of a worktree: its branch or detached commit, and how it stands against its upstream.
    private static func detail(of info: WorktreeInfo) -> String {
        let worktree = info.worktree
        var detail: String
        if worktree.isPrunable {
            detail = String(localized: "sidebar.worktree.prunable", defaultValue: "folder missing · prunable", bundle: .module, comment: "A worktree whose folder is gone; prunable is git's term.")
        } else if let branch = worktree.branchName {
            detail = branch
        } else {
            let sha = String((worktree.headSHA ?? "").prefix(RefString.shortSHA))
            detail = String(localized: "sidebar.worktree.detached", defaultValue: "detached @ \(sha)", bundle: .module, comment: "A worktree on a detached HEAD at a short SHA.")
        }
        if let branch = info.status?.branch, branch.upstream != nil {
            let sync = [branch.ahead > 0 ? "↑\(branch.ahead)" : nil, branch.behind > 0 ? "↓\(branch.behind)" : nil].compactMap { $0 }.joined(separator: " ")
            detail += " · " + (sync.isEmpty ? String(localized: "sidebar.branch.synced", defaultValue: "synced", bundle: .module, comment: "A worktree's branch is even with its upstream.") : sync)
        }
        return detail
    }

    // MARK: Accessibility

    /// What VoiceOver reads for the row: its name first, then the state the right-hand columns show.
    static func accessibilityLabel(of node: SidebarNode, expanded: Bool) -> String {
        var parts: [String] = []
        switch node.item {
        case .header(_, let title, let count, _, _):
            parts = [title, "\(count)"]
        case .worktree(let info, let isCurrent):
            parts = [name(of: info.worktree), detail(of: info)]
            if isCurrent { parts.append(String(localized: "sidebar.accessibility.current", defaultValue: "current", bundle: .module, comment: "VoiceOver: the worktree this window shows.")) }
            if info.worktree.isLocked { parts.append(lockedText) }
            let changes = info.status?.entries.count ?? 0
            if changes > 0 { parts.append(String(localized: "sidebar.accessibility.changes", defaultValue: "\(changes) changes", bundle: .module, comment: "VoiceOver: uncommitted changes of a worktree.")) }
        case .row(let row):
            parts = [row.text]
            if row.isCheckedOut { parts.append(String(localized: "sidebar.accessibility.checkedOut", defaultValue: "checked out", bundle: .module, comment: "VoiceOver: the branch HEAD is on.")) }
            if row.linkedWorktree != nil { parts.append(String(localized: "sidebar.accessibility.linkedWorktree", defaultValue: "checked out in another worktree", bundle: .module, comment: "VoiceOver: a branch another worktree has checked out.")) }
            if row.ahead > 0 { parts.append(String(localized: "sidebar.accessibility.ahead", defaultValue: "\(row.ahead) ahead", bundle: .module, comment: "VoiceOver: commits the branch has that its upstream lacks.")) }
            if row.behind > 0 { parts.append(String(localized: "sidebar.accessibility.behind", defaultValue: "\(row.behind) behind", bundle: .module, comment: "VoiceOver: commits the upstream has that the branch lacks.")) }
            if !row.value.isEmpty, !(node.isExpandable && expanded) { parts.append(row.value) }
        }
        return parts.joined(separator: ", ")
    }

    private func updateAccessibility() {
        guard let node else { return }
        setAccessibilityLabel(Self.accessibilityLabel(of: node, expanded: isExpanded))
    }
}

/// The round plus of a section header; drawn by the cell, so the button itself only takes the click and gives VoiceOver a button.
final class PlusButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
