import AppKit
import GitEngine

/// The tooltips of history rows, one per cell rather than one for the whole row: the exact date over the date column, the working directory's hint over its counts,
/// and the full text of a subject or author only where the row cuts it off. Cut-off ref pills need none; hovering them expands them in place.
/// The widths follow the same column layout and fonts `GraphRowView` draws with.
@MainActor
final class HistoryRowToolTips {
    struct Tip: Equatable {
        let range: ClosedRange<CGFloat>
        let text: String
    }

    /// AppKit keeps tooltip owners unretained, so each row view's owners live here until the view gets new ones.
    private final class Owner: NSObject, NSViewToolTipOwner {
        let text: String
        init(_ text: String) { self.text = text }
        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { text }
    }

    private var owners: [ObjectIdentifier: [Owner]] = [:]
    private(set) var installed: [ObjectIdentifier: [Tip]] = [:]

    /// Replaces the view's tooltips with those of the model at the given row width.
    func install(on view: NSView, model: GraphRowView.Model, width: CGFloat) {
        view.removeAllToolTips()
        let tips = Self.tips(for: model, width: width)
        let viewOwners = tips.map { Owner($0.text) }
        for (tip, owner) in zip(tips, viewOwners) {
            view.addToolTip(NSRect(x: tip.range.lowerBound, y: 0, width: tip.range.upperBound - tip.range.lowerBound, height: Theme.Graph.rowHeight), owner: owner, userData: nil)
        }
        owners[ObjectIdentifier(view)] = viewOwners
        installed[ObjectIdentifier(view)] = tips
    }

    static func tips(for model: GraphRowView.Model, width: CGFloat) -> [Tip] {
        typealias C = Theme.Cell
        let layout = model.columns.layout(in: width)
        var tips: [Tip] = []
        if model.wipCounts != nil {
            return [Tip(range: layout.commit, text: String(localized: "history.row.uncommittedChanges", defaultValue: "Uncommitted changes", bundle: .module))]
        }
        let textX = layout.commit.lowerBound + C.subjectLeading
        let subjectWidth = max(layout.commit.upperBound - textX - C.leading, C.minimumSubject)
        var font = model.isHead ? Theme.bodyStrong : Theme.body
        if model.kind == .stash { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        if Self.width(of: model.subject, font: font) > subjectWidth {
            tips.append(Tip(range: textX...(textX + subjectWidth), text: model.subject))
        }
        func cutOff(_ text: String, in range: ClosedRange<CGFloat>?, font: NSFont) {
            guard let range else { return }
            let available = range.upperBound - range.lowerBound - C.leading - C.trailing
            guard available > C.minimumText, Self.width(of: text, font: font) > available else { return }
            tips.append(Tip(range: range, text: text))
        }
        cutOff(model.commit.authorName, in: layout.author, font: Theme.caption)
        if let date = layout.date {
            tips.append(Tip(range: date, text: DateText.exact(model.commit.authorDate)))
        }
        return tips
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }
}
