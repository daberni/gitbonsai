import AppKit
import GitEngine

/// How the ref picker draws an item: the sidebar's and labels' glyphs (check where checked out, laptop, cloud, tag), a ring for a commit.
@MainActor
enum RefItemStyle {
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = AppLanguage.locale
        return formatter
    }()

    static func drawGlyph(of item: RefCatalog.Item, in rect: CGRect, color: NSColor, context: CGContext) {
        let glyph: Glyph? = switch item.kind {
        case .head(let branch): branch == nil ? .bonsaiDetached : .check
        case .localBranch(let isHead): isHead ? .check : .laptop
        case .remoteBranch: .cloud
        case .tag: .tag
        case .commit: nil
        }
        if let glyph {
            glyph.draw(in: rect, color: color, context: context)
            return
        }
        let radius = Theme.RefPicker.commitRing
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(Theme.Stroke.icon)
        context.strokeEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
    }

    /// The muted text after the name: short SHA and age for refs, subject and age for a commit, whose name already is its SHA.
    static func detail(of item: RefCatalog.Item) -> (sha: String?, rest: String) {
        let age = relativeFormatter.localizedString(for: item.commit.date, relativeTo: Date())
        switch item.kind {
        case .commit: return (nil, age)
        case .head(nil): return (nil, "HEAD · \(age)")
        case .head: return (item.commit.shortID, "HEAD · \(age)")
        default: return (item.commit.shortID, age)
        }
    }

    /// The muted text after a commit's SHA: why it is offered, then its subject.
    static func commitText(of item: RefCatalog.Item) -> String {
        ([item.note].compactMap { $0 } + [item.commit.subject]).joined(separator: " · ")
    }

    static func sectionTitle(_ section: RefCatalog.Section) -> String {
        switch section {
        case .current: String(localized: "Current", bundle: .module, comment: "Ref picker section with HEAD and the commit the picker was opened for.")
        case .local: String(localized: "Local Branches", bundle: .module)
        case .remote(let remote): String(localized: "Remote Branches · \(remote)", bundle: .module)
        case .tags: String(localized: "Tags", bundle: .module)
        case .commit: String(localized: "Commit", bundle: .module)
        }
    }
}

/// One line of the picker's list: a section header in `label` caps, or an item with glyph, highlighted name and the muted SHA and age on the right.
final class RefPickerRowView: NSView {
    private typealias R = Theme.RefPicker

    enum Content {
        case header(String)
        case item(RefCatalog.Match)
    }

    var content: Content? { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if case .item = content { onPress?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
        let left = R.rowPadding
        let right = bounds.width - R.rowPadding
        switch content {
        case .header(let title):
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern]
            let text = NSAttributedString(string: title.uppercased(with: AppLanguage.locale), attributes: attributes)
            text.draw(at: CGPoint(x: left, y: bounds.maxY - Theme.Space.xs - text.size().height))
        case .item(let match):
            let item = match.item
            let midY = bounds.midY
            RefItemStyle.drawGlyph(of: item, in: CGRect(x: left, y: midY - R.glyph / 2, width: R.glyph, height: R.glyph), color: Theme.inkMuted, context: context)
            let detail = RefItemStyle.detail(of: item)
            var trailing = right - Self.drawRight(detail.rest, font: Theme.captionDigits, color: Theme.inkMuted, rightEdge: right, midY: midY)
            if let sha = detail.sha {
                trailing -= Theme.Space.s
                trailing -= Self.drawRight(sha, font: Theme.monoSmall, color: Theme.inkFaint, rightEdge: trailing, midY: midY)
            }
            let textLeft = left + R.glyph + R.glyphGap
            let isHead = if case .head = item.kind { true } else { false }
            let font = isHead ? Theme.bodyStrong : Theme.body
            let titleFont = item.kind == .commit ? Theme.mono : font
            let title = GraphRowView.highlighted(item.title, ranges: match.titleRanges, attributes: [.font: titleFont, .foregroundColor: Theme.ink, .paragraphStyle: Self.truncating])
            let titleWidth = min(title.size().width, trailing - R.detailGap - textLeft)
            guard titleWidth > 0 else { return }
            Self.draw(title, x: textLeft, width: titleWidth, midY: midY)
            let subjectLeft = textLeft + titleWidth + R.detailGap
            if item.kind == .commit, trailing - R.detailGap > subjectLeft {
                let subject = NSAttributedString(string: RefItemStyle.commitText(of: item), attributes: [.font: Theme.body, .foregroundColor: Theme.inkMuted, .paragraphStyle: Self.truncating])
                Self.draw(subject, x: subjectLeft, width: trailing - R.detailGap - subjectLeft, midY: midY)
            }
        }
    }

    /// Draws one line of text vertically centred on `midY`, cut with an ellipsis at `width`.
    static func draw(_ text: NSAttributedString, x: CGFloat, width: CGFloat, midY: CGFloat) {
        let height = text.size().height
        text.draw(with: CGRect(x: x, y: midY - height / 2, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// Right-aligned, returns its width.
    @discardableResult
    static func drawRight(_ text: String, font: NSFont, color: NSColor, rightEdge: CGFloat, midY: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rightEdge - size.width, y: midY - size.height / 2), withAttributes: attributes)
        return size.width
    }
}
