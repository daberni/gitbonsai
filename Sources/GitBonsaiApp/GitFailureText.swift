import AppKit
import GitEngine

/// The app's words for a failed git command: one sentence of what happened, with git's own output kept as details.
enum GitFailureText {
    /// "Commit 11f8174 „Add an ETP tab“ ließ sich nicht anwenden."
    static func summary(of error: Error) -> String {
        guard let gitError = error as? GitError else { return error.localizedDescription }
        switch GitFailure(output: gitError.stderr) {
        case let .couldNotApply(commit, subject): return "Commit \(commit)\(quoted(subject)) ließ sich nicht anwenden."
        case let .couldNotRevert(commit, subject): return "Commit \(commit)\(quoted(subject)) ließ sich nicht zurücknehmen."
        case let .conflicts(paths): return "Konflikte in \(list(paths))."
        case let .localChangesInTheWay(paths) where paths.isEmpty: return "Lokale Änderungen würden überschrieben."
        case let .localChangesInTheWay(paths): return "Lokale Änderungen würden überschrieben: \(list(paths))."
        case .uncommittedChanges: return "Nicht committete Änderungen stehen im Weg; erst committen oder stashen."
        case .emptyStep: return "Der Schritt ist leer, es gibt nichts zu committen."
        case .unreachable: return "Der Server ist nicht erreichbar. Netzwerkverbindung und Remote-Adresse prüfen."
        case .authenticationFailed: return "Anmeldung beim Server fehlgeschlagen. GitBonsai fragt nicht nach Passwörtern: Zugangsdaten im Credential-Helper speichern oder den SSH-Schlüssel im SSH-Agent laden."
        case let .message(text) where text.isEmpty: return "git meldet einen Fehler (Exit-Code \(gitError.exitCode))."
        case let .message(text): return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    /// Local changes stopped the command before it changed anything, so stashing them and running it again gets it through.
    static func isBlockedByLocalChanges(_ error: Error) -> Bool {
        guard let gitError = error as? GitError else { return false }
        switch GitFailure(output: gitError.stderr) {
        case .localChangesInTheWay, .uncommittedChanges: return true
        default: return false
        }
    }

    /// A failure that changed nothing and asks for nothing: the server could not be reached, or a stash was already gone. A toast says so instead of a sheet.
    static func isPassing(_ error: Error) -> Bool {
        guard let gitError = error as? GitError else { return false }
        return GitFailure(output: gitError.stderr) == .unreachable || gitError.stderr.contains("is no longer in the stash list")
    }

    /// git's output as a terminal would show it, or nil when it says nothing beyond the summary.
    static func details(of error: Error) -> String? {
        guard let gitError = error as? GitError else { return nil }
        let text = GitFailure.visibleText(gitError.stderr)
        return text.isEmpty ? nil : text
    }

    /// The toast for what a rebase, cherry-pick or revert reported besides its result, or nil.
    static func toast(for report: OperationReport?) -> String? {
        guard let report else { return nil }
        var parts: [String] = []
        switch report.alreadyApplied {
        case 0: break
        case 1: parts.append("1 bereits enthaltener Commit übersprungen")
        default: parts.append("\(report.alreadyApplied) bereits enthaltene Commits übersprungen")
        }
        if report.skippedEmptyStep { parts.append(parts.isEmpty ? "Leeren Schritt übersprungen" : "leeren Schritt übersprungen") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func quoted(_ subject: String) -> String { subject.isEmpty ? "" : " „\(subject)“" }

    private static func list(_ paths: [String]) -> String {
        paths.count > 3 ? paths.prefix(3).joined(separator: ", ") + " und \(paths.count - 3) weitere" : paths.joined(separator: ", ")
    }
}
