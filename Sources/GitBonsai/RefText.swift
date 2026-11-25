import AppKit

/// What a name inside running text stands for; it picks the inline pill's glyph and colour. The raw value is its code inside a `RefName` mark.
enum RefKind: Character {
    case branch = "b", remoteBranch = "r", remote = "o", tag = "t", commit = "c", path = "p", worktree = "w", stash = "s"
}

/// UI copy in the app's language with its names found: `RefText` draws every name as an inline pill; `plain` is the same sentence as bare text.
/// Built from a `LocalizedStringResource` whose names were marked with `RefName`, or from text shown as it is.
struct RefString: Equatable, CustomStringConvertible {
    enum Part: Equatable {
        case text(String)
        case name(String, RefKind)
    }

    var parts: [Part]

    static let shortSHA = 7

    init(_ resource: LocalizedStringResource) { self.init(marked: resource.marked) }

    /// Text shown as it is, such as git's output or a commit subject; marks in it are not looked for.
    init(verbatim text: String) { parts = text.isEmpty ? [] : [.text(text)] }

    /// Finds the names `RefName` marked in `text`.
    init(marked text: String) {
        var parts: [Part] = []
        var rest = Substring(text)
        while let start = rest.firstIndex(of: RefName.start) {
            if start > rest.startIndex { parts.append(.text(String(rest[..<start]))) }
            let afterStart = rest.index(after: start)
            guard afterStart < rest.endIndex, let kind = RefKind(rawValue: rest[afterStart]), let end = rest[afterStart...].firstIndex(of: RefName.end) else {
                parts.append(.text(String(rest[start...])))
                rest = ""
                break
            }
            parts.append(.name(String(rest[rest.index(after: afterStart)..<end]), kind))
            rest = rest[rest.index(after: end)...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        self.parts = parts
    }

    private init(parts: [Part]) { self.parts = parts }

    /// The sentence without pills, for tooltips, accessibility and logs.
    var plain: String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .name(let name, _): name
            }
        }.joined()
    }

    /// The sentence with its names marked again, to pass on as an argument of another localized text.
    var marked: String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .name(let name, let kind): RefName.mark(name, kind)
            }
        }.joined()
    }

    /// Interpolated into a plain string, it reads as the plain sentence.
    var description: String { plain }

    var isEmpty: Bool { parts.isEmpty }

    var containsNames: Bool { parts.contains { if case .name = $0 { true } else { false } } }
}

/// Draws the names of a `RefString` as small pills inside text: the history's ref pill in miniature, with its glyph, in the colour of its kind.
@MainActor
enum RefText {
    private typealias M = Theme.RefText

