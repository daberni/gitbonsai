import AppKit

/// Parts that the clone sheet, the new-branch sheet and the action forms share.
@MainActor
enum SheetSupport {
    /// A caption above its control, the control as wide as the form.
    static func captionRow(_ label: LocalizedStringResource, control: NSView, width: CGFloat) -> NSStackView {
        let caption = NSTextField(labelWithString: label.text)
        caption.font = Theme.caption
        caption.textColor = Theme.inkMuted
        let row = NSStackView(views: [caption, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Theme.ActionSheet.labelSpacing
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    /// A save panel on `window` that picks a new folder's place and name, starting at `directory` with `name` filled in.
    static func chooseFolder(title: String, directory: URL, name: String, on window: NSWindow, then chosen: @escaping (URL) -> Void) {
        let panel = savePanel(title: title)
        panel.prompt = String(localized: "common.choose", defaultValue: "Choose", bundle: .module)
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            chosen(url)
        }
    }

    /// A save panel on `window` for a file to write, with `name` suggested; nil when cancelled.
    static func chooseFile(title: String, name: String, on window: NSWindow) async -> URL? {
        let panel = savePanel(title: title)
        panel.nameFieldStringValue = name
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }

    private static func savePanel(title: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = title
        panel.canCreateDirectories = true
        return panel
    }

    enum Destination: Equatable {
        case missing, file, emptyFolder, occupiedFolder, unreadableFolder
    }

    /// What is at a path git is to create a folder at, a clone or a worktree; entries named in `ignoring` do not count as content.
    static func destination(at path: String, ignoring: Set<String> = []) -> Destination {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .file }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return .unreadableFolder }
        return contents.allSatisfy(ignoring.contains) ? .emptyFolder : .occupiedFolder
    }
}
