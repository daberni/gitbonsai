import AppKit
import GitEngine

/// Draws headers, worktrees and rows on the sidebar's grid.
extension SidebarView {
    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let linkedPath = hoveredWorktreePath
        let slotRight = slotRight
        let valueRight = valueRight
        for (index, item) in items.enumerated() where frames[index].intersects(dirtyRect) {
            let rect = frames[index]
            let columnA = CGRect(x: rect.minX + M.rowInset, y: rect.midY - M.column / 2, width: M.column, height: M.column)
            let columnB = columnA.offsetBy(dx: M.columnStep, dy: 0)
            let slot = CGRect(x: slotRight - M.slot, y: rect.midY - M.slot / 2, width: M.slot, height: M.slot)
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
                if worktree.isLocked { value = String(localized: "sidebar.worktree.locked", defaultValue: "locked", bundle: .module, comment: "Marks a locked worktree in the sidebar.") }
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
                if worktree.isPrunable { detail = String(localized: "sidebar.worktree.prunable", defaultValue: "folder missing · prunable", bundle: .module, comment: "A worktree whose folder is gone; prunable is git's term.") }
                else if let branch = worktree.branchName { detail = branch }
                else {
                    let sha = String((worktree.headSHA ?? "").prefix(RefString.shortSHA))
                    detail = String(localized: "sidebar.worktree.detached", defaultValue: "detached @ \(sha)", bundle: .module, comment: "A worktree on a detached HEAD at a short SHA.")
                }
                if let branch = info.status?.branch, branch.upstream != nil {
                    let sync = [branch.ahead > 0 ? "↑\(branch.ahead)" : nil, branch.behind > 0 ? "↓\(branch.behind)" : nil].compactMap { $0 }.joined(separator: " ")
                    detail += " · " + (sync.isEmpty ? String(localized: "sidebar.branch.synced", defaultValue: "synced", bundle: .module, comment: "A worktree's branch is even with its upstream.") : sync)
                }
                drawText(detail, font: Theme.caption, color: faint ? Theme.inkFaint : Theme.inkMuted, x: textX, midY: line2, maxX: valueRight)

            case .row(let row):
                if row.isCheckedOut {
                    fillRow(Theme.surfaceSelected)
                } else if hovered == index, row.target != nil || row.slot == .chevronRight {
                    fillRow(Theme.surface2)
                }
                let shift = CGAffineTransform(translationX: row.indent, y: 0)
                row.expander?.draw(in: columnA.insetBy(dx: M.expanderInset, dy: M.expanderInset), color: row.ghost ? Theme.inkFaint : Theme.inkMuted, context: context)
                if let icon = row.icon {
                    let inset = icon == .chevronDown || icon == .chevronRight ? M.chevronInset : M.iconInset
                    icon.draw(in: columnB.insetBy(dx: inset, dy: inset).applying(shift), color: Theme.inkMuted, context: context)
                }
                if let slotGlyph = row.slot {
                    let inset = slotGlyph == .chevronRight ? M.slotChevronInset : M.slotInset
                    slotGlyph.draw(in: slot.insetBy(dx: inset, dy: inset), color: row.slotColor ?? Theme.inkMuted, context: context)
                }
                let limit = row.ahead > 0 || row.behind > 0 ? drawSyncBadges(behind: row.behind, ahead: row.ahead, right: valueRight, midY: rect.midY) : drawValue(row.value, atY: rect.midY)
                // The add-remote row is the one exception to the grid: its text starts right after the plus.
                let x = row.ghost ? columnB.minX : textX + row.indent
                drawText(row.text, font: row.strong ? Theme.bodyStrong : Theme.body, color: row.ghost ? Theme.inkFaint : Theme.ink, x: x, midY: rect.midY, maxX: limit)
            }
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
}
