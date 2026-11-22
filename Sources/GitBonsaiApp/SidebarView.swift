import AppKit
import GitEngine

/// The repository sidebar, drawn on one five-column grid: expander, icon, text, value, status slot.
///
/// Left of the text there is only hierarchy; everything that describes state (counters, ahead/behind, the checked-out mark, the worktree glyph) sits on the right.
final class SidebarView: NSView {
    enum Item {
        case header(key: String, title: String, count: Int, icon: Glyph, plus: Bool)
        case worktree(WorktreeInfo, isCurrent: Bool)
        case row(text: String, value: String, expander: Glyph?, icon: Glyph?, slot: Glyph?, slotColor: NSColor?, indent: CGFloat, strong: Bool, isCheckedOut: Bool, ghost: Bool, target: String?, linkedWorktree: String?, checkout: CheckoutTarget?)
    }

    var onSelectCommit: ((String) -> Void)?
    /// Double click on a branch. `worktreePath` is set when the branch is checked out in another worktree.
    var onCheckout: ((CheckoutTarget, _ worktreePath: String?) -> Void)?
    /// Double click on a worktree other than the one shown.
    var onSwitchWorktree: ((String) -> Void)?

    private var items: [Item] = []
    private var frames: [CGRect] = []
    private var collapsed: Set<String> = []
    private var knownSections: Set<String> = []
    private var hovered: Int?
    private weak var model: GraphViewModel?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    func reload(from model: GraphViewModel) {
        self.model = model
        var result: [Item] = []
        let otherWorktrees = model.branchesInOtherWorktrees

        func section(_ key: String, title: String, count: Int, icon: Glyph, plus: Bool = false, startCollapsed: Bool = false) -> Bool {
            if knownSections.insert(key).inserted, startCollapsed { collapsed.insert(key) }
            result.append(.header(key: key, title: title, count: count, icon: icon, plus: plus))
            return !collapsed.contains(key)
        }
        /// Branches grouped by their first path segment, folders first, like Fork and Tower.
        func branches(_ refs: [Ref], display: (Ref) -> String, section key: String) {
            var folders: [String: [(String, Ref)]] = [:]
            var leaves: [(String, Ref)] = []
            for ref in refs {
                let name = display(ref)
                if let slash = name.firstIndex(of: "/") {
                    folders[String(name[..<slash]) + "/", default: []].append((String(name[name.index(after: slash)...]), ref))
                } else {
                    leaves.append((name, ref))
                }
            }
            func leaf(_ name: String, _ ref: Ref, indent: CGFloat) {
                let value = [ref.ahead.flatMap { $0 > 0 ? "↑\($0)" : nil }, ref.behind.flatMap { $0 > 0 ? "↓\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
                let linked = otherWorktrees[ref.fullName]
                let slot: Glyph? = ref.isHead ? .check : linked != nil ? .bonsaiLinked : nil
                let checkout: CheckoutTarget? = switch ref.kind {
                case .localBranch: .localBranch(ref.name)
                case .remoteBranch(let remote): .remoteBranch(remote: remote, branch: String(ref.name.dropFirst(remote.count + 1)))
                default: nil
                }
                result.append(.row(text: name, value: value, expander: nil, icon: nil, slot: slot, slotColor: ref.isHead ? Theme.moss : nil, indent: indent, strong: ref.isHead, isCheckedOut: ref.isHead, ghost: false, target: ref.target, linkedWorktree: linked?.path, checkout: ref.isHead ? nil : checkout))
            }
            for folder in folders.keys.sorted() {
                let folderKey = key + "/" + folder
                let open = !collapsed.contains(folderKey)
                result.append(.row(text: folder, value: open ? "" : "\(folders[folder]!.count)", expander: nil, icon: open ? .chevronDown : .chevronRight, slot: nil, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: "folder:" + folderKey, linkedWorktree: nil, checkout: nil))
                if open { for (name, ref) in folders[folder]!.sorted(by: { $0.0 < $1.0 }) { leaf(name, ref, indent: 16) } }
            }
            for (name, ref) in leaves.sorted(by: { $0.0 < $1.0 }) { leaf(name, ref, indent: 0) }
        }

        if section("worktrees", title: "Worktrees", count: model.worktrees.count, icon: .bonsaiMain, plus: true) {
            for info in model.worktrees {
                result.append(.worktree(info, isCurrent: model.isCurrent(info.worktree)))
            }
        }
        let tags = model.refs.filter { $0.kind == .tag }
        result.append(.row(text: "Tags", value: "\(tags.count)", expander: nil, icon: .tag, slot: .chevronRight, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: nil, linkedWorktree: nil, checkout: nil))

        let locals = model.refs.filter { $0.kind == .localBranch }
        if section("local", title: "Local", count: locals.count, icon: .laptop, plus: true) {
            // The uncommitted changes of this worktree; a click selects their row in the history, or HEAD when there are none.
            let changes = model.status?.entries.count ?? 0
            result.append(.row(text: "Working Directory", value: "\(changes)", expander: nil, icon: .pencil, slot: nil, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: changes > 0 ? GraphViewModel.wipID : model.headSHA, linkedWorktree: nil, checkout: nil))
            result.append(.row(text: "Stashes", value: "\(model.stashes.count)", expander: nil, icon: .stashBowl, slot: .chevronRight, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: false, target: nil, linkedWorktree: nil, checkout: nil))
            branches(locals, display: { $0.name }, section: "local")
        }

        var remotes: [String: [Ref]] = [:]
        for ref in model.refs {
            if case .remoteBranch(let remote) = ref.kind, !ref.name.hasSuffix("/HEAD") { remotes[remote, default: []].append(ref) }
        }
        for (index, remote) in remotes.keys.sorted(by: { $0 == "origin" ? true : $1 == "origin" ? false : $0 < $1 }).enumerated() {
            let refs = remotes[remote]!
            if section("remote:" + remote, title: remote, count: refs.count, icon: .cloud, startCollapsed: index > 0 || refs.count > 40) {
                branches(refs, display: { String($0.name.dropFirst(remote.count + 1)) }, section: "remote:" + remote)
            }
        }
        result.append(.row(text: "Remote hinzufügen …", value: "", expander: .plus, icon: nil, slot: nil, slotColor: nil, indent: 0, strong: false, isCheckedOut: false, ghost: true, target: nil, linkedWorktree: nil, checkout: nil))

        items = result
        layoutItems()
    }

    private func layoutItems() {
        var y: CGFloat = 8
        frames = items.map { item in
            let height: CGFloat
            switch item {
            case .header: y += 4; height = 30
            case .worktree: height = 44
            case .row: height = 26
            }
            defer { y += height }
            return CGRect(x: 6, y: y, width: bounds.width - 12, height: height)
        }
        let total = max(y + 8, enclosingScrollView?.contentSize.height ?? 0)
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

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), let model else { return }
        switch items[index] {
        case .header(let key, _, _, _, _):
            if collapsed.remove(key) == nil { collapsed.insert(key) }
            reload(from: model)
        case .worktree(let info, let isCurrent):
            // Same as a branch row: one click shows where it stands in the history, a double click goes there.
            if event.clickCount == 2, !isCurrent, !info.worktree.isPrunable, !info.worktree.isBare {
                onSwitchWorktree?(info.worktree.path)
            } else if let head = info.worktree.headSHA {
                onSelectCommit?(head)
            }
        case .row(_, _, _, _, _, _, _, _, _, _, let target?, let linked, let checkout):
            if event.clickCount == 2, let checkout {
                onCheckout?(checkout, linked)
            } else if target.hasPrefix("folder:") {
                let key = String(target.dropFirst(7))
                if collapsed.remove(key) == nil { collapsed.insert(key) }
                reload(from: model)
            } else {
                onSelectCommit?(target)
            }
        default:
            break
        }
    }

    /// The worktree path linked to the hovered row: a branch checked out elsewhere, or the worktree row itself.
    private var hoveredWorktreePath: String? {
        guard let hovered, hovered < items.count else { return nil }
        switch items[hovered] {
        case .row(_, _, _, _, _, _, _, _, _, _, _, let linked, _): return linked
        case .worktree(let info, let isCurrent): return isCurrent ? nil : info.worktree.path
        default: return nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let linkedPath = hoveredWorktreePath
        for (index, item) in items.enumerated() where frames[index].intersects(dirtyRect) {
            let rect = frames[index]
            let columnA = CGRect(x: rect.minX + 6, y: rect.midY - 8, width: 16, height: 16)
            let columnB = columnA.offsetBy(dx: 22, dy: 0)
            let slot = CGRect(x: rect.maxX - 4 - 18, y: rect.midY - 9, width: 18, height: 18)
            let valueRight = slot.minX - 6
            let textX = columnB.maxX + 6

            func fillRow(_ color: NSColor) {
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            func drawValue(_ string: String, atY midY: CGFloat, color: NSColor = Theme.inkMuted) -> CGFloat {
                guard !string.isEmpty else { return valueRight }
                let value = NSAttributedString(string: string, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color])
                let x = valueRight - value.size().width
                value.draw(at: CGPoint(x: x, y: midY - value.size().height / 2))
                return x - 8
            }
            func drawText(_ string: String, font: NSFont, color: NSColor, x: CGFloat, midY: CGFloat, maxX: CGFloat) {
                let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
                let height = text.size().height
                text.draw(with: CGRect(x: x, y: midY - height / 2, width: max(maxX - x, 10), height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }

            switch item {
            case .header(let key, let title, let count, let icon, let plus):
                (collapsed.contains(key) ? Glyph.chevronRight : .chevronDown).draw(in: columnA.insetBy(dx: 2.5, dy: 2.5), color: Theme.inkMuted, context: context)
                icon.draw(in: columnB.insetBy(dx: 1, dy: 1), color: Theme.inkMuted, context: context)
                let limit = drawValue("\(count)", atY: rect.midY)
                let label = NSAttributedString(string: title.uppercased(), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: 0.66])
                label.draw(with: CGRect(x: textX, y: rect.midY - label.size().height / 2, width: limit - textX, height: label.size().height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                if plus {
                    let circle = NSBezierPath(ovalIn: slot.insetBy(dx: 0.5, dy: 0.5))
                    Theme.surface2.setFill(); circle.fill()
                    Theme.hairline.setStroke(); circle.stroke()
                    Glyph.plus.draw(in: slot.insetBy(dx: 4.5, dy: 4.5), color: Theme.inkMuted, context: context)
                }

            case .worktree(let info, let isCurrent):
                let worktree = info.worktree
                if isCurrent {
                    fillRow(Theme.surfaceSelected)
                } else if linkedPath == worktree.path {
                    fillRow(Theme.claySoft)
                    Theme.clay.setStroke()
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
                    outline.lineWidth = 1.5
                    outline.stroke()
                } else if hovered == index {
                    fillRow(Theme.surface2)
                }
                let faint = worktree.isPrunable
                let glyph: Glyph = worktree.isPrunable ? .bonsaiPrunable : worktree.isLocked ? .bonsaiLocked : worktree.isDetached ? .bonsaiDetached : worktree.isMain ? .bonsaiMain : .bonsaiLinked
                let line1 = rect.minY + 14, line2 = rect.minY + 31
                glyph.draw(in: CGRect(x: columnB.minX - 1, y: line1 - 9, width: 18, height: 18), color: faint ? Theme.inkFaint : Theme.ink, context: context)
                var value = ""
                if worktree.isLocked { value = "gesperrt" }
                let dirtyCount = info.status?.entries.count ?? 0
                var limit = valueRight
                if dirtyCount > 0 {
                    limit = drawValue("\(dirtyCount)", atY: line1)
                    context.setFillColor(Theme.clay.cgColor)
                    context.fillEllipse(in: CGRect(x: limit + 8 - 4 - 7, y: line1 - 3.5, width: 7, height: 7))
                    limit -= 11
                }
                if !value.isEmpty {
                    let text = NSAttributedString(string: value, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
                    text.draw(at: CGPoint(x: limit - text.size().width, y: line1 - text.size().height / 2))
                    limit -= text.size().width + 8
                }
                let name = (worktree.path as NSString).lastPathComponent
                drawText(name, font: NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .medium), color: faint ? Theme.inkFaint : Theme.ink, x: textX, midY: line1, maxX: limit)
                var detail: String
                if worktree.isPrunable { detail = "Ordner fehlt · prunable" }
                else if let branch = worktree.branchName { detail = branch }
                else { detail = "detached @ " + String((worktree.headSHA ?? "").prefix(7)) }
                if let branch = info.status?.branch, branch.upstream != nil {
                    let sync = [branch.ahead > 0 ? "↑\(branch.ahead)" : nil, branch.behind > 0 ? "↓\(branch.behind)" : nil].compactMap { $0 }.joined(separator: " ")
                    detail += " · " + (sync.isEmpty ? "synced" : sync)
                }
                drawText(detail, font: Theme.caption, color: faint ? Theme.inkFaint : Theme.inkMuted, x: textX, midY: line2, maxX: valueRight)

            case .row(let text, let value, let expander, let icon, let slotGlyph, let slotColor, let indent, let strong, let isCheckedOut, let ghost, let target, _, _):
                if isCheckedOut {
                    fillRow(Theme.surfaceSelected)
                } else if hovered == index, target != nil || slotGlyph == .chevronRight {
                    fillRow(Theme.surface2)
                }
                let shift = CGAffineTransform(translationX: indent, y: 0)
                expander?.draw(in: columnA.insetBy(dx: 2, dy: 2), color: ghost ? Theme.inkFaint : Theme.inkMuted, context: context)
                if let icon {
                    let inset: CGFloat = icon == .chevronDown || icon == .chevronRight ? 2.5 : 1
                    icon.draw(in: columnB.insetBy(dx: inset, dy: inset).applying(shift), color: Theme.inkMuted, context: context)
                }
                if let slotGlyph {
                    let inset: CGFloat = slotGlyph == .chevronRight ? 4 : 2
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
