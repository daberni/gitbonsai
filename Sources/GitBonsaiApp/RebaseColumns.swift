import AppKit

/// Columns of the interactive rebase list: a fixed handle with the grip and the fold mark, then action, SHA, subject and branches.
/// The subject takes the room the others leave; when the columns need more than the list is wide, the list scrolls sideways.
struct RebaseColumns: Equatable {
    private typealias M = Theme.InteractiveRebase

    enum Column: String, CaseIterable {
        case action, sha, subject, branches

        var title: String {
            switch self {
            case .action: String(localized: "rebase.column.action", defaultValue: "Action", bundle: .module, comment: "Column header in the rebase sheet: pick, reword, squash …")
            case .sha: String(localized: "rebase.column.sha", defaultValue: "SHA", bundle: .module)
            case .subject: String(localized: "rebase.column.message", defaultValue: "Message", bundle: .module, comment: "Caption above the commit message editor; also a column header.")
            case .branches: String(localized: "rebase.column.branches", defaultValue: "Branches", bundle: .module, comment: "Column header in the rebase sheet.")
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .action: M.minimumActionColumn
            case .sha: M.minimumShaColumn
            case .subject: M.minimumSubjectColumn
            case .branches: M.minimumBranchesColumn
            }
        }

        var standardWidth: CGFloat {
            switch self {
            case .action: M.actionColumn
            case .sha: M.shaColumn
            case .subject: M.subjectColumn
            case .branches: M.branchesColumn
            }
        }
    }

    var widths: [Column: CGFloat] = Dictionary(uniqueKeysWithValues: Column.allCases.map { ($0, $0.standardWidth) })

    func width(of column: Column) -> CGFloat { widths[column] ?? column.standardWidth }

    /// The width of the rows: the list's own width, or more when the columns need it.
    func totalWidth(in visibleWidth: CGFloat) -> CGFloat {
        max(visibleWidth, M.handleWidth + Column.allCases.map(width(of:)).reduce(0, +))
    }

    /// Where each column sits in rows of `totalWidth(in:)`.
    func layout(in visibleWidth: CGFloat) -> [Column: ClosedRange<CGFloat>] {
        let total = totalWidth(in: visibleWidth)
        let fixed = M.handleWidth + width(of: .action) + width(of: .sha) + width(of: .branches)
        var x = M.handleWidth
        var ranges: [Column: ClosedRange<CGFloat>] = [:]
        for column in Column.allCases {
            let width = column == .subject ? total - fixed : width(of: column)
            ranges[column] = x...(x + width)
            x += width
        }
        return ranges
    }

    /// The draggable boundaries: the right edge of every column but the last.
    func dividers(in visibleWidth: CGFloat) -> [(Column, CGFloat)] {
        let ranges = layout(in: visibleWidth)
        return Column.allCases.dropLast().compactMap { column in ranges[column].map { (column, $0.upperBound) } }
    }

    /// Moves the right edge of `column` to `x`. Narrowing the subject while it fills the list widens the branches instead, so the boundary follows the mouse.
    mutating func drag(_ column: Column, to x: CGFloat, in visibleWidth: CGFloat) {
        guard let range = layout(in: visibleWidth)[column] else { return }
        let updated = max(x - range.lowerBound, column.minimumWidth)
        widths[column] = updated
        guard column == .subject else { return }
        let spare = visibleWidth - M.handleWidth - Column.allCases.map(width(of:)).reduce(0, +)
        if spare > 0 { widths[.branches] = width(of: .branches) + spare }
    }

    // MARK: Storage

    private static let storeKey = "rebaseColumns"

    @MainActor
    static func load() -> RebaseColumns {
        var columns = RebaseColumns()
        for (name, width) in ColumnStore.widths(forKey: storeKey) {
            if let column = Column(rawValue: name) { columns.widths[column] = max(width, column.minimumWidth) }
        }
        return columns
    }

    @MainActor
    func save() {
        ColumnStore.save(widths: Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value) }), forKey: Self.storeKey)
    }
}

/// The captions above the rebase list. It scrolls sideways with the rows, and its boundaries can be dragged like those over the rows.
final class RebaseColumnHeaderView: NSTableHeaderView {
    var columns = RebaseColumns() { didSet { if columns != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    /// The width the list shows, which the columns fill.
    var visibleWidth: CGFloat = 0 { didSet { if visibleWidth != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var onDrag: ((RebaseColumns.Column, CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    private var dividers: [(RebaseColumns.Column, CGFloat)] { columns.dividers(in: visibleWidth) }

    override func resetCursorRects() {
        ColumnDividers.addCursorRects(to: self, at: dividers.map(\.1))
    }

    override func mouseDown(with event: NSEvent) {
        guard let divider = ColumnDividers.hit(convert(event.locationInWindow, from: nil).x, in: dividers) else { return }
        ColumnDividers.followDrag(in: self) { onDrag?(divider, $0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
        for (_, x) in dividers { NSRect(x: x.rounded() - Theme.Stroke.hairline / 2, y: Theme.ColumnHeader.dividerInset, width: Theme.Stroke.hairline, height: bounds.height - 2 * Theme.ColumnHeader.dividerInset).fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern]
        for (column, range) in columns.layout(in: visibleWidth) {
            let string = NSAttributedString(string: column.title.uppercased(with: AppLanguage.locale), attributes: attributes)
            let size = string.size()
            let x = range.lowerBound + Theme.Cell.leading
            guard x + size.width <= range.upperBound - Theme.Cell.captionClearance else { continue }
            string.draw(at: CGPoint(x: x, y: bounds.midY - size.height / 2))
        }
    }
}

/// The caption bar above the result preview, as tall as the list's header so both lists start on the same line.
final class CaptionBarView: NSView {
    var title = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
        let string = NSAttributedString(string: title.uppercased(with: AppLanguage.locale), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
        string.draw(at: CGPoint(x: Theme.Cell.leading, y: bounds.midY - string.size().height / 2))
    }
}
