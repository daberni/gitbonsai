import AppKit

/// What a name inside running text stands for; it picks the inline pill's glyph and colour.
enum RefKind {
    case branch, remoteBranch, remote, tag, commit, path, worktree, stash
}

/// UI copy with its names marked, written as `"Rebase \(branch: name) auf \(branch: onto)"`. `RefText` draws every name as an inline pill; `plain` is the same sentence as bare text.
struct RefString: ExpressibleByStringInterpolation, Equatable, CustomStringConvertible {
    enum Part: Equatable {
        case text(String)
        case name(String, RefKind)
    }

    var parts: [Part]

    struct StringInterpolation: StringInterpolationProtocol {
        var parts: [Part] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { parts.append(.text(literal)) }
        mutating func appendInterpolation(_ text: String) { parts.append(.text(text)) }
        mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T) { parts.append(.text(value.description)) }
        mutating func appendInterpolation(_ string: RefString) { parts += string.parts }
        mutating func appendInterpolation(branch: String) { parts.append(.name(branch, .branch)) }
        mutating func appendInterpolation(remoteBranch: String) { parts.append(.name(remoteBranch, .remoteBranch)) }
        mutating func appendInterpolation(remote: String) { parts.append(.name(remote, .remote)) }
        mutating func appendInterpolation(tag: String) { parts.append(.name(tag, .tag)) }
        /// A commit is always named by its short SHA.
        mutating func appendInterpolation(commit: String) { parts.append(.name(String(commit.prefix(RefString.shortSHA)), .commit)) }
        mutating func appendInterpolation(path: String) { parts.append(.name(path, .path)) }
        mutating func appendInterpolation(worktree: String) { parts.append(.name(worktree, .worktree)) }
        mutating func appendInterpolation(stash: String) { parts.append(.name(stash, .stash)) }
    }

    static let shortSHA = 7

    init(stringLiteral value: String) { parts = [.text(value)] }
    init(stringInterpolation: StringInterpolation) { parts = stringInterpolation.parts }
    init(_ text: String) { parts = [.text(text)] }
    private init(parts: [Part]) { self.parts = parts }

    /// The sentence without pills, for tooltips, accessibility, logs and the harness.
    var plain: String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .name(let name, _): name
            }
        }.joined()
    }

    /// Interpolated into a plain string, it reads as the plain sentence.
    var description: String { plain }

    var containsNames: Bool { parts.contains { if case .name = $0 { true } else { false } } }

    static func + (lhs: RefString, rhs: RefString) -> RefString { RefString(parts: lhs.parts + rhs.parts) }

    /// Joins the pieces with `separator`, as `[String].joined(separator:)` does.
    static func joined(_ pieces: [RefString], separator: String) -> RefString {
        RefString(parts: pieces.enumerated().flatMap { index, piece in (index == 0 ? [] : [Part.text(separator)]) + piece.parts })
    }
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
        let image = pillImage(name, kind: kind, font: font)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func textFont(_ kind: RefKind, like font: NSFont) -> NSFont {
        switch kind {
        case .commit, .path: NSFont.monospacedSystemFont(ofSize: font.pointSize - M.shrink, weight: .medium)
        default: NSFont.systemFont(ofSize: font.pointSize - M.shrink, weight: .medium)
        }
    }

    private static func color(_ kind: RefKind) -> NSColor {
        switch kind {
        case .branch: Theme.moss
        case .remoteBranch, .remote: Theme.sky
        case .tag: Theme.ochre
        case .worktree: Theme.clay
        case .commit, .path, .stash: Theme.inkMuted
        }
    }

    private static func pillImage(_ name: String, kind: RefKind, font: NSFont) -> NSImage {
        let textFont = textFont(kind, like: font)
        let text = truncatedMiddle(name, font: textFont)
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: Theme.ink]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height = ceil(textSize.height) + M.extraHeight
        let glyph = height - 2 * M.glyphInset
        let size = CGSize(width: M.padding + glyph + M.glyphGap + ceil(textSize.width) + M.trailingPadding, height: height)
        // Drawn on demand, so the colours resolve for the appearance the pill is shown in.
        return NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            color(kind).mixed(into: Theme.surface0, fraction: Theme.Pill.tint.plain).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let glyphRect = CGRect(x: M.padding, y: (rect.height - glyph) / 2, width: glyph, height: glyph)
            drawGlyph(kind, in: glyphRect, context: context)
            (text as NSString).draw(at: CGPoint(x: glyphRect.maxX + M.glyphGap, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
    }

    private static func drawGlyph(_ kind: RefKind, in rect: CGRect, context: CGContext) {
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
        guard title.containsNames else { return }
        attributedTitle = RefText.attributed(title, font: NSFont.menuFont(ofSize: 0))
        setAccessibilityLabel(title.plain)
    }

    /// The title as a person reads it, without the pills' attachment characters; what the harness matches entries by.
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
}
