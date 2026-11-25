import Foundation
import GitEngine

/// The rows a conflict is drawn with. In the merge window ours, the result (or the base) and theirs get the same number of rows per region, padded with empty rows, so one row is one line across all three columns.
/// In the history pane one column shows the file unified: the lines all agree on and the result of each decided change, and for each open conflict a row of actions above ours and theirs.
struct MergeLayout {
    enum Column: CaseIterable { case ours, middle, theirs }

    /// How a run of rows is tinted.
    enum Tint: Equatable {
        case ours
        case theirs
        /// An open conflict.
        case conflict
        /// The result of a change that kept the base or took both sides or the word merge.
        case resolved
    }

    struct Band: Equatable {
        let row: Int
        let rows: Int
        let tint: Tint
        /// Rows from `row` on that hold text; the rest are padding.
        let lines: Int
        /// Text drawn faint, such as the base standing in for an open conflict in the result.
        let isFaint: Bool
    }

    /// A row of links in place of a line: a label and the actions of one change.
    struct ActionRow: Equatable {
        struct Action: Equatable {
            let title: String
            let link: String
        }

        let label: String
        let actions: [Action]
    }

    struct Text {
        var lines: [String] = []
        /// The line number of each row in its file; nil for padding and action rows.
        var numbers: [Int?] = []
        var bands: [Band] = []
        var actionRows: [Int: ActionRow] = [:]
    }

    /// Where a change sits: its first row and how many rows it spans.
    struct Place: Equatable {
        let row: Int
        let rows: Int
    }

    private(set) var ours = Text()
    private(set) var middle = Text()
    private(set) var theirs = Text()
    private(set) var places: [Place] = []

    func text(of column: Column) -> Text {
        switch column {
        case .ours: ours
        case .middle: middle
        case .theirs: theirs
        }
    }

    // MARK: Three columns

    init(_ resolution: MergeResolution, showsBase: Bool) {
        var row = 0
        var index = 0
        var counters = (ours: 1, middle: 1, theirs: 1)
        for region in resolution.document.regions {
            switch region {
            case .same(let lines):
                append(lines, to: &ours, from: &counters.ours)
                append(lines, to: &middle, from: &counters.middle)
                append(lines, to: &theirs, from: &counters.theirs)
                row += lines.count
            case .change(let change):
                let isOpen = !resolution.isResolved(index)
                let result = showsBase ? change.base : resolution.result(at: index) ?? change.base
                let rows = max(change.ours.count, result.count, change.theirs.count, 1)
                let middleTint: Tint
                if isOpen && !showsBase {
                    middleTint = .conflict
                } else if showsBase || resolution.states[index].merged != nil {
                    middleTint = .resolved
                } else {
                    let taken = resolution.states[index].taken
                    middleTint = taken == [.ours] ? .ours : taken == [.theirs] ? .theirs : .resolved
                }
                let sideTint: (Tint) -> Tint = { isOpen ? .conflict : $0 }
                if change.ours != change.base || change.kind == .conflict { ours.bands.append(Band(row: row, rows: rows, tint: sideTint(.ours), lines: change.ours.count, isFaint: false)) }
                if change.theirs != change.base || change.kind == .conflict { theirs.bands.append(Band(row: row, rows: rows, tint: sideTint(.theirs), lines: change.theirs.count, isFaint: false)) }
                middle.bands.append(Band(row: row, rows: rows, tint: middleTint, lines: result.count, isFaint: isOpen && !showsBase))
                append(change.ours, to: &ours, from: &counters.ours, padTo: rows)
                // An open conflict's base in the result is a stand-in, not part of the file; it gets no numbers.
                if isOpen && !showsBase {
                    var none = 0
                    append(result, to: &middle, from: &none, padTo: rows, numbered: false)
                } else {
                    append(result, to: &middle, from: &counters.middle, padTo: rows)
                }
                append(change.theirs, to: &theirs, from: &counters.theirs, padTo: rows)
                places.append(Place(row: row, rows: rows))
                row += rows
                index += 1
            }
        }
    }

    // MARK: Unified

