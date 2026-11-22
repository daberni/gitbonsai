import AppKit
import GitEngine

/// Turns chosen or dropped folders into repository roots: a folder inside a repository stands for that repository.
@MainActor
struct RepositoryOpener {
    /// The root of the repository that contains `path`, or nil. With `reportErrors` a folder outside any repository is reported on the window.
    func root(containing path: String, reportErrorsOn window: NSWindow?) async -> String? {
        do {
            return try await Repository.root(containing: path)
        } catch {
            if let window { reportNotARepository(path, on: window) }
            return nil
        }
    }

    /// Asks for one or more folders in a sheet and hands them on once the user confirms.
    func chooseFolders(for window: NSWindow, then open: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Öffnen"
        panel.message = "Ordner eines Repositorys wählen. Ein Unterordner genügt."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            open(panel.urls.map(\.path))
        }
    }

    private func reportNotARepository(_ path: String, on window: NSWindow) {
        guard ScreenshotHarness.outputPath == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Kein Git-Repository"
        alert.informativeText = "\((path as NSString).abbreviatingWithTildeInPath) liegt in keinem Repository."
        alert.beginSheetModal(for: window)
    }
}
