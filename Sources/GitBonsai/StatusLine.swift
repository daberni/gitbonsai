/// The line under the history: the last action's git command and what the loaded history holds.
///
/// Loads and refreshes, including the reconciles that follow every change on disk, only rewrite the summary; the note belongs to actions, so the next action alone replaces or clears it.
struct StatusLine {
    /// What the history holds, or how far a load got.
    var summary: String
    /// The last action's git command, its duration or its failure.
    var note: String?

    /// The note leads, so a narrow window cuts the summary off rather than the command.
    var text: String {
        guard let note else { return summary }
        return "\(note) · \(summary)"
    }
}
