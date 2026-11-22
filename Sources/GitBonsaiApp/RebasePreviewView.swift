import AppKit
import GitEngine

/// The history after the rebase as a small graph, newest on top like the history: one node per resulting commit, its subject and what happened to it, the commit it lands on at the bottom.
/// Dropped commits are listed below. Rows share the list's height, so both sides keep one grid.
final class RebasePreviewView: NSView {
    private typealias M = Theme.InteractiveRebase

    struct Row: Equatable {
        let subject: String
        let sha: String
        let marks: [(String, NSColor)]
        let branches: [String]
        let isBase: Bool

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.subject == rhs.subject && lhs.sha == rhs.sha && lhs.marks.map(\.0) == rhs.marks.map(\.0) && lhs.branches == rhs.branches && lhs.isBase == rhs.isBase
        }
    }

    private(set) var rows: [Row] = []
    private(set) var dropped: [String] = []

    override var isFlipped: Bool { true }

    /// Lines of text the preview shows, top to bottom, for checks without a picture.
    var textLines: [String] {
        rows.map { row in ([row.isBase ? "Basis" : "•", row.sha, row.subject] + row.marks.map(\.0) + row.branches.map { "[\($0)]" }).joined(separator: " ") } + (dropped.isEmpty ? [] : ["verworfen: " + dropped.joined(separator: ", ")])
    }

    func show(_ model: InteractiveRebaseModel) {
        let plan = model.plan
        let result = plan.result
        var rows: [Row] = []
        // A commit counts as moved when another one now stands where the original order would put it.
        let position = Dictionary(uniqueKeysWithValues: model.original.enumerated().map { ($1.id, $0) })
        let heads = result.map(\.head.id)
        let inOriginalOrder = heads.sorted { position[$0, default: 0] < position[$1, default: 0] }
        for (offset, commit) in result.enumerated().reversed() {
            var marks: [(String, NSColor)] = []
            if commit.isMessageChanged { marks.append((commit.folded.contains { $0.action == .squash } ? "Nachrichten vereint" : "neu formuliert", Theme.sky)) }
            if !commit.folded.isEmpty { marks.append(("+\(commit.folded.count) zusammengeführt", Theme.moss)) }
            if commit.stopsForEdit { marks.append(("hält zum Bearbeiten an", Theme.ochre)) }
            if inOriginalOrder[offset] != commit.head.id { marks.append(("verschoben", Theme.clay)) }
            var branches = commit.branches.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
            if offset == result.count - 1 { branches.insert(model.branch, at: 0) }
            rows.append(Row(subject: commit.subject, sha: commit.head.shortID, marks: marks, branches: branches, isBase: false))
        }
        let baseBranches = result.isEmpty ? [model.branch] : []
        rows.append(Row(subject: model.targetCommit.subject, sha: model.targetCommit.shortID, marks: [], branches: baseBranches, isBase: true))
        self.rows = rows
        dropped = plan.steps.filter { $0.action == .drop }.compactMap { $0.commit?.shortID }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows.count + (dropped.isEmpty ? 0 : 1)) * M.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !rows.isEmpty else { return }
        let height = M.rowHeight
        let centers = rows.indices.map { CGFloat($0) * height + height / 2 }
        if let first = centers.first, let last = centers.last, rows.count > 1 {
            context.setStrokeColor(Theme.moss.cgColor)
            context.setLineWidth(Theme.Stroke.strand)
            context.move(to: CGPoint(x: M.previewStrandX, y: first))
            context.addLine(to: CGPoint(x: M.previewStrandX, y: last))
            context.strokePath()
        }
        for (row, center) in zip(rows, centers) {
            let node = CGRect(x: M.previewStrandX - M.previewNode, y: center - M.previewNode, width: M.previewNode * 2, height: M.previewNode * 2)
            context.setFillColor((row.isBase ? Theme.inkFaint : Theme.surface2).cgColor)
            context.fillEllipse(in: node)
            if !row.isBase {
                context.setStrokeColor(Theme.moss.cgColor)
                context.setLineWidth(Theme.Stroke.strand)
                context.strokeEllipse(in: node.insetBy(dx: Theme.Stroke.strand / 2, dy: Theme.Stroke.strand / 2))
            }
            drawText(of: row, centeredAt: center)
        }
        if !dropped.isEmpty, let last = centers.last {
            let text = NSAttributedString(string: "Verworfen: " + dropped.joined(separator: ", "), attributes: [.font: Theme.caption, .foregroundColor: Theme.persimmon])
            let lineHeight = ceil(text.size().height)
            text.draw(with: NSRect(x: M.previewTextX, y: last + height - lineHeight / 2, width: bounds.width - M.previewTextX - Theme.Space.s, height: lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// Subject on the first line; SHA, marks and branches on the second.
    private func drawText(of row: Row, centeredAt center: CGFloat) {
        let width = bounds.width - M.previewTextX - Theme.Space.s
        let subject = NSAttributedString(string: row.subject, attributes: [.font: row.isBase ? Theme.caption : Theme.bodyMedium, .foregroundColor: row.isBase ? Theme.inkMuted : Theme.ink])
        let lineHeight = M.rowHeight / 2
        subject.draw(with: NSRect(x: M.previewTextX, y: center - lineHeight + Theme.Stroke.hairline, width: width, height: lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let detail = NSMutableAttributedString(string: row.isBase ? "Basis \(row.sha)" : row.sha, attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.inkFaint])
        for (text, color) in row.marks {
            detail.append(NSAttributedString(string: "  " + text, attributes: [.font: Theme.caption, .foregroundColor: color]))
        }
        for branch in row.branches {
            detail.append(NSAttributedString(string: "  ⑂ " + branch, attributes: [.font: Theme.pill, .foregroundColor: Theme.moss]))
        }
        detail.draw(with: NSRect(x: M.previewTextX, y: center + Theme.Stroke.hairline, width: width, height: lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
