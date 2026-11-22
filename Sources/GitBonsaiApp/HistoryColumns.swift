import AppKit

/// Widths and visibility of the history columns. The commit text is always shown and takes whatever is left.
struct HistoryColumns: Equatable {
    enum Column: String, CaseIterable {
        case label, graph, commit, author, sha, date

        var title: String {
            switch self {
            case .label: "Branch / Tag"
            case .graph: "Graph"
            case .commit: "Commit"
            case .author: "Autor"
            case .sha: "SHA"
            case .date: "Datum"
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .label: 80
            case .graph: Theme.Graph.firstLane + Theme.Graph.lane / 2
            case .commit: 160
            case .author: 60
            case .sha: 60
            case .date: 64
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
    var sha: CGFloat = 80
    var date: CGFloat = Theme.Graph.dateColumn
    var hidden: Set<Column> = []
    /// How far the graph is scrolled to the left inside its column.
    var graphScrollX: CGFloat = 0

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

/// Column widths and visibility are a preference of the user, shared by all tabs and kept across launches. Screenshot runs neither read nor write them.
@MainActor
enum ColumnStore {
    private static var defaults: UserDefaults? { ScreenshotHarness.outputPath == nil ? .standard : nil }

    static func load() -> HistoryColumns {
        var columns = HistoryColumns.standard
        if let hidden = ProcessInfo.processInfo.environment["GITBONSAI_HIDDEN_COLUMNS"] {
            columns.hidden = Set(hidden.split(separator: ",").compactMap { HistoryColumns.Column(rawValue: String($0)) })
        }
        guard let defaults else { return columns }
        func width(_ key: String) -> CGFloat? { defaults.object(forKey: key) == nil ? nil : CGFloat(defaults.double(forKey: key)) }
        columns.label = width("columnLabel") ?? columns.label
        columns.author = width("columnAuthor") ?? columns.author
        columns.sha = width("columnSHA") ?? columns.sha
        columns.date = width("columnDate") ?? columns.date
        if let hidden = defaults.stringArray(forKey: "hiddenColumns") { columns.hidden = Set(hidden.compactMap(HistoryColumns.Column.init(rawValue:))) }
        return columns
    }

    static func loadGraphWidth() -> CGFloat? {
        guard let defaults, defaults.object(forKey: "columnGraph") != nil else { return nil }
        return CGFloat(defaults.double(forKey: "columnGraph"))
    }

    static func save(_ columns: HistoryColumns, graphWidth: CGFloat?) {
        guard let defaults else { return }
        defaults.set(Double(columns.label), forKey: "columnLabel")
        defaults.set(Double(columns.author), forKey: "columnAuthor")
        defaults.set(Double(columns.sha), forKey: "columnSHA")
        defaults.set(Double(columns.date), forKey: "columnDate")
        defaults.set(columns.hidden.map(\.rawValue).sorted(), forKey: "hiddenColumns")
        if let graphWidth { defaults.set(Double(graphWidth), forKey: "columnGraph") } else { defaults.removeObject(forKey: "columnGraph") }
    }
}
