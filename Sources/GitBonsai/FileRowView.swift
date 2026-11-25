import AppKit
import GitEngine

/// One file in one line: status letter, the folder dimmed, the file name, and on the right the line counts.
/// When space runs out the folder gives way from the front, the file name stays.
/// The cell of the file table, reused for other files while scrolling; the table handles clicks, keys and menus.
final class FileRowView: NSTableCellView {
    /// What the buttons a hovered row shows do with the whole file.
    enum Action {
        case stage, unstage, discard

        var glyph: Glyph {
            switch self {
            case .stage: .plus
            case .unstage: .minus
            case .discard: .trash
            }
        }
    }

    struct Model {
        let selection: FileSelection
        let letter: String
        let color: NSColor
        let stat: DiffStat?
        /// Shown instead of the counts, for instance "untracked".
        let note: String?
        /// Shown from right to left while the row is hovered.
        var actions: [Action] = []
        /// What happened to the file, where the context menu needs to know; nil for an untracked file.
        var state: FileState? = nil

        init(selection: FileSelection, letter: String, color: NSColor, stat: DiffStat?, note: String?, actions: [Action] = [], state: FileState? = nil) {
            self.selection = selection
            self.letter = letter
            self.color = color
            self.stat = stat
            self.note = note
            self.actions = actions
            self.state = state
        }
    }

    private typealias M = Theme.FileList
    var model: Model {
        didSet {
            toolTip = Self.toolTip(model)
            needsDisplay = true
        }
    }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// The file list tracks the pointer for all rows and tells the one under it; nil while the pointer is elsewhere.
    private(set) var hover: Hover? { didSet { if hover != oldValue { needsDisplay = true } } }
    private var isHovered: Bool { hover != nil }
    private var hoveredAction: Action? { hover?.action }

    struct Hover: Equatable {
        /// The action button under the pointer, if any.
        var action: Action?
    }

    func setHover(_ hover: Hover?) { self.hover = hover }

    /// The action buttons take the place of the counts at the right end while the row is hovered, the first one outermost.
    func actionRect(_ index: Int) -> CGRect {
        let size = M.actionButton
        let maxX = bounds.maxX - Theme.Space.xs / 2 - CGFloat(index) * (size + M.actionGap)
        return CGRect(x: maxX - size, y: bounds.midY - size / 2, width: size, height: size)
    }

    /// The right-hand slot always reserves room for the buttons, so the path keeps its place and cut whether or not the row is hovered.
    private var actionsWidth: CGFloat {
        guard !model.actions.isEmpty else { return 0 }
        return bounds.maxX - Theme.Space.xs - actionRect(model.actions.count - 1).minX
    }

    func action(at point: CGPoint) -> Action? {
        model.actions.indices.first { actionRect($0).contains(point) }.map { model.actions[$0] }
    }

    init(model: Model) {
        self.model = model
        super.init(frame: .zero)
        toolTip = Self.toolTip(model)
    }

    private static func toolTip(_ model: Model) -> String {
        model.selection.originalPath.map { "\($0) → \(model.selection.path)" } ?? model.selection.path
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// A reused cell must not show the hover of the file it showed before.
    override func prepareForReuse() {
        super.prepareForReuse()
        hover = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHovered {
            (isSelected ? Theme.surfaceSelected : Theme.surface2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: M.rowRadius, yRadius: M.rowRadius).fill()
        }
        let midY = bounds.midY
        let inset = Theme.Space.xs
        let letter = NSAttributedString(string: model.letter, attributes: [.font: Theme.monoStrong, .foregroundColor: model.color])
        letter.draw(at: CGPoint(x: inset, y: midY - letter.size().height / 2))

        let trailing = trailingText()
        let trailingWidth = max(trailing?.size().width ?? 0, actionsWidth)
        if isHovered && !model.actions.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            for (index, action) in model.actions.enumerated() {
                let rect = actionRect(index)
                if hoveredAction == action {
                    Theme.ink.withAlphaComponent(Theme.Wash.pressed).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
                }
                action.glyph.draw(in: rect.insetBy(dx: Theme.Space.xs, dy: Theme.Space.xs), color: Theme.ink, context: context)
            }
        } else if let trailing {
            let size = trailing.size()
            trailing.draw(at: CGPoint(x: bounds.maxX - inset - size.width, y: midY - size.height / 2))
        }

        let pathX = inset + M.letterWidth
        let available = bounds.maxX - inset - trailingWidth - (trailingWidth == 0 ? 0 : M.statGap) - pathX
        guard available > 0 else { return }
        // One string, cut from the front: the folder goes first, the file name last.
        let path = NSMutableAttributedString(string: model.selection.directory, attributes: Self.attributes(Theme.inkMuted))
        path.append(NSAttributedString(string: model.selection.name, attributes: Self.attributes(Theme.ink)))
        let height = path.size().height
        path.draw(with: CGRect(x: pathX, y: midY - height / 2, width: available, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func attributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        return [.font: Theme.mono, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func trailingText() -> NSAttributedString? {
        if let note = model.note { return NSAttributedString(string: note, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted]) }
        guard let stat = model.stat else { return nil }
        return Self.statText(stat)
    }

    /// `+18 −9`, either part left out when it is zero.
    static func statText(_ stat: DiffStat) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if stat.added > 0 { text.append(NSAttributedString(string: "+\(stat.added)", attributes: [.font: Theme.captionDigits, .foregroundColor: Theme.moss])) }
        if stat.removed > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: Theme.captionDigits])) }
            text.append(NSAttributedString(string: "−\(stat.removed)", attributes: [.font: Theme.captionDigits, .foregroundColor: Theme.persimmon]))
        }
        return text
    }
}

extension FileState {
    /// The colour of the change letter, the same in the file lists and the diff header.
    @MainActor var tint: NSColor {
        switch self {
        case .added: Theme.moss
        case .deleted, .unmerged: Theme.persimmon
        case .renamed, .copied: Theme.sky
        default: Theme.ochre
        }
    }
}
