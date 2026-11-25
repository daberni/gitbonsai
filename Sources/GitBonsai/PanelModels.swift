import AppKit

/// One entry of a sidebar panel: two lines, a glyph on the left and the age and short SHA on the right.
struct PanelRow: Equatable {
    let id: String
    let glyph: Glyph
    let title: String
    /// Drawn after the title in muted ink, for example ◆ for an annotated tag.
    let marker: String?
    let tooltip: String?
    let detail: String
    /// Nil for an entry that exists only elsewhere, a tag not fetched yet for instance.
    let date: Date?
    let sha: String
    /// Extra words the filter matches besides the title.
    let searchText: String
    /// Small marks before the age, such as where a tag exists.
    var badges: [PanelBadge] = []
    /// A row that needs attention gets a clay wash.
    var isHighlighted = false
    /// A row that is not here yet draws its title and glyph muted.
    var isDimmed = false
}

/// A glyph with an optional caption, drawn on the first line of a row.
struct PanelBadge: Equatable {
    enum Tone: Equatable { case muted, faint, alert }

    let glyph: Glyph
    let label: String?
    let tone: Tone
}

/// A choice in the filter's menu that narrows the list to some entries, by their id.
struct PanelScope {
    let title: String
    /// Shown in the empty list when no entry is in this scope.
    let empty: String
    let includes: (String) -> Bool
}

/// A button below the list that acts on the selected entry.
struct PanelAction {
    let title: String
    let isDestructive: Bool
    let isEnabled: (String) -> Bool
    /// Whether the button is there at all for the selected entry, or with nil for no selection; for actions that only some kinds of entries have.
    let isShown: (String?) -> Bool
    let perform: (String) -> Void

    init(_ title: LocalizedStringResource, isDestructive: Bool = false, isEnabled: @escaping (String) -> Bool = { _ in true }, isShown: @escaping (String?) -> Bool = { _ in true }, perform: @escaping (String) -> Void) {
        self.title = title.text
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isShown = isShown
        self.perform = perform
    }
}
