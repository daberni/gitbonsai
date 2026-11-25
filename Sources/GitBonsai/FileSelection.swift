import Foundation
import GitEngine

/// A file chosen in the detail panel, together with the change it is shown for.
struct FileSelection: Hashable {
    let path: String
    let originalPath: String?
    let source: DiffSource

    init(path: String, originalPath: String?, source: DiffSource) {
        self.path = path
        self.originalPath = originalPath
        self.source = source
    }

    /// Working directory files can be staged or unstaged; commit files only be looked at.
    var isStageable: Bool {
        switch source {
        case .unstaged, .untracked: true
        default: false
        }
    }

    var isUnstageable: Bool { source == .staged }

    var name: String { (path as NSString).lastPathComponent }
    var directory: String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? "" : directory + "/"
    }
}
