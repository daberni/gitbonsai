import AppKit

/// Widths and visibility of the history columns. The commit text is always shown and takes whatever is left.
struct HistoryColumns: Equatable {
    enum Column: String, CaseIterable {
        case label, graph, commit, author, sha, date

        var title: String {
            switch self {
            case .label: String(localized: "history.column.label", defaultValue: "Branch / Tag", bundle: .module, comment: "History column header")
            case .graph: String(localized: "history.column.graph", defaultValue: "Graph", bundle: .module, comment: "History column header")
            case .commit: String(localized: "history.column.commit", defaultValue: "Commit", bundle: .module, comment: "History column header: the commit message")
            case .author: String(localized: "history.column.author", defaultValue: "Author", bundle: .module, comment: "History column header")
            case .sha: String(localized: "history.column.sha", defaultValue: "SHA", bundle: .module, comment: "History column header")
            case .date: String(localized: "history.column.date", defaultValue: "Date", bundle: .module, comment: "History column header")
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .label: Theme.Graph.minimumLabelColumn
            case .graph: Theme.Graph.firstLane + Theme.Graph.lane / 2
            case .commit: Theme.Graph.minimumCommitColumn
            case .author: Theme.Graph.minimumAuthorColumn
            case .sha: Theme.Graph.minimumShaColumn
            case .date: Theme.Graph.minimumDateColumn
            }
        }
    }

    /// Where each visible column sits in a history of a given width.
    struct Layout {
        var label: ClosedRange<CGFloat>?
        var graph: ClosedRange<CGFloat>?
        var commit: ClosedRange<CGFloat>
        var author: ClosedRange<CGFloat>?
        var sha: ClosedRange<CGFloat>?
        var date: ClosedRange<CGFloat>?

        /// The draggable boundaries: the right edge of the columns left of the commit text, the left edge of those right of it.
        var dividers: [(Column, CGFloat)] {
            var result: [(Column, CGFloat)] = []
            if let label { result.append((.label, label.upperBound)) }
            if let graph { result.append((.graph, graph.upperBound)) }
            if let author { result.append((.author, author.lowerBound)) }
            if let sha { result.append((.sha, sha.lowerBound)) }
            if let date { result.append((.date, date.lowerBound)) }
            return result
        }
    }

    var label: CGFloat = Theme.Graph.labelColumn
    var graph: CGFloat = Theme.Graph.firstLane + Theme.Graph.lane
    var author: CGFloat = Theme.Graph.authorColumn
    var sha: CGFloat = Theme.Graph.shaColumn
    var date: CGFloat = Theme.Graph.dateColumn
    var hidden: Set<Column> = []
    /// How far the graph is scrolled to the left inside its column.
    var graphScrollX: CGFloat = 0
    /// Width the graph needs to show every lane; wider than `graph` when the graph scrolls.
    var graphContentWidth: CGFloat = 0

    static let standard = HistoryColumns(hidden: [.sha])

    func shows(_ column: Column) -> Bool { column == .commit || !hidden.contains(column) }

    func width(of column: Column) -> CGFloat {
        switch column {
        case .label: label
        case .graph: graph
        case .commit: 0
        case .author: author
        case .sha: sha
        case .date: date
        }
    }

    /// Columns right of the commit text give way when the history gets too narrow, the author first.
    func layout(in width: CGFloat) -> Layout {
        var x: CGFloat = 0
        var label: ClosedRange<CGFloat>?
        var graph: ClosedRange<CGFloat>?
        if shows(.label) { label = x...(x + self.label); x += self.label }
        if shows(.graph) { graph = x...(x + self.graph); x += self.graph }
        var right: [Column] = [.author, .sha, .date].filter(shows)
        while !right.isEmpty, width - x - right.map(self.width(of:)).reduce(0, +) < Column.commit.minimumWidth { right.removeFirst() }
        var ranges: [Column: ClosedRange<CGFloat>] = [:]
        var edge = width
        for column in right.reversed() {
            ranges[column] = (edge - self.width(of: column))...edge
            edge -= self.width(of: column)
        }
        return Layout(label: label, graph: graph, commit: x...max(edge, x), author: ranges[.author], sha: ranges[.sha], date: ranges[.date])
    }

    /// The strips at both ends of the lanes that keep avatars of lanes out of view; nil while the whole graph fits its column.
    struct AvatarStrips: Equatable {
        var left: ClosedRange<CGFloat>
        var right: ClosedRange<CGFloat>
        /// Each strip fades in over its own width of scrolling, so it neither shows at its end of the scroll range nor appears at once.
        var leftOpacity: CGFloat
        var rightOpacity: CGFloat
    }

