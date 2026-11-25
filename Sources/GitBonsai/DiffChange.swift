import AppKit
import GitEngine

/// What happened to the file shown, with the letter and colour of the file lists, and the sentence its tooltip says.
struct DiffChange {
    let letter: String
    let color: NSColor
    let word: String
    /// Set for a rename or copy.
    let oldPath: String?
    let description: String

    @MainActor init(selection: FileSelection, diff: FileDiff?) {
        let isUntracked = switch selection.source {
        case .untracked, .added: true
        default: false
        }
        let state: FileState? = isUntracked ? nil : diff?.change ?? (selection.originalPath == nil ? nil : .renamed)
        oldPath = diff?.oldPath ?? selection.originalPath
        if isUntracked {
            letter = "?"
            color = Theme.inkMuted
            word = String(localized: "files.state.untracked", defaultValue: "untracked", bundle: .module, comment: "Note on a file row: a file git does not track yet")
        } else if let state {
            letter = String(state.rawValue)
            color = state.tint
            word = Self.word(for: state)
        } else {
            letter = ""
            color = Theme.inkMuted
            word = ""
        }
        var lines: [String] = []
        if let oldPath {
            lines.append(Self.move(copied: state == .copied, from: oldPath, to: selection.path, similarity: diff?.similarity))
        } else {
            lines.append(selection.path)
        }
        if let diff, diff.modeChanged, let oldMode = diff.oldMode, let newMode = diff.newMode { lines.append(String(localized: "diff.fileMode", defaultValue: "File mode \("\(oldMode) → \(newMode)")", bundle: .module, comment: "e.g. File mode 100644 → 100755")) }
        description = lines.joined(separator: "\n")
    }

    /// A path with an old path was renamed unless git says it was copied.
    private static func move(copied: Bool, from oldPath: String, to path: String, similarity: Int?) -> String {
        switch (copied, similarity) {
        case (true, let similarity?): String(localized: "diff.header.copiedSimilarity", defaultValue: "copied from \(oldPath) to \(path) (similarity \(similarity) %)", bundle: .module)
        case (true, nil): String(localized: "diff.header.copied", defaultValue: "copied from \(oldPath) to \(path)", bundle: .module)
        case (false, let similarity?): String(localized: "diff.header.renamedSimilarity", defaultValue: "renamed from \(oldPath) to \(path) (similarity \(similarity) %)", bundle: .module)
        case (false, nil): String(localized: "diff.header.renamed", defaultValue: "renamed from \(oldPath) to \(path)", bundle: .module)
        }
    }

    private static func word(for state: FileState) -> String {
        switch state {
        case .added: String(localized: "files.state.added", defaultValue: "added", bundle: .module, comment: "What happened to a file")
        case .deleted: String(localized: "files.state.deleted", defaultValue: "deleted", bundle: .module, comment: "What happened to a file")
        case .renamed: String(localized: "files.state.renamed", defaultValue: "renamed", bundle: .module, comment: "What happened to a file")
        case .copied: String(localized: "files.state.copied", defaultValue: "copied", bundle: .module, comment: "What happened to a file")
        case .typeChanged: String(localized: "files.state.typeChanged", defaultValue: "type changed", bundle: .module, comment: "What happened to a file")
        case .unmerged: String(localized: "files.state.conflict", defaultValue: "conflict", bundle: .module, comment: "Note on a file row: the file has unresolved conflicts")
        case .modified, .unmodified: String(localized: "files.state.modified", defaultValue: "modified", bundle: .module, comment: "What happened to a file")
        }
    }
}

/// The old and new path of a rename around the leading and trailing folders they share, as `git diff --stat` writes them, so both fit on one line:
/// `src/{transactions → ledger}/server/repository.ts`, or `docs/old.md → new.md` when only the name changed.
enum RenamedPath {
    static func text(old: String, new: String) -> String {
        let oldParts = old.split(separator: "/", omittingEmptySubsequences: false)
        let newParts = new.split(separator: "/", omittingEmptySubsequences: false)
        // Each side keeps at least one component of its own.
        let limit = min(oldParts.count, newParts.count) - 1
        let shared = zip(oldParts, newParts).prefix { $0 == $1 }.count
        let leading = min(shared, limit)
        let trailing = min(zip(oldParts.reversed(), newParts.reversed()).prefix { $0 == $1 }.count, limit - leading)
        let prefix = oldParts.prefix(leading).map { $0 + "/" }.joined()
        let suffix = oldParts.suffix(trailing).map { "/" + $0 }.joined()
        let oldMiddle = oldParts[leading..<(oldParts.count - trailing)].joined(separator: "/")
        let newMiddle = newParts[leading..<(newParts.count - trailing)].joined(separator: "/")
        return suffix.isEmpty ? "\(prefix)\(oldMiddle) → \(newMiddle)" : "\(prefix){\(oldMiddle) → \(newMiddle)}\(suffix)"
    }
}
