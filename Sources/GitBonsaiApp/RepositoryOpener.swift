import AppKit
import GitEngine

/// Turns chosen or dropped folders into repository roots: a folder inside a repository stands for that repository.
@MainActor
struct RepositoryOpener {
    /// Resolves all folders at once and returns their locations in the order of `paths`, with nil for a folder outside any repository.
    func locations(containing paths: [String]) async -> [RepositoryLocation?] {
        await withTaskGroup(of: (Int, RepositoryLocation?).self) { group in
            for (index, path) in paths.enumerated() {
                group.addTask { (index, try? await Repository.location(containing: path)) }
            }
            var locations = [RepositoryLocation?](repeating: nil, count: paths.count)
            for await (index, location) in group { locations[index] = location }
            return locations
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

    func reportNotARepository(_ path: String, on window: NSWindow) {
        guard ScreenshotHarness.outputPath == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Kein Git-Repository"
        alert.informativeText = "\((path as NSString).abbreviatingWithTildeInPath) liegt in keinem Repository."
        alert.beginSheetModal(for: window)
    }
}