    /// The file in one column: decided changes show their result, open conflicts a row of actions above ours and theirs.
    init(unified resolution: MergeResolution, sides: ConflictSides, wordMerges: Set<Int>) {
        var row = 0
        var index = 0
        var counter = 1
        var text = Text()
        for region in resolution.document.regions {
            switch region {
            case .same(let lines):
                append(lines, to: &text, from: &counter)
                row += lines.count
            case .change(let change):
                let start = row
                if !resolution.isResolved(index) {
                    text.actionRows[row] = Self.openActions(for: index, number: index + 1, canMerge: wordMerges.contains(index))
                    append([""], to: &text, from: &counter, numbered: false)
                    row += 1
                    // The sides of an open conflict are not lines of the result yet; the numbers are the result's, as in the merge window.
                    var none = 0
                    text.bands.append(Band(row: row, rows: max(change.ours.count, 1), tint: .ours, lines: change.ours.count, isFaint: false))
                    append(change.ours, to: &text, from: &none, padTo: 1, numbered: false)
                    row += max(change.ours.count, 1)
                    text.bands.append(Band(row: row, rows: max(change.theirs.count, 1), tint: .theirs, lines: change.theirs.count, isFaint: false))
                    append(change.theirs, to: &text, from: &none, padTo: 1, numbered: false)
                    row += max(change.theirs.count, 1)
                } else {
                    let result = resolution.result(at: index) ?? change.base
                    let state = resolution.states[index]
                    let tint: Tint = state.merged != nil ? .resolved : state.taken == [.ours] ? .ours : state.taken == [.theirs] ? .theirs : .resolved
                    if change.kind == .conflict {
                        text.actionRows[row] = Self.decidedActions(for: index, number: index + 1)
                        append([""], to: &text, from: &counter, numbered: false)
                        row += 1
                    }
                    text.bands.append(Band(row: row, rows: max(result.count, 1), tint: tint, lines: result.count, isFaint: false))
                    append(result, to: &text, from: &counter, padTo: 1)
                    row += max(result.count, 1)
                }
                places.append(Place(row: start, rows: row - start))
                index += 1
            }
        }
        middle = text
    }

    private static func openActions(for index: Int, number: Int, canMerge: Bool) -> ActionRow {
        var actions = [
            ActionRow.Action(title: String(localized: "conflict.choice.ours", defaultValue: "Ours", bundle: .module, comment: "Resolve the open conflicts with our side"), link: "take/\(index)/ours"),
            ActionRow.Action(title: String(localized: "conflict.choice.theirs", defaultValue: "Theirs", bundle: .module, comment: "Resolve the open conflicts with their side"), link: "take/\(index)/theirs"),
            ActionRow.Action(title: String(localized: "conflict.choice.both", defaultValue: "Both", bundle: .module, comment: "Link above an open conflict: take ours, then theirs"), link: "take/\(index)/both"),
        ]
        if canMerge { actions.append(ActionRow.Action(title: String(localized: "conflict.choice.mergeWords", defaultValue: "Merge words", bundle: .module, comment: "Link above an open conflict: combine the changes of both sides word by word"), link: "merge/\(index)")) }
        return ActionRow(label: String(localized: "conflict.unified.open", defaultValue: "Conflict \(number)", bundle: .module, comment: "Label of the action row above an open conflict in the unified view"), actions: actions)
    }

    private static func decidedActions(for index: Int, number: Int) -> ActionRow {
        ActionRow(label: String(localized: "conflict.unified.decided", defaultValue: "Conflict \(number) resolved", bundle: .module, comment: "Label of the row above a decided conflict in the unified view"), actions: [
            ActionRow.Action(title: String(localized: "conflict.choice.undo", defaultValue: "Undo", bundle: .module, comment: "Link above a decided conflict: open it again"), link: "reopen/\(index)"),
        ])
    }

    // MARK: Rows

    private func append(_ lines: [String], to text: inout Text, from counter: inout Int, padTo rows: Int = 0, numbered: Bool = true) {
        // A trailing carriage return stays in the result but is not drawn.
        text.lines += lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        for _ in lines {
            text.numbers.append(numbered ? counter : nil)
            if numbered { counter += 1 }
        }
        let padding = max(0, rows - lines.count)
        text.lines += Array(repeating: "", count: padding)
        text.numbers += Array(repeating: nil, count: padding)
    }
}
