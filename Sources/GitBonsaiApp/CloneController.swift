import AppKit
import GitEngine

/// "Clone Repository": asks for source, destination and options in a sheet, runs `git clone` with its progress and hands the new repository on.
/// The URL comes from the pasteboard when it holds one; the destination follows the URL inside the first repository folder until the user edits it.
@MainActor
final class CloneController {
    /// Called with the new working tree after a successful clone.
    var onCloned: ((String) -> Void)?
    /// Called whenever the sheet has closed, cloned or not.
    var onClose: (() -> Void)?

    private(set) var sheet: CloneSheet?
    private var parent: NSWindow?
    private var clone: Task<Void, Never>?
    /// The destination last filled in automatically; once the field differs, the user's choice stays.
    private var suggestedDestination = ""

    var isShowing: Bool { sheet != nil }
    private let settings: AppSettings
    private let pasteboard: Pasteboard

    init(settings: AppSettings, pasteboard: Pasteboard) {
        self.settings = settings
        self.pasteboard = pasteboard
    }

    func show(on window: NSWindow) {
        guard sheet == nil else { return }
        let sheet = CloneSheet(pasteboard: pasteboard)
        self.sheet = sheet
        parent = window
        sheet.onChange = { [weak self] in self?.update() }
        sheet.cloneButton.target = self
        sheet.cloneButton.action = #selector(start(_:))
        sheet.cancelButton.target = self
        sheet.cancelButton.action = #selector(cancel(_:))
        sheet.chooseButton.target = self
        sheet.chooseButton.action = #selector(chooseDestination(_:))
        // harness: the out-of-process harness puts its text on the pasteboard before it opens the sheet.
        ScreenshotHarness.seedClonePasteboard()
        if let pasted = pasteboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines), CloneSource.isCloneable(pasted) {
            sheet.urlField.stringValue = pasted
        }
        update()
        sheet.fitWindow()
        window.beginSheet(sheet.window)
    }

    // MARK: Form

    private var destinationBase: String {
        settings.repositoryFolders.first ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private var url: String { sheet?.urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var destination: String { ((sheet?.destinationField.stringValue ?? "").trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }

    /// Follows the URL with the destination and checks the folder after every change.
    private func update() {
        guard let sheet else { return }
        let current = sheet.destinationField.stringValue
        if current.isEmpty || current == suggestedDestination {
            let name = CloneSource.repositoryName(of: url) ?? ""
            let suggestion = name.isEmpty ? "" : ((destinationBase as NSString).appendingPathComponent(name) as NSString).abbreviatingWithTildeInPath
            sheet.destinationField.stringValue = suggestion
            suggestedDestination = suggestion
        }
        let problem = destinationProblem
        sheet.showWarning(problem)
        sheet.cloneButton.isEnabled = !url.isEmpty && !destination.isEmpty && problem == nil
    }

    /// git clones only into a folder that is missing or empty; saying so before it runs spares a failure.
    private var destinationProblem: String? {
        guard !destination.isEmpty else { return nil }
        switch FolderDestination.at(destination) {
        case .missing, .emptyFolder: return nil
        case .unreadableFolder: return String(localized: "clone.destination.unreadable", defaultValue: "The folder can't be read.", bundle: .module)
        case .file: return String(localized: "clone.destination.fileInTheWay", defaultValue: "A file is in the way at this path.", bundle: .module)
        case .occupiedFolder: return String(localized: "clone.destination.notEmpty", defaultValue: "The folder already exists and isn't empty.", bundle: .module)
        }
    }

    var options: CloneOptions {
        let branch = sheet?.branchField.stringValue.trimmingCharacters(in: .whitespaces)
        return CloneOptions(recurseSubmodules: sheet?.submodules.state == .on, shallow: sheet?.shallow.state == .on, branch: branch?.isEmpty == false ? branch : nil)
    }

    /// Fills the form as a user would; the harness answers the sheet this way.
    func fill(_ answers: [String: String]) {
        guard let sheet else { return }
        if let url = answers["url"] { sheet.urlField.stringValue = url }
        if let path = answers["path"] { sheet.destinationField.stringValue = path }
        if let branch = answers["branch"] { sheet.branchField.stringValue = branch }
        if let value = answers["submodules"] { sheet.submodules.state = value == "1" ? .on : .off }
        if let value = answers["shallow"] { sheet.shallow.state = value == "1" ? .on : .off }
        update()
    }

    @objc private func chooseDestination(_ sender: Any?) {
        guard let sheet else { return }
        let current = URL(fileURLWithPath: destination.isEmpty ? destinationBase : destination)
        let title = String(localized: "clone.destination.panelTitle", defaultValue: "Clone Destination", bundle: .module)
        SheetSupport.chooseFolder(title: title, directory: current.deletingLastPathComponent(), name: current.lastPathComponent, on: sheet.window) { [weak self] url in
            sheet.destinationField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            self?.update()
        }
    }

    // MARK: Running

    @objc private func start(_ sender: Any?) {
        guard let sheet, clone == nil, sheet.cloneButton.isEnabled else { return }
        let url = url
        let destination = destination
        let options = options
        sheet.showRunning(true)
        // harness: replaced by an `os.Logger` trace through `TraceSink`, which the harness reads from the unified log.
        ScreenshotHarness.traceClone((["git", "clone", "--progress"] + options.arguments + ["--", url, destination]).joined(separator: " "))
        clone = Task { [weak self] in
            do {
                try await Repository.clone(url: url, to: destination, options: options) { progress in
                    Task { @MainActor in self?.sheet?.show(progress) }
                }
                self?.finish(.success(destination))
            } catch {
                self?.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        clone = nil
        switch result {
        case .success(let path):
            // harness: replaced by an `os.Logger` trace through `TraceSink`, which the harness reads from the unified log.
            ScreenshotHarness.traceClone("cloned into \(path)")
            close()
            onCloned?(path)
        case .failure(let error) where error is CancellationError:
            // harness: replaced by an `os.Logger` trace through `TraceSink`, which the harness reads from the unified log.
            ScreenshotHarness.traceClone("cancelled, folder left behind: \(FileManager.default.fileExists(atPath: destination))")
            close()
        case .failure(let error):
            // harness: replaced by an `os.Logger` trace through `TraceSink`, which the harness reads from the unified log.
            ScreenshotHarness.traceClone("failed: \(GitFailureText.summary(of: error).plain)")
            sheet?.showRunning(false)
            sheet?.showFailure(error)
            update()
        }
    }

    /// Cancel while git runs stops it, and `Repository.clone` removes what it wrote; the sheet closes once git has exited.
    @objc func cancel(_ sender: Any?) {
        if let clone {
            // harness: replaced by an `os.Logger` trace through `TraceSink`, which the harness reads from the unified log.
            ScreenshotHarness.traceClone("cancelling")
            clone.cancel()
            return
        }
        close()
    }

    private func close() {
        guard let sheet else { return }
        parent?.endSheet(sheet.window)
        sheet.window.orderOut(nil)
        self.sheet = nil
        onClose?()
    }
}