    /// `color` nil leaves the text colour to the control, so a menu draws disabled and highlighted rows its own way.
    static func attributed(_ string: RefString, font: NSFont, color: NSColor? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var base: [NSAttributedString.Key: Any] = [.font: font]
        if let color { base[.foregroundColor] = color }
        for part in string.parts {
            switch part {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: base))
            case .name(let name, let kind):
                // The name goes in once more as text too small and clear to see, before its pill: the control's plain text then reads
                // "develop auschecken" instead of "￼ auschecken", so type-select in menus, VoiceOver and copying keep the name.
                result.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: M.hiddenSize), .foregroundColor: NSColor.clear]))
                result.append(pill(name, kind: kind, font: font))
            }
        }
        return result
    }

    /// The plain text of a control that shows a `RefString`, without the pills' attachment characters.
    nonisolated static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private static func pill(_ name: String, kind: RefKind, font: NSFont) -> NSAttributedString {
        let metrics = PillMetrics(kind, like: font)
        let image = pillImage(name, kind: kind, metrics: metrics)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -metrics.baselineFromBottom, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// One pill's measurements: its text has the size of the text around it, and height, glyph and padding follow from that size, so a pill in a menu, an alert or the command bar reads like its line.
    @MainActor struct PillMetrics {
        let textFont: NSFont
        let lineHeight: CGFloat
        let height: CGFloat
        let glyph: CGFloat
        let padding: CGFloat
        let glyphGap: CGFloat
        let trailingPadding: CGFloat

        init(_ kind: RefKind, like font: NSFont) {
            let size = font.pointSize
            textFont = RefText.textFont(kind, like: font)
            lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
            height = lineHeight + ceil(size * M.extraHeight)
            glyph = height - 2 * round(size * M.glyphInset)
            padding = round(size * M.padding)
            glyphGap = round(size * M.glyphGap)
            trailingPadding = round(size * M.trailingPadding)
        }

        var textInset: CGFloat { padding + glyph + glyphGap }
        /// Top of the text line inside a one-line pill.
        var textTop: CGFloat { (height - lineHeight) / 2 }
        /// The pill text's baseline above the pill's bottom edge; placing the pill this far below the line's baseline aligns both texts.
        var baselineFromBottom: CGFloat { height - textTop - textFont.ascender }
    }

    /// A word such as "Default" in the muted pill of the settings lists, without a glyph, for a menu item's marker.
    static func marker(_ text: String, font: NSFont) -> NSAttributedString {
        let metrics = PillMetrics(.branch, like: font)
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.textFont, .foregroundColor: Theme.ink]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        let size = CGSize(width: textWidth + 2 * metrics.trailingPadding, height: metrics.height)
        let image = NSImage(size: size, flipped: true) { rect in
            Theme.inkMuted.mixed(into: Theme.surface0, fraction: Theme.Pill.tint.plain).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            (text as NSString).draw(at: CGPoint(x: metrics.trailingPadding, y: metrics.textTop), withAttributes: attributes)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -metrics.baselineFromBottom, width: size.width, height: size.height)
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: M.hiddenSize), .foregroundColor: NSColor.clear])
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    static func textFont(_ kind: RefKind, like font: NSFont) -> NSFont {
        switch kind {
        case .commit, .path: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .medium)
        default: NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
        }
    }

    static func color(_ kind: RefKind) -> NSColor {
        switch kind {
        case .branch: Theme.moss
        case .remoteBranch, .remote: Theme.sky
        case .tag: Theme.ochre
        case .worktree: Theme.clay
        case .commit, .path, .stash: Theme.inkMuted
        }
    }

    private static func pillImage(_ name: String, kind: RefKind, metrics: PillMetrics) -> NSImage {
        let text = truncatedMiddle(name, font: metrics.textFont)
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.textFont, .foregroundColor: Theme.ink]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        let glyph = metrics.glyph
        let size = CGSize(width: metrics.textInset + textWidth + metrics.trailingPadding, height: metrics.height)
        // Drawn on demand, so the colours resolve for the appearance the pill is shown in.
        return NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            color(kind).mixed(into: Theme.surface0, fraction: Theme.Pill.tint.plain).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let glyphRect = CGRect(x: metrics.padding, y: (rect.height - glyph) / 2, width: glyph, height: glyph)
            drawGlyph(kind, in: glyphRect, context: context)
            (text as NSString).draw(at: CGPoint(x: metrics.textInset, y: metrics.textTop), withAttributes: attributes)
            return true
        }
    }

    static func drawGlyph(_ kind: RefKind, in rect: CGRect, context: CGContext) {
        let glyph: Glyph? = switch kind {
        case .branch: .laptop
        case .remoteBranch, .remote: .cloud
        case .tag: .tag
        case .path: .document
        case .worktree: .bonsaiLinked
        case .stash: .stashBowl
        case .commit: nil
        }
        if let glyph {
            glyph.draw(in: rect, color: Theme.ink, context: context)
            return
        }
        // The graph's commit node, small: a ring.
        context.setStrokeColor(Theme.ink.cgColor)
        context.setLineWidth(M.commitRing)
        context.strokeEllipse(in: rect.insetBy(dx: rect.width * M.commitInset, dy: rect.height * M.commitInset))
    }

    /// Cuts the middle out of a name wider than `Theme.RefText.maxNameWidth`, keeping its start (feature/) and its distinguishing end.
    private static func truncatedMiddle(_ name: String, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (name as NSString).size(withAttributes: attributes).width > M.maxNameWidth else { return name }
        let characters = Array(name)
        var keep = characters.count - 1
        while keep > 2 {
            let head = keep / 2
            let candidate = String(characters[..<head]) + "…" + String(characters[(characters.count - (keep - head))...])
            if (candidate as NSString).size(withAttributes: attributes).width <= M.maxNameWidth { return candidate }
            keep -= 1
        }
        return "…"
    }
}

extension NSMenuItem {
    /// Shows `title` with its names as pills; VoiceOver gets the plain sentence.
    @MainActor func setTitle(_ title: RefString) {
        self.title = title.plain
        guard title.containsNames else {
            // A pill title set before would otherwise stay on screen over the plain one.
            attributedTitle = nil
            return
        }
        attributedTitle = RefText.attributed(title, font: NSFont.menuFont(ofSize: 0))
        setAccessibilityLabel(title.plain)
    }

    @MainActor func setTitle(_ title: LocalizedStringResource) { setTitle(RefString(title)) }

    /// Shows `title` followed by `marker`, such as "Default", as a pill.
    @MainActor func setTitle(_ title: RefString, marker: String) {
        let font = NSFont.menuFont(ofSize: 0)
        self.title = title.plain + " " + marker
        let text = NSMutableAttributedString(attributedString: RefText.attributed(title, font: font))
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        text.append(RefText.marker(marker, font: font))
        attributedTitle = text
        setAccessibilityLabel(self.title)
    }

    /// The title as a person reads it, without the pills' attachment characters; what tests match entries by.
    var plainTitle: String { RefText.plain(title) }
}

extension NSTextField {
    /// Shows `text` in the field's font and colour, its names as pills.
    @MainActor func setText(_ text: RefString) {
        guard text.containsNames, let font else {
            stringValue = text.plain
            return
        }
        let rendered = NSMutableAttributedString(attributedString: RefText.attributed(text, font: font, color: textColor))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        rendered.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: rendered.length))
        attributedStringValue = rendered
    }

    @MainActor func setText(_ text: LocalizedStringResource) { setText(RefString(text)) }
}
