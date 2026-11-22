import AppKit
import GitEngine

/// Git: which git binary the app runs, with its version and a warning when it is too old.
final class GitSettingsViewController: SettingsPaneController {
    private let pathField = NSTextField()
    /// One line, so the section keeps its height while the message changes; long paths are shortened in the middle.
    private let status = SettingsForm.statusLine()
    private var versionCheck: Task<Void, Never>?

    override func buildForm(_ form: SettingsForm) {
        pathField.placeholderString = GitRunner.automaticGitPath()
        pathField.stringValue = AppSettings.gitPath ?? ""
        pathField.usesSingleLineMode = true
        pathField.cell?.wraps = false
        pathField.cell?.isScrollable = true
        pathField.target = self
        pathField.action = #selector(commitPath(_:))
        pathField.widthAnchor.constraint(equalToConstant: Theme.Settings.pathFieldWidth).isActive = true
        let choose = NSButton(title: "Auswählen …", target: self, action: #selector(choosePath(_:)))
        let row = NSStackView(views: [pathField, choose])
        row.spacing = Theme.Settings.columnSpacing
        form.addRow("Git-Programm", row)
        form.addCaption(status)
        form.addCaption(SettingsForm.caption("Leer lassen, um git automatisch zu finden. Gilt für Repositories, die danach geöffnet werden."))
        showVersion()
    }

    @objc private func commitPath(_ sender: Any?) {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard path.isEmpty || FileManager.default.isExecutableFile(atPath: path) else {
            show("Unter „\(path)“ liegt kein ausführbares Programm. Nicht übernommen.", color: Theme.persimmon)
            return
        }
        guard path != (AppSettings.gitPath ?? "") else { return showVersion() }
        AppSettings.gitPath = path
        showVersion()
    }

    @objc private func choosePath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: (GitRunner.defaultGitPath() as NSString).deletingLastPathComponent)
        panel.prompt = "Auswählen"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            pathField.stringValue = url.path
            commitPath(nil)
        }
    }

    /// Asks the git the app would run now for its version.
    private func showVersion() {
        let path = GitRunner.defaultGitPath()
        show("Prüfe git …", color: Theme.inkMuted)
        versionCheck?.cancel()
        versionCheck = Task { [weak self] in
            let result: Result<GitVersion, Error>
            do { result = .success(try await GitRunner.version(ofGitAt: path)) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let version) where version < .minimumSupported:
                show("git \(version) ist zu alt. GitBonsai braucht git \(GitVersion.minimumSupported.major).\(GitVersion.minimumSupported.minor) oder neuer.", color: Theme.ochre)
            case .success(let version):
                show("git \(version) unter \(path)", color: Theme.inkMuted)
            case .failure:
                show("Dieses Programm meldet sich nicht als git.", color: Theme.persimmon)
            }
        }
    }

    private func show(_ text: String, color: NSColor) {
        status.stringValue = text
        status.textColor = color
    }
}