    func avatarStrips(lanes: ClosedRange<CGFloat>) -> AvatarStrips? {
        let maxScroll = graphContentWidth - graph
        guard maxScroll > 0 else { return nil }
        let width = Theme.Graph.pinStripWidth
        let fade = { (distance: CGFloat) in min(max(distance / width, 0), 1) }
        return AvatarStrips(left: lanes.lowerBound...(lanes.lowerBound + width), right: (lanes.upperBound - width)...lanes.upperBound, leftOpacity: fade(graphScrollX), rightOpacity: fade(maxScroll - graphScrollX))
    }

    /// Centre of an avatar drawn above the strips, or nil when it is drawn on its lane below them. An avatar slides into a strip on its lane and stops at the strip's centre, so nothing jumps.
    static func pinnedAvatarX(nodeX: CGFloat, strips: AvatarStrips?) -> CGFloat? {
        guard let strips else { return nil }
        let radius = Theme.Graph.nodeRadius
        guard nodeX - radius < strips.left.upperBound || nodeX + radius > strips.right.lowerBound else { return nil }
        let leftCentre = (strips.left.lowerBound + strips.left.upperBound) / 2
        let rightCentre = (strips.right.lowerBound + strips.right.upperBound) / 2
        return min(max(nodeX, leftCentre), rightCentre)
    }

    /// Opacity of an avatar above a strip: full while it still follows its lane, dimmed further the further its lane has run past, so it fades instead of switching.
    static func pinnedAvatarAlpha(nodeX: CGFloat, pinnedX: CGFloat) -> CGFloat {
        let progress = min(abs(nodeX - pinnedX) / Theme.Graph.pinStripWidth, 1)
        return 1 - progress * (1 - Theme.Graph.pinnedAvatarAlpha)
    }

    /// Moves the boundary of `column` to `x`. Every column keeps its minimum, and the commit text keeps its own.
    mutating func drag(_ column: Column, to x: CGFloat, in width: CGFloat) {
        let layout = layout(in: width)
        let spare = max(layout.commit.upperBound - layout.commit.lowerBound - Column.commit.minimumWidth, 0)
        let current = self.width(of: column)
        let growth: CGFloat
        switch column {
        case .label, .graph:
            let edge = column == .label ? layout.label?.upperBound : layout.graph?.upperBound
            growth = x - (edge ?? x)
        default:
            let ranges: [Column: ClosedRange<CGFloat>?] = [.author: layout.author, .sha: layout.sha, .date: layout.date]
            growth = ((ranges[column] ?? nil)?.lowerBound ?? x) - x
        }
        let updated = max(min(current + growth, current + spare), column.minimumWidth)
        switch column {
        case .label: label = updated
        case .graph: graph = updated
        case .author: author = updated
        case .sha: sha = updated
        case .date: date = updated
        case .commit: break
        }
    }
}

/// Column widths and visibility are a preference of the user, shared by all tabs and kept across launches. They live in the app's `Persistence`.
@MainActor
struct ColumnStore {
    private let defaults: UserDefaults?

    init(persistence: Persistence) {
        defaults = persistence.defaults
    }

    func load() -> HistoryColumns {
        var columns = HistoryColumns.standard
        guard let defaults else { return columns }
        func width(_ key: String) -> CGFloat? { defaults.object(forKey: key) == nil ? nil : CGFloat(defaults.double(forKey: key)) }
        columns.label = width("columnLabel") ?? columns.label
        columns.author = width("columnAuthor") ?? columns.author
        columns.sha = width("columnSHA") ?? columns.sha
        columns.date = width("columnDate") ?? columns.date
        if let hidden = defaults.stringArray(forKey: "hiddenColumns") { columns.hidden = Set(hidden.compactMap(HistoryColumns.Column.init(rawValue:))) }
        return columns
    }

    func loadGraphWidth() -> CGFloat? {
        guard let defaults, defaults.object(forKey: "columnGraph") != nil else { return nil }
        return CGFloat(defaults.double(forKey: "columnGraph"))
    }

    /// Column widths of another list, such as the interactive rebase steps, by column name under their own key.
    func widths(forKey key: String) -> [String: CGFloat] {
        guard let defaults, let stored = defaults.dictionary(forKey: key) as? [String: Double] else { return [:] }
        return stored.mapValues { CGFloat($0) }
    }

    func save(widths: [String: CGFloat], forKey key: String) {
        defaults?.set(widths.mapValues { Double($0) }, forKey: key)
    }

    func save(_ columns: HistoryColumns, graphWidth: CGFloat?) {
        guard let defaults else { return }
        defaults.set(Double(columns.label), forKey: "columnLabel")
        defaults.set(Double(columns.author), forKey: "columnAuthor")
        defaults.set(Double(columns.sha), forKey: "columnSHA")
        defaults.set(Double(columns.date), forKey: "columnDate")
        defaults.set(columns.hidden.map(\.rawValue).sorted(), forKey: "hiddenColumns")
        if let graphWidth { defaults.set(Double(graphWidth), forKey: "columnGraph") } else { defaults.removeObject(forKey: "columnGraph") }
    }
}
